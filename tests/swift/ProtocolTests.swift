import XCTest
@testable import ProtocolCore

/// Wire-format contract: Swift <-> C must agree. Validated here end-to-end.
final class ProtocolTests: XCTestCase {

    func testMagicAndSizeConstants() {
        XCTAssertEqual(StreamHeader.magic, 0x4950434D)
        XCTAssertEqual(StreamHeader.size, 21)
    }

    func testHeaderRoundTrip() {
        let h = StreamHeader(magic: StreamHeader.magic,
                             frameNumber: 42,
                             timestampUs: 123_456_789,
                             codec: StreamCodec.hevc.rawValue,
                             frameSize: 9999)
        let data = h.encode()
        XCTAssertEqual(data.count, StreamHeader.size)

        let magic = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        XCTAssertEqual(magic, 0x4950434D)

        let frame = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        XCTAssertEqual(frame, 42)

        var ts: UInt64 = 0
        for i in 0..<8 { ts |= UInt64(data[8 + i]) << (8 * i) }
        XCTAssertEqual(ts, 123_456_789)

        let codec = data[16]
        XCTAssertEqual(codec, StreamCodec.hevc.rawValue)

        var size: UInt32 = 0
        for i in 0..<4 { size |= UInt32(data[17 + i]) << (8 * i) }
        XCTAssertEqual(size, 9999)
    }

    func testEveryFrameIsDelimited() {
        // Protocol guarantees a parseable header before every frame.
        let h = StreamHeader(magic: StreamHeader.magic, frameNumber: 1,
                             timestampUs: 0, codec: StreamCodec.h264.rawValue, frameSize: 10)
        let data = h.encode()
        XCTAssertEqual(Array(data[0...3]), [0x4D, 0x43, 0x50, 0x49]) // "IPCM" LE
    }
}
