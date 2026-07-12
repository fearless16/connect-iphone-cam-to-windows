import Foundation
import Network

/// Step 5: listen on a TCP port. usbmuxd tunnels it over USB automatically,
/// so the Windows receiver connects via usbmuxd_connect(device_id, PORT).
final class StreamSender {

    static let port: UInt16 = 12345

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "sender")

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
            self?.connection?.cancel()
            self?.connection = conn
            conn.start(queue: self?.queue ?? .main)
            print("SENDER: client connected")
        }
        listener?.start(queue: queue)
        print("SENDER: listening on port \(StreamSender.port)")
    }

    /// Send a complete protocol packet (header + Annex-B frame).
    func send(frameNumber: UInt32, timestampUs: UInt64, codec: UInt8, frame: Data) {
        guard let conn = connection else { return }
        let header = StreamHeader(
            magic: StreamHeader.magic,
            frameNumber: frameNumber,
            timestampUs: timestampUs,
            codec: codec,
            frameSize: UInt32(frame.count)
        ).encode()
        conn.send(content: header, completion: .contentProcessed({ _ in }))
        conn.send(content: frame, completion: .contentProcessed({ _ in }))
    }
}
