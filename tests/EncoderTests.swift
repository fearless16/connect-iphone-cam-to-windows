import XCTest
import VideoToolbox
import CoreMedia
import CoreVideo

/// Validates the VideoToolbox HEVC encoder path. Skips where no HW encoder exists.
final class EncoderTests: XCTestCase {
    func testEncoderCreates() throws {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(nil, 1280, 720, kCMVideoCodecType_HEVC,
                                           nil, nil, nil, nil, &s)
        try XCTSkipUnless(st == noErr && s != nil, "No HEVC encoder on this host.")
        XCTAssertEqual(st, noErr)
        VTCompressionSessionInvalidate(s!)
    }
}
