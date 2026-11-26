import Foundation
import MetricKit
import Network

/// T6.1: keeps the newest crash report from the previous run and hands it to the
/// PC once. MetricKit delivers crash diagnostics on the next launch, so nothing
/// runs while streaming. The listener on port 12347 exists only while a report is
/// waiting, follows the same USB-only / Wi-Fi opt-in rule as the stream (D4), and
/// is closed again after the PC acknowledges. It never touches the video path.
final class CrashReportService: NSObject, MXMetricManagerSubscriber {

    private let store: CrashReportStore
    private let queue = DispatchQueue(label: "crash-report", qos: .utility)
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var wifiEnabled = false
    private var started = false
    private var retryAttempt = 0
    /// Status text for CameraStreamer, which logs it through os.Logger and shows
    /// it (print never reaches a release build's log). Set before start();
    /// called on the service queue.
    var onStatus: ((String) -> Void)?

    init(store: CrashReportStore = CrashReportStore(directory: CrashReportStore.defaultDirectory())) {
        self.store = store
        super.init()
    }

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            MXMetricManager.shared.add(self)
            self.serveIfPending()
        }
    }

    func stop() {
        queue.async {
            guard self.started else { return }
            self.started = false
            MXMetricManager.shared.remove(self)
            self.stopListening()
        }
    }

    /// The allowed interfaces are fixed when a listener is created, so a change
    /// rebuilds an existing listener.
    func setWiFiEnabled(_ enabled: Bool) {
        queue.async {
            guard self.wifiEnabled != enabled else { return }
            self.wifiEnabled = enabled
            if self.listener != nil {
                self.stopListening()
                self.serveIfPending()
            }
        }
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // The newest payload that actually contains a crash replaces any older report.
        guard let payload = payloads.last(where: { !($0.crashDiagnostics ?? []).isEmpty }) else { return }
        let json = payload.jsonRepresentation()
        queue.async {
            let envelope = CrashReportStore.envelope(
                diagnostics: json,
                receivedAt: Date(),
                app: Self.appDescription(),
                os: ProcessInfo.processInfo.operatingSystemVersionString,
                device: Self.machineIdentifier())
            if self.store.save(envelope) {
                self.onStatus?("Crash report from the last run stored (\(envelope.count) bytes) • sent on the next PC connection")
                self.serveIfPending()
            }
        }
    }

    // MARK: Listener

    private func serveIfPending() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started, listener == nil, store.pending != nil else { return }
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        // D4: without the Wi-Fi opt-in, refuse every non-USB interface.
        if !wifiEnabled { params.prohibitedInterfaceTypes = [.wifi, .cellular] }
        params.allowLocalEndpointReuse = true
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: CrashReportFraming.port))
        } catch {
            onStatus?("Crash report listener error: \(error)")
            scheduleRetry()
            return
        }
        listener = newListener
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            self.queue.async {
                guard self.listener === newListener else { return }
                switch state {
                case .ready:
                    self.retryAttempt = 0
                case .failed:
                    self.stopListening()
                    self.scheduleRetry()
                default:
                    break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.queue.async { self.serve(connection) }
        }
        newListener.start(queue: queue)
    }

    private func serve(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard activeConnection == nil,
              let payload = store.pending,
              let framed = CrashReportFraming.frame(payload) else {
            connection.cancel()
            return
        }
        activeConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async {
                    if self.activeConnection === connection { self.activeConnection = nil }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A stalled peer must not keep the socket (or the listener) busy.
        queue.asyncAfter(deadline: .now() + 15) { [weak connection] in connection?.cancel() }
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                if data?.first == CrashReportFraming.ack {
                    self.queue.async {
                        // A newer report saved during delivery stays pending.
                        guard self.store.clear(matching: payload) else { return }
                        self.onStatus?("Crash report delivered to the PC • local copy deleted")
                        self.stopListening()
                    }
                }
                connection.cancel()
            }
        })
    }

    private func stopListening() {
        dispatchPrecondition(condition: .onQueue(queue))
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
    }

    private func scheduleRetry() {
        guard retryAttempt < 5 else { return }
        retryAttempt += 1
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.serveIfPending() }
    }

    // MARK: Context

    private static func appDescription() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func machineIdentifier() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
