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

    func start() {
        // A foreground transition can call start again. Keep the original
        // listening socket alive rather than creating a competing listener.
        guard listener == nil else { return }
        let params = NWParameters.tcp
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: StreamSender.port))
        } catch {
            print("ERROR: NWListener \(error)")
            return
        }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.report("USB stream service ready")
            case .waiting(let error):
                self?.report("USB listener waiting: \(error.localizedDescription)")
            case .failed(let error):
                self?.report("USB listener failed: \(error.localizedDescription)")
            case .cancelled:
                self?.report("USB listener stopped")
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in
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
        listener?.start(queue: queue)
        print("SENDER: listening on port \(StreamSender.port)")
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
