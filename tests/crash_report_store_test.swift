import Foundation

@main
struct CrashReportStoreTests {
    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func main() {
        // Framing: magic, little-endian length, payload; bounds enforced.
        let payload = Data("{\"a\":1}".utf8)
        let framed = CrashReportFraming.frame(payload)
        expect(framed != nil, "a small payload frames")
        expect(Array(framed!.prefix(4)) == [0x49, 0x43, 0x52, 0x50], "magic is ICRP")
        expect(Array(framed![4..<8]) == [UInt8(payload.count), 0, 0, 0], "length is u32 little-endian")
        expect(framed!.suffix(payload.count) == payload, "payload follows the header")
        expect(framed!.count == CrashReportFraming.headerSize + payload.count, "total size")
        expect(CrashReportFraming.frame(Data()) == nil, "empty payload is rejected")
        expect(CrashReportFraming.frame(Data(count: CrashReportFraming.maxPayloadBytes + 1)) == nil,
               "oversized payload is rejected")
        expect(CrashReportFraming.frame(Data(repeating: 0x20, count: CrashReportFraming.maxPayloadBytes)) != nil,
               "a payload at the cap is accepted")
        expect(CrashReportFraming.port == 12347, "side channel port")

        // Store: save, replace, read back, clear.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-report-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CrashReportStore(directory: dir)
        expect(store.pending == nil, "nothing pending at first")
        expect(store.save(Data("one".utf8)), "save succeeds")
        expect(store.pending == Data("one".utf8), "pending returns the saved report")
        expect(store.save(Data("two".utf8)), "a newer report replaces the old one")
        expect(store.pending == Data("two".utf8), "only the newest report is kept")
        expect(!store.save(Data()), "empty report is not saved")
        expect(!store.save(Data(count: CrashReportFraming.maxPayloadBytes + 1)), "oversized report is not saved")
        expect(store.pending == Data("two".utf8), "a rejected save keeps the previous report")
        store.clear()
        expect(store.pending == nil, "clear removes the report")
        store.clear()   // clearing twice must not fail

        // An ack for a delivered report never deletes a newer one saved meanwhile.
        expect(store.save(Data("old".utf8)), "save the report being delivered")
        expect(store.save(Data("new".utf8)), "a newer report arrives during delivery")
        expect(!store.clear(matching: Data("old".utf8)), "the old ack does not clear the newer report")
        expect(store.pending == Data("new".utf8), "the newer report is still pending")
        expect(store.clear(matching: Data("new".utf8)), "the matching ack clears it")
        expect(store.pending == nil, "nothing pending after the matching ack")
        expect(!store.clear(matching: Data("new".utf8)), "a repeated ack finds nothing to clear")

        // Envelope: valid JSON with context, within the cap.
        let when = Date(timeIntervalSince1970: 0)
        let small = CrashReportStore.envelope(diagnostics: Data("{\"crashDiagnostics\":[{\"x\":1}]}".utf8),
                                              receivedAt: when, app: "1.0 (2)", os: "iOS 26", device: "iPhone15,2")
        let object = try! JSONSerialization.jsonObject(with: small) as! [String: Any]
        expect(object["app"] as? String == "1.0 (2)", "envelope carries the app version")
        expect(object["device"] as? String == "iPhone15,2", "envelope carries the device")
        expect(object["receivedAt"] as? String == "1970-01-01T00:00:00Z", "envelope carries the time")
        expect((object["diagnostics"] as? [String: Any])?["crashDiagnostics"] != nil, "diagnostics are embedded as JSON")

        // A huge payload shrinks to something that still fits and still parses.
        let big = Data(("{\"blob\":\"" + String(repeating: "x", count: 600_000) + "\"}").utf8)
        let shrunk = CrashReportStore.envelope(diagnostics: big, receivedAt: when, app: "1", os: "2", device: "3")
        expect(shrunk.count <= CrashReportFraming.maxPayloadBytes, "huge diagnostics fit the cap, got \(shrunk.count)")
        let shrunkObject = try! JSONSerialization.jsonObject(with: shrunk) as! [String: Any]
        let shrunkDiagnostics = shrunkObject["diagnostics"] as! [String: Any]
        expect(shrunkDiagnostics["truncated"] as? Bool == true, "huge diagnostics are marked truncated")
        expect(shrunkDiagnostics["originalBytes"] as? Int == big.count, "the original size is recorded")

        // Not-JSON input still yields a valid, small envelope.
        let junk = CrashReportStore.envelope(diagnostics: Data([0xFF, 0xFE, 0x00]), receivedAt: when,
                                             app: "1", os: "2", device: "3")
        expect((try? JSONSerialization.jsonObject(with: junk)) != nil, "junk input still gives valid JSON")

        print("crash_report_store_test: OK")
    }
}
