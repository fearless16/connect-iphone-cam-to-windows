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
    // T3.3: Bonjour service type; must match NSBonjourServices in Info.plist.
    static let bonjourType = "_ipcamstream._tcp"
    // A fixed ASCII instance name. The default (the device name) usually holds a
    // curly apostrophe, which the receiver's validator rejects as non-ASCII.
    // Bonjour appends " (2)" itself if two phones advertise at once.
    static let bonjourName = "iPhoneCameraStream"

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "sender")
    var onStatus: ((String) -> Void)?
    var onClientConnected: (() -> Void)?
    /// Called just before `onClientConnected` with whether the PC connected over
    /// Wi-Fi (true) or USB (false). The encoder bit rate follows the transport.
    var onClientTransport: ((Bool) -> Void)?
    /// One reading of the TCP link to the PC, from the transport's own counters.
    struct LinkStats {
        var rttMs: Double
        var rttVarMs: Double
        /// Retransmitted bytes / sent bytes over the window, 0 if nothing was sent.
        var retransmitRatio: Double
        /// Frames dropped on queue overflow during the window.
        var drops: UInt64
        /// Longest wait (ms) of any packet during the window, including a packet
        /// still queued or in flight, so a stalled link is visible.
        var maxQueueMs: Double
    }
    /// Every 2 s while a PC is connected (T5.8). Called on the sender queue.
    var onLinkStats: ((LinkStats) -> Void)?
    var onFrameRate: ((Double, UInt64) -> Void)?
    /// Window-max time (ms) a packet waited in the send queue plus the send, reported with onFrameRate.
    var onQueueLatency: ((Double) -> Void)?
    var onFrameSent: ((TimeInterval) -> Void)?
    var onConnectionState: ((StreamSenderConnectionState) -> Void)?
    var onKeyFrameNeeded: (() -> Void)?
    /// Called once each time a live PC connection ends, with a short reason.
    var onDisconnect: ((String) -> Void)?
    /// IPv4 address of the Wi-Fi interface while Wi-Fi mode is on, else nil.
    /// Published when the listener becomes ready and on every path update.
    var onWiFiAddress: ((String?) -> Void)?
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
    // T3.1: off by default, so the listener refuses Wi-Fi and cellular and only
    // the USB (usbmux) path reaches it. Confined to `queue`.
    private var wifiEnabled = false
    // T5.8: one repeating timer (never recreated while running) collects the
    // transport counters of the live connection every 2 s. Confined to `queue`.
    private static let linkStatsInterval: TimeInterval = 2
    private var linkTimer: DispatchSourceTimer?
    private var pendingTransferReport: NWConnection.PendingDataTransferReport?
    private var pendingTransferConnection: NWConnection?
    // Link-window counters for onLinkStats. They are read by the 2 s timer, not
    // by the send completion, so a link that sends nothing still reports its
    // drops and its queue wait. Confined to `queue`.
    private var linkWindowDrops: UInt64 = 0
    private var linkWindowMaxQueueMs = 0.0
    private var inFlightEnqueuedAt: TimeInterval?
    // Every drop asks for an IDR, but at most once per interval: on a weak link
    // a keyframe per drop would make the congestion worse. Confined to `queue`.
    private static let keyFrameRequestInterval: TimeInterval = 0.5
    private var lastKeyFrameRequestUptime: TimeInterval = -.infinity
    private var keyFrameRequestDeferred = false
    // Name of the Wi-Fi interface as the path monitor reports it (never hardcoded).
    private var wifiInterfaceName: String?

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
            self.startLinkTimer()
            self.startOnQueue()
        }
    }

    private func startLinkTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard linkTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.linkStatsInterval, repeating: Self.linkStatsInterval)
        timer.setEventHandler { [weak self] in self?.collectLinkStats() }
        linkTimer = timer
        timer.resume()
    }

    private func stopLinkTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        linkTimer?.cancel()
        linkTimer = nil
        pendingTransferReport = nil
        pendingTransferConnection = nil
    }

    /// Each tick collects the report started on the previous tick and starts the
    /// next one, so a report always covers one full interval of one connection.
    private func collectLinkStats() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Close this window's counters now, whether or not a report follows.
        let drops = linkWindowDrops
        let maxQueueMs = currentWindowMaxQueueMs()
        resetLinkWindow()
        guard let conn = connection, connectionReady else {
            pendingTransferReport = nil
            pendingTransferConnection = nil
            return
        }
        let previous = pendingTransferReport
        let previousConnection = pendingTransferConnection
        pendingTransferReport = conn.startDataTransferReport()
        pendingTransferConnection = conn
        // A report that belongs to an earlier connection says nothing about this one.
        guard let previous, previousConnection === conn else { return }
        previous.collect(queue: queue) { [weak self, weak conn] report in
            guard let self, let conn, self.connection === conn,
                  let path = report.pathReports.first else { return }
            let sent = Double(path.sentTransportByteCount)
            self.onLinkStats?(LinkStats(
                rttMs: path.transportSmoothedRTT * 1000,
                rttVarMs: path.transportRTTVariance * 1000,
                retransmitRatio: sent > 0 ? Double(path.retransmittedTransportByteCount) / sent : 0,
                drops: drops,
                maxQueueMs: maxQueueMs))
        }
    }

    /// The window's longest packet wait, counting the packet in flight and the
    /// oldest queued packet as waiting until now.
    private func currentWindowMaxQueueMs() -> Double {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = ProcessInfo.processInfo.systemUptime
        var longest = linkWindowMaxQueueMs
        if let inFlightEnqueuedAt { longest = max(longest, (now - inFlightEnqueuedAt) * 1000.0) }
        if let oldest = pendingPackets.first { longest = max(longest, (now - oldest.enqueuedAt) * 1000.0) }
        return longest
    }

    private func resetLinkWindow() {
        dispatchPrecondition(condition: .onQueue(queue))
        linkWindowDrops = 0
        linkWindowMaxQueueMs = 0
    }

    /// Asks the encoder for an IDR at most once per `keyFrameRequestInterval`.
    /// A request inside the interval is deferred, not lost, and is skipped if a
    /// keyframe was admitted meanwhile.
    private func requestKeyFrame() {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = ProcessInfo.processInfo.systemUptime
        let wait = lastKeyFrameRequestUptime + Self.keyFrameRequestInterval - now
        guard wait > 0 else {
            lastKeyFrameRequestUptime = now
            onKeyFrameNeeded?()
            return
        }
        guard !keyFrameRequestDeferred else { return }
        keyFrameRequestDeferred = true
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.keyFrameRequestDeferred = false
            guard self.waitingForKeyFrame else { return }
            self.lastKeyFrameRequestUptime = ProcessInfo.processInfo.systemUptime
            self.onKeyFrameNeeded?()
        }
    }

    /// Opt in to (or out of) Wi-Fi connections. Only the listener is rebuilt,
    /// because the allowed interfaces are fixed when it is created. An accepted
    /// connection does not depend on its listener, so a USB connection keeps
    /// streaming; a Wi-Fi client is closed only when Wi-Fi is turned off.
    func setWiFiEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.wifiEnabled != enabled else { return }
            self.wifiEnabled = enabled
            if !enabled, let conn = self.connection, conn.currentPath?.usesInterfaceType(.wifi) == true {
                self.noteDisconnect("Wi-Fi streaming disabled")
                self.dropConnection()
                self.publishConnectionState(.waiting)
            }
            self.rebuildListener(reason: enabled ? "Wi-Fi streaming enabled" : "Wi-Fi streaming disabled")
            self.publishWiFiAddress()
        }
    }

    /// Rebind after a USB interface transition. Calling `start()` alone is
    /// intentionally idempotent and cannot repair a listener that
    /// Network.framework still considers ready on a stale path.
    func restartListening(reason: String) {
        queue.async { [weak self] in
            guard let self, self.desiredRunning else { return }
            self.noteDisconnect("listener restart: \(reason)")
            self.dropConnection()
            self.publishConnectionState(.waiting)
            self.rebuildListener(reason: reason)
        }
    }

    /// Cancels the current PC connection and clears its send state.
    private func dropConnection() {
        dispatchPrecondition(condition: .onQueue(queue))
        connection?.cancel()
        connection = nil
        connectionReady = false
        sendInFlight = false
        inFlightEnqueuedAt = nil
        pendingPackets.removeAll(keepingCapacity: true)
    }

    /// Replaces the listener and leaves any accepted connection alone.
    private func rebuildListener(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard desiredRunning else { return }
        let oldListener = listener
        listenerReady = false
        listener = nil
        oldListener?.cancel()
        listenerRetryAttempt = 0
        report(reason)
        startOnQueue()
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
        wifiInterfaceName = path.availableInterfaces.first(where: { $0.type == .wifi })?.name
        publishWiFiAddress()
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
        guard !listenerReady else { return }
        restartListening(reason: "USB network path changed • rebinding listener")
    }

    private func publishWiFiAddress() {
        dispatchPrecondition(condition: .onQueue(queue))
        onWiFiAddress?(wifiEnabled ? wifiInterfaceName.flatMap(Self.ipv4Address(ofInterface:)) : nil)
    }

    /// IPv4 address of the named interface, or nil when it has none.
    private static func ipv4Address(ofInterface name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == name else { continue }
            let capacity = Int(INET_ADDRSTRLEN)
            var host = [CChar](repeating: 0, count: capacity)
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { socketAddress in
                var ipv4 = socketAddress.pointee.sin_addr
                _ = inet_ntop(AF_INET, &ipv4, &host, socklen_t(capacity))
            }
            return String(cString: host)
        }
        return nil
    }

    private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard listener == nil else { return }
        let tcpOptions = NWProtocolTCP.Options()
        // Push each frame out immediately; Nagle would hold back a frame's tail.
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        // WMM video class for Wi-Fi; harmless on USB.
        params.serviceClass = .interactiveVideo
        // D4: without the Wi-Fi opt-in, refuse every non-USB interface.
        if !wifiEnabled { params.prohibitedInterfaceTypes = [.wifi, .cellular] }
        // restartListening closes the PC connection server-side, leaving port
        // 12345 in TIME_WAIT. Without reuse the rebind fails and backs off ~30 s.
        params.allowLocalEndpointReuse = true
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: StreamSender.port))
        } catch {
            report("USB listener could not be created: \(error)")
            publishConnectionState(.failed)
            scheduleRestart()
            return
        }
        // T3.3: announce over Bonjour only while Wi-Fi mode is on. The listener is
        // rebuilt on every Wi-Fi switch change, so the advertisement follows it.
        if wifiEnabled {
            newListener.service = NWListener.Service(name: StreamSender.bonjourName, type: StreamSender.bonjourType)
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
                // A rebuilt listener (Wi-Fi switch) must not mark a live PC connection as waiting.
                if self.connection == nil { self.publishConnectionState(.waiting) }
                self.publishWiFiAddress()
                self.report("USB stream service ready")
            case .waiting(let error):
                if self.connection == nil { self.publishConnectionState(.waiting) }
                self.report("USB listener waiting: \(Self.describe(error))")
            case .failed(let error):
                guard self.listener === newListener else { return }
                self.listenerReady = false
                self.publishConnectionState(.failed)
                self.report("USB listener failed: \(Self.describe(error))")
                self.noteDisconnect("listener failed: \(Self.describe(error))")
                self.dropConnection()
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
            self.inFlightEnqueuedAt = nil
            self.pendingPackets.removeAll(keepingCapacity: true)
            self.waitingForKeyFrame = true
            self.publishConnectionState(.waiting)
            self.sentFrameCount = 0
            self.droppedFrameCount = 0
            self.sentFrameStart = ProcessInfo.processInfo.systemUptime
            self.windowMaxQueueLatencyMs = 0
            self.resetLinkWindow()
            // conn.start(queue:) below delivers every state change on `queue` already.
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.connectionReady = true
                    self.waitingForKeyFrame = true
                    self.sentFrameCount = 0
                    self.droppedFrameCount = 0
                    self.sentFrameStart = ProcessInfo.processInfo.systemUptime
                    self.windowMaxQueueLatencyMs = 0
                    self.resetLinkWindow()
                    self.publishConnectionState(.connected)
                    self.onClientTransport?(conn.currentPath?.usesInterfaceType(.wifi) ?? false)
                    self.onClientConnected?()
                    self.report("PC connected • starting video")
                case .waiting(let error):
                    self.pauseForConnectionWaiting()
                    self.report("PC connection waiting: \(Self.describe(error))")
                case .failed(let error):
                    self.noteDisconnect("connection failed: \(Self.describe(error))")
                    self.connectionReady = false
                    self.connection = nil
                    self.sendInFlight = false
                    self.inFlightEnqueuedAt = nil
                    self.pendingPackets.removeAll(keepingCapacity: true)
                    self.publishConnectionState(.failed)
                    self.report("PC connection failed: \(Self.describe(error))")
                    conn.cancel()
                case .cancelled:
                    self.noteDisconnect("PC connection closed")
                    self.connectionReady = false
                    self.connection = nil
                    self.sendInFlight = false
                    self.inFlightEnqueuedAt = nil
                    self.pendingPackets.removeAll(keepingCapacity: true)
                    self.publishConnectionState(.disconnected)
                    self.report("PC connection closed")
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }
        newListener.start(queue: queue)
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
            report("Encoded frame of \(frame.count) bytes exceeds the protocol limit • requesting keyframe")
            queue.async { [weak self] in
                self?.waitingForKeyFrame = true
                self?.requestKeyFrame()
            }
            return
        }

        queue.async { [weak self] in
            guard let self, let conn = self.connection,
                  self.connectionReady else { return }
            guard !self.waitingForKeyFrame || isKeyframe else { return }
            guard self.pendingPackets.count < self.maxQueuedPackets else {
                self.droppedFrameCount &+= 1
                self.linkWindowDrops &+= 1
                // A dropped frame breaks the reference chain. Stop admitting deltas
                // and ask for an IDR instead of streaming corrupt video for up to 2 s.
                self.waitingForKeyFrame = true
                self.requestKeyFrame()
                return
            }
            // Build the packet only for a frame that will be sent: no copy of a
            // 4K frame while no PC is connected or the keyframe gate is closed.
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
            self.pendingPackets.append((data: packet, enqueuedAt: ProcessInfo.processInfo.systemUptime))
            // Do not admit delta frames until this IDR was actually retained.
            if isKeyframe { self.waitingForKeyFrame = false }
            self.pumpSend(connection: conn)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.desiredRunning = false
            self?.stopLinkTimer()
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

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "POSIX \(code.rawValue) \(String(cString: strerror(code.rawValue)))"
        case .dns(let code):
            return "DNS \(code)"
        case .tls(let status):
            return "TLS \(status)"
        default:
            return String(describing: error)
        }
    }

    /// Status text for CameraStreamer, which logs it through os.Logger and shows
    /// it. StreamSender itself imports only Foundation and Network (R-ARCH-3).
    private func report(_ message: String) {
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
        inFlightEnqueuedAt = enqueuedAt
        let generation = sendGeneration
        // The connection was started on `queue`, so its completions run there.
        connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            self.sendInFlight = false
            self.inFlightEnqueuedAt = nil
            guard generation == self.sendGeneration else {
                // This completion belongs to the pre-wait transport state,
                // including any error it carries. Resume only with the
                // queued fresh IDR on the current connection generation.
                self.pumpSend(connection: connection)
                return
            }
            if let error {
                self.report("Video send failed: \(Self.describe(error))")
                self.noteDisconnect("send error: \(Self.describe(error))")
                self.connectionReady = false
                self.connection = nil
                self.pendingPackets.removeAll(keepingCapacity: true)
                self.publishConnectionState(.failed)
                connection.cancel()
                return
            }
            self.sentFrameCount &+= 1
            let sentAt = ProcessInfo.processInfo.systemUptime
            let waitedMs = (sentAt - enqueuedAt) * 1000.0
            self.windowMaxQueueLatencyMs = max(self.windowMaxQueueLatencyMs, waitedMs)
            self.linkWindowMaxQueueMs = max(self.linkWindowMaxQueueMs, waitedMs)
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
        })
    }
}
