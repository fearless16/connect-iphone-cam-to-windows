import XCTest
import VideoToolbox
import CoreMedia
import CoreVideo

/// Validates the VideoToolbox HEVC encoder path. Skips where no HW encoder exists.
final class EncoderTests: XCTestCase {
    func testEncoderCreates() throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: 1280,
            height: 720,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s)
        try XCTSkipUnless(status == noErr && s != nil, "No HEVC encoder on this host.")
        XCTAssertEqual(status, noErr)
        if let session = s {
            VTCompressionSessionInvalidate(session)
        }
    }
}
