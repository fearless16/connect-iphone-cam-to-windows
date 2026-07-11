import XCTest
import AVFoundation

/// Validates camera discovery. Skips where no physical back camera exists (CI Mac / simulator).
final class CaptureTests: XCTestCase {
    func testBackCameraPresent() throws {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTripleCamera, .builtInDualCamera],
            mediaType: .video,
            position: .back).devices
        try XCTSkipUnless(!devices.isEmpty, "No back camera on this host (CI Mac / simulator).")
        XCTAssertFalse(devices.isEmpty)
    }
}
