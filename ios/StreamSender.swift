import Foundation
import Network

enum StreamSenderConnectionState: Equatable {
    case waiting
    case connected
    case sending
    case disconnected
    case failed
}

/// Step 5: listen on a TCP port. usbmuxd tunnels it over USB automatically,
/// so the Windows receiver connects via usbmuxd_connect(device_id, PORT).
final class StreamSender {

    static let port: UInt16 = 12345

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "sender")
    var onStatus: ((String) -> Void)?
    var onClientConnected: (() -> Void)?
    var onFrameRate: ((Double, UInt64) -> Void)?
    /// Window-max time (ms) a packet waited in the send queue plus the send, reported with onFrameRate.
    var onQueueLatency: ((Double) -> Void)?
    var onFrameSent: ((TimeInterval) -> Void)?
    var onConnectionState: ((StreamSenderConnectionState) -> Void)?
    var onKeyFrameNeeded: (() -> Void)?
    /// Called once each time a live PC connection ends, with a short reason.
    var onDisconnect: ((String) -> Void)?
    // Keep the queue short to bound latency, but allow enough packets to absorb
    // Network.framework completion jitter. A one-packet gate measured ~30 fps
    // even when the camera was producing native 4K60.
    private let maxQueuedPackets = 8
    private var pendingPackets: [(data: Data, enqueuedAt: TimeInterval)] = []
    private var windowMaxQueueLatencyMs = 0.0
    private var sendInFlight = false
    // Network.framework may complete a send that was submitted before a
    // transient `.waiting` state. Fence those completions so they cannot make
    // recovered health/counters look active before a fresh keyframe is sent.
    private var sendGeneration: UInt64 = 0
    private var connectionReady = false
    private var waitingForKeyFrame = true
    private var sentFrameCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var sentFrameStart = ProcessInfo.processInfo.systemUptime
    private var desiredRunning = false
    private var listenerRetryAttempt = 0
    // USB tethering can disappear and come back without changing the app
    // lifecycle. Recreate the listener whenever its wired path changes so a
    // previously-ready listener is never left bound to the old interface.
    private let pathMonitor = NWPathMonitor()
    private var wiredPathSignature: String?
    private var listenerReady = false

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor.start(queue: queue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredRunning = true
            self.publishConnectionState(.waiting)
            self.startOnQueue()
        }
    }

    /// Rebind after foreground recovery or a USB interface transition. Calling
    /// `start()` alone is intentionally idempotent and cannot repair a
    /// listener that Network.framework still considers ready on a stale path.
    func restartListening(reason: String) {
        queue.async { [weak self] in
            guard let self, self.desiredRunning else { return }
            self.noteDisconnect("listener restart: \(reason)")
            self.connection?.cancel()
            self.connection = nil
            self.connectionReady = false
            self.sendInFlight = false
            self.pendingPackets.removeAll(keepingCapacity: true)
            let oldListener = self.listener
            self.listenerReady = false
            self.listener = nil
            oldListener?.cancel()
            self.listenerRetryAttempt = 0
            self.publishConnectionState(.waiting)
            self.report(reason)
            self.startOnQueue()
        }
    }

    /// Media discontinuity (camera or encoder rebuilt) without a transport fault.
    /// Keep the PC connection; drop queued deltas and wait for a fresh IDR.
    func resetForDiscontinuity(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingPackets.removeAll(keepingCapacity: true)
            self.waitingForKeyFrame = true
            self.sendGeneration &+= 1
            self.report(reason)
        }
    }

    private func handlePathUpdate(_ path: NWPath) {
        dispatchPrecondition(condition: .onQueue(queue))
        let wiredInterfaces = path.availableInterfaces
            .filter { $0.type == .wiredEthernet }
            .map(\.name)
            .sorted()
            .joined(separator: ",")
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        let signature = "\(status):\(wiredInterfaces)"
        defer { wiredPathSignature = signature }
        guard let previous = wiredPathSignature, previous != signature, desiredRunning else { return }
        // A ready listener is bound to the wildcard address and keeps accepting on
        // interfaces that appear later. Never drop a working PC connection because
        // Wi-Fi or cellular changed; only rebuild a listener that is not ready.
        guard !listenerReady else {
            print("SENDER: network path changed; listener still ready")
            return
        }
        restartListening(reason: "USB network path changed • rebinding listener")
    }

    private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard listener == nil else { return }
        let tcpOptions = NWProtocolTCP.Options()
        // Push each frame out immediately; Nagle would hold back a frame's tail.
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        // restartListening closes the PC connection server-side, leaving port
        // 12345 in TIME_WAIT. Without reuse the rebind fails and backs off ~30 s.
        params.allowLocalEndpointReuse = true
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: StreamSender.port))
        } catch {
            print("ERROR: NWListener \(error)")
            publishConnectionState(.failed)
            scheduleRestart()
            return
        }
        listenerReady = false
        listener = newListener
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            switch state {
            case .ready:
                guard self.listener === newListener else { return }
                self.listenerReady = true
                self.listenerRetryAttempt = 0
                self.publishConnectionState(.waiting)
                self.report("USB stream service ready")
            case .waiting(let error):
                self.publishConnectionState(.waiting)
                self.report("USB listener waiting: \(error.localizedDescription)")
            case .failed(let error):
                guard self.listener === newListener else { return }
                self.listenerReady = false
                self.publishConnectionState(.failed)
                self.report("USB listener failed: \(error.localizedDescription)")
                self.noteDisconnect("listener failed: \(error.localizedDescription)")
                self.connection?.cancel()
                self.connection = nil
                self.connectionReady = false
                self.sendInFlight = false
                self.pendingPackets.removeAll(keepingCapacity: true)
                self.listener = nil
                newListener.cancel()
                self.scheduleRestart()
            case .cancelled:
                guard self.listener === newListener else { return }
                self.listenerReady = false
                self.listener = nil
                self.publishConnectionState(self.desiredRunning ? .waiting : .disconnected)
                self.report("USB listener stopped")
                self.scheduleRestart()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.noteDisconnect("replaced by new PC connection")
            self.connection?.cancel()
            self.connection = conn
            self.connectionReady = false
            self.sendInFlight = false
            self.pendingPackets.removeAll(keepingCapacity: true)
            self.waitingForKeyFrame = true
            self.publishConnectionState(.waiting)
            self.sentFrameCount = 0
            self.droppedFrameCount = 0
            self.sentFrameStart = ProcessInfo.processInfo.systemUptime
            self.windowMaxQueueLatencyMs = 0
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                self?.queue.async {
                    guard let self, let conn, self.connection === conn else { return }
                    switch state {
                    case .ready:
                        self.connectionReady = true
                        self.waitingForKeyFrame = true
                        self.sentFrameCount = 0
                        self.droppedFrameCount = 0
                        self.sentFrameStart = ProcessInfo.processInfo.systemUptime
                        self.windowMaxQueueLatencyMs = 0
                        self.publishConnectionState(.connected)
                        self.onClientConnected?()
                        self.report("PC connected • starting video")
                    case .waiting(let error):
                        self.pauseForConnectionWaiting()
                        self.report("PC connection waiting: \(error.localizedDescription)")
                    case .failed(let error):
                        self.noteDisconnect("connection failed: \(error.localizedDescription)")
                        self.connectionReady = false
                        self.connection = nil
                        self.sendInFlight = false
                        self.pendingPackets.removeAll(keepingCapacity: true)
                        self.publishConnectionState(.failed)
                        self.report("PC connection failed: \(error.localizedDescription)")
                    case .cancelled:
                        self.noteDisconnect("PC connection closed")
                        self.connectionReady = false
                        self.connection = nil
                        self.sendInFlight = false
                        self.pendingPackets.removeAll(keepingCapacity: true)
                        self.publishConnectionState(.disconnected)
                        self.report("PC connection closed")
                    default:
                        break
                    }
                }
            }
            conn.start(queue: self.queue)
        }
        newListener.start(queue: queue)
        print("SENDER: listening on port \(StreamSender.port)")
    }

    private func scheduleRestart() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard desiredRunning, listener == nil else { return }
        let delay = min(2.0, 0.25 * pow(2.0, Double(listenerRetryAttempt)))
        listenerRetryAttempt = min(listenerRetryAttempt + 1, 5)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.desiredRunning, self.listener == nil else { return }
            self.startOnQueue()
        }
    }

    /// Send a complete protocol packet (header + Annex-B frame).
    func send(frameNumber: UInt32, timestampUs: UInt64, codec: UInt8, isKeyframe: Bool, frame: Data) {
        guard frame.count <= StreamHeader.maxFrameSize else {
            print("ERROR: encoded frame \(frame.count) bytes exceeds protocol limit")
            queue.async { [weak self] in
                self?.waitingForKeyFrame = true
                self?.onKeyFrameNeeded?()
            }
            return
        }
        let header = StreamHeader(
            magic: StreamHeader.magic,
            frameNumber: frameNumber,
            timestampUs: timestampUs,
            codec: codec,
            frameSize: UInt32(frame.count)
        ).encode()
        var packet = Data(capacity: header.count + frame.count)
        packet.append(header)
        packet.append(frame)

        queue.async { [weak self] in
            guard let self, let conn = self.connection,
                  self.connectionReady else { return }
            guard !self.waitingForKeyFrame || isKeyframe else { return }
            guard self.pendingPackets.count < self.maxQueuedPackets else {
                self.droppedFrameCount &+= 1
                // A dropped frame breaks the reference chain. Stop admitting deltas
                // and ask for an IDR instead of streaming corrupt video for up to 2 s.
                self.waitingForKeyFrame = true
                self.onKeyFrameNeeded?()
                return
            }
            self.pendingPackets.append((data: packet, enqueuedAt: ProcessInfo.processInfo.systemUptime))
            // Do not admit delta frames until this IDR was actually retained.
            if isKeyframe { self.waitingForKeyFrame = false }
            self.pumpSend(connection: conn)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.desiredRunning = false
            self?.listenerRetryAttempt = 0
            self?.connection?.cancel()
            self?.connection = nil
            self?.connectionReady = false
            self?.sendInFlight = false
            self?.pendingPackets.removeAll(keepingCapacity: true)
            self?.listener?.cancel()
            self?.listenerReady = false
            self?.listener = nil
            self?.publishConnectionState(.disconnected)
        }
    }

    private func report(_ message: String) {
        print("SENDER: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }

    /// Report that a live connection is ending. Call it before the connection is
    /// cleared; it does nothing when no connection exists, so each drop is
    /// reported once (later handlers for the same connection fail their identity guard).
    private func noteDisconnect(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connection != nil else { return }
        onDisconnect?(reason)
    }

    private func publishConnectionState(_ state: StreamSenderConnectionState) {
        dispatchPrecondition(condition: .onQueue(queue))
        onConnectionState?(state)
    }

    private func pauseForConnectionWaiting() {
        dispatchPrecondition(condition: .onQueue(queue))
        connectionReady = false
        pendingPackets.removeAll(keepingCapacity: true)
        waitingForKeyFrame = true
        sendGeneration &+= 1
        publishConnectionState(.waiting)
    }

    private func pumpSend(connection: NWConnection) {
        guard connectionReady, !sendInFlight, !pendingPackets.isEmpty else { return }
        let next = pendingPackets.removeFirst()
        let packet = next.data
        let enqueuedAt = next.enqueuedAt
        sendInFlight = true
        let generation = sendGeneration
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            self?.queue.async {
                guard let self, let connection, self.connection === connection else { return }
                self.sendInFlight = false
                guard generation == self.sendGeneration else {
                    // This completion belongs to the pre-wait transport state,
                    // including any error it carries. Resume only with the
                    // queued fresh IDR on the current connection generation.
                    self.pumpSend(connection: connection)
                    return
                }
                if let error {
                    self.report("Video send failed: \(error.localizedDescription)")
                    self.noteDisconnect("send error: \(error.localizedDescription)")
                    self.connectionReady = false
                    self.connection = nil
                    self.pendingPackets.removeAll(keepingCapacity: true)
                    self.publishConnectionState(.failed)
                    connection.cancel()
                    return
                }
                self.sentFrameCount &+= 1
                let sentAt = ProcessInfo.processInfo.systemUptime
                self.windowMaxQueueLatencyMs = max(self.windowMaxQueueLatencyMs,
                                                   (sentAt - enqueuedAt) * 1000.0)
                if self.sentFrameCount == 1 {
                    self.publishConnectionState(.sending)
                    self.onFrameSent?(sentAt)
                    self.report("First video frame sent")
                }
                if self.sentFrameCount % 30 == 0 {
                    self.onFrameSent?(sentAt)
                }
                if self.sentFrameCount % 60 == 0 {
                    let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - self.sentFrameStart)
                    self.onFrameRate?(Double(self.sentFrameCount) / elapsed, self.droppedFrameCount)
                    self.onQueueLatency?(self.windowMaxQueueLatencyMs)
                    self.windowMaxQueueLatencyMs = 0
                }
                self.pumpSend(connection: connection)
            }
        })
    }
}
