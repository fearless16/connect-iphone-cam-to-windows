import Foundation
import Network

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
    // Keep the queue short to bound latency, but allow enough packets to absorb
    // Network.framework completion jitter. A one-packet gate measured ~30 fps
    // even when the camera was producing native 4K60.
    private let maxQueuedPackets = 8
    private var pendingPackets: [Data] = []
    private var sendInFlight = false
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
            self.startOnQueue()
        }
    }

    /// Rebind after foreground recovery or a USB interface transition. Calling
    /// `start()` alone is intentionally idempotent and cannot repair a
    /// listener that Network.framework still considers ready on a stale path.
    func restartListening(reason: String) {
        queue.async { [weak self] in
            guard let self, self.desiredRunning else { return }
            self.connection?.cancel()
            self.connection = nil
            self.connectionReady = false
            self.sendInFlight = false
            self.pendingPackets.removeAll(keepingCapacity: true)
            let oldListener = self.listener
            self.listener = nil
            oldListener?.cancel()
            self.listenerRetryAttempt = 0
            self.report(reason)
            self.startOnQueue()
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
        restartListening(reason: "USB network path changed • rebinding listener")
    }

    private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard listener == nil else { return }
        let params = NWParameters.tcp
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: StreamSender.port))
        } catch {
            print("ERROR: NWListener \(error)")
            scheduleRestart()
            return
        }
        listener = newListener
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            switch state {
            case .ready:
                guard self.listener === newListener else { return }
                self.listenerRetryAttempt = 0
                self.report("USB stream service ready")
            case .waiting(let error):
                self.report("USB listener waiting: \(error.localizedDescription)")
            case .failed(let error):
                guard self.listener === newListener else { return }
                self.report("USB listener failed: \(error.localizedDescription)")
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
                self.listener = nil
                self.report("USB listener stopped")
                self.scheduleRestart()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = conn
            self.connectionReady = false
            self.sendInFlight = false
            self.pendingPackets.removeAll(keepingCapacity: true)
            self.waitingForKeyFrame = true
            self.sentFrameCount = 0
            self.droppedFrameCount = 0
            self.sentFrameStart = ProcessInfo.processInfo.systemUptime
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                self?.queue.async {
                    guard let self, let conn, self.connection === conn else { return }
                    switch state {
                    case .ready:
                        self.connectionReady = true
                        self.waitingForKeyFrame = true
                        self.onClientConnected?()
                        self.report("PC connected • starting video")
                    case .waiting(let error):
                        self.report("PC connection waiting: \(error.localizedDescription)")
                    case .failed(let error):
                        self.connectionReady = false
                        self.connection = nil
                        self.sendInFlight = false
                        self.pendingPackets.removeAll(keepingCapacity: true)
                        self.report("PC connection failed: \(error.localizedDescription)")
                    case .cancelled:
                        self.connectionReady = false
                        self.connection = nil
                        self.sendInFlight = false
                        self.pendingPackets.removeAll(keepingCapacity: true)
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
        let delay = min(30.0, pow(2.0, Double(listenerRetryAttempt)))
        listenerRetryAttempt = min(listenerRetryAttempt + 1, 5)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.desiredRunning, self.listener == nil else { return }
            self.startOnQueue()
        }
    }

    /// Send a complete protocol packet (header + Annex-B frame).
    func send(frameNumber: UInt32, timestampUs: UInt64, codec: UInt8, isKeyframe: Bool, frame: Data) {
        guard frame.count <= Int(UInt32.max) else {
            print("ERROR: encoded frame exceeds protocol limit")
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
                return
            }
            self.pendingPackets.append(packet)
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
            self?.listener = nil
        }
    }

    private func report(_ message: String) {
        print("SENDER: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }

    private func pumpSend(connection: NWConnection) {
        guard !sendInFlight, !pendingPackets.isEmpty else { return }
        let packet = pendingPackets.removeFirst()
        sendInFlight = true
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            self?.queue.async {
                guard let self, let connection, self.connection === connection else { return }
                self.sendInFlight = false
                if let error {
                    self.report("Video send failed: \(error.localizedDescription)")
                    self.connectionReady = false
                    self.connection = nil
                    self.pendingPackets.removeAll(keepingCapacity: true)
                    connection.cancel()
                    return
                }
                self.sentFrameCount &+= 1
                if self.sentFrameCount == 1 {
                    self.report("First video frame sent")
                }
                if self.sentFrameCount % 60 == 0 {
                    let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - self.sentFrameStart)
                    self.onFrameRate?(Double(self.sentFrameCount) / elapsed, self.droppedFrameCount)
                }
                self.pumpSend(connection: connection)
            }
        })
    }
}
