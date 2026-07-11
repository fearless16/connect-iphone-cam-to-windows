import XCTest

/// Decoder requires FFmpeg + a captured .h265 sample. Validated manually / on Windows.
final class DecoderTests: XCTestCase {
    func testDecoder() throws {
        try XCTSkipIf(true, "Decoder needs FFmpeg + captured .h265; validated manually.")
    }
}
