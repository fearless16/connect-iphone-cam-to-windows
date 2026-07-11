import XCTest

/// Transport (usbmuxd TCP) requires a real iOS device over USB. Validated manually.
final class TransportTests: XCTestCase {
    func testTransport() throws {
        try XCTSkipIf(true, "Transport needs an iOS device over usbmuxd; validated manually on device.")
    }
}
