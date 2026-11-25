import Foundation

// Shared golden vector with tests/protocol_selftest.cpp: the Swift mirror must
// encode byte-for-byte what protocol/stream_protocol.h writes.
@main
struct StreamHeaderTests {
    static let goldenHeader: [UInt8] = [
        0x4D, 0x43, 0x50, 0x49, 0x2A, 0x00, 0x00, 0x00, 0xB1, 0x68, 0xDE,
        0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
    ]

    static func main() {
        let encoded = StreamHeader(
            magic: StreamHeader.magic,
            frameNumber: 42,
            timestampUs: 987_654_321,
            codec: StreamCodec.hevc.rawValue,
            frameSize: 1024
        ).encode()

        guard encoded.count == StreamHeader.size else {
            fatalError("StreamHeader.encode() wrote \(encoded.count) bytes; expected \(StreamHeader.size)")
        }
        guard Array(encoded) == goldenHeader else {
            fatalError("StreamHeader.encode() drifted from the C wire layout: \(Array(encoded))")
        }
        print("stream_header_test: OK")
    }
}
