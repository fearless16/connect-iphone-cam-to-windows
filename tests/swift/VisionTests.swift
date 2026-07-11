import XCTest

/// Vision person segmentation requires a real device + the ML model. Validated manually.
final class VisionTests: XCTestCase {
    func testVision() throws {
        try XCTSkipIf(true, "Vision segmentation validated manually on device (step 9).")
    }
}
