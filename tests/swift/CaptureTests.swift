import XCTest
import AVFoundation

/// Validates camera discovery. Skips where no physical back camera exists (CI Mac / simulator).
final class CaptureTests: XCTestCase {
    func testBackCameraPresent() throws {
        #if canImport(UIKit)
        // iOS / simulator: the device may expose dual or triple camera modules.
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTripleCamera,
            .builtInDualCamera
        ]
        #else
        // macOS has no dual/triple camera types; only the wide-angle module exists.
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        #endif

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back).devices
        try XCTSkipUnless(!devices.isEmpty, "No back camera on this host (CI Mac / simulator).")
        XCTAssertFalse(devices.isEmpty)
    }
}
