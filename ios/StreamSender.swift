import Foundation
import Network

/// Step 5: listen on a TCP port. usbmuxd tunnels it over USB automatically,
/// so the Windows receiver connects via usbmuxd_connect(device_id, PORT).
final class StreamSender {

    static let port: UInt16 = 12345

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "sender")
    // Keep at most one packet pending in Network.framework. At 4K60, queueing
    // encoded frames trades a brief stall for seconds of latency and memory use.
    private var sendInFlight = false

    func start() {
        let params = NWParameters.tcp
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: StreamSender.port))
        } catch {
            print("ERROR: NWListener \(error)")
            return
        }
        listener?.stateUpdateHandler = { s in
            print("SENDER: listener \(s)")
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.queue.async {
                self?.connection?.cancel()
                self?.connection = conn
                self?.sendInFlight = false
                conn.start(queue: self?.queue ?? .main)
                print("SENDER: client connected")
            }
        }
        listener?.start(queue: queue)
        print("SENDER: listening on port \(StreamSender.port)")
    }

    /// Send a complete protocol packet (header + Annex-B frame).
    func send(frameNumber: UInt32, timestampUs: UInt64, codec: UInt8, frame: Data) {
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
            guard let self, let conn = self.connection, !self.sendInFlight else { return }
            self.sendInFlight = true
            conn.send(content: packet, completion: .contentProcessed { error in
                self.queue.async {
                    self.sendInFlight = false
                    if let error {
                        print("SENDER: send failed \(error)")
                    }
                }
            })
        }
    }
}
