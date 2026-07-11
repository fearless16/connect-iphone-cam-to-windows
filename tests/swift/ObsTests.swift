import XCTest

/// OBS virtual camera requires the DirectShow filter + Windows host. Validated manually.
final class ObsTests: XCTestCase {
    func testObs() throws {
        try XCTSkipIf(true, "OBS virtual camera validated manually on Windows (step 8).")
    }
}
