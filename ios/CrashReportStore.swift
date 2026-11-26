import Foundation

/// T6.1: framing for the crash-report side channel (port 12347). This is NOT the
/// video wire format: 4-byte magic "ICRP", a u32 little-endian payload length,
/// then the JSON payload. The receiver answers with one ack byte once the report
/// is saved, and only then does the phone delete its copy.
enum CrashReportFraming {
    static let port: UInt16 = 12347
    static let magic: [UInt8] = [0x49, 0x43, 0x52, 0x50]   // "ICRP"
    static let headerSize = 8
    static let maxPayloadBytes = 256 * 1024
    static let ack: UInt8 = 0x06

    static func frame(_ payload: Data) -> Data? {
        guard !payload.isEmpty, payload.count <= maxPayloadBytes else { return nil }
        var out = Data(magic)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// One small file holding the newest undelivered crash report. Never grows
/// beyond `CrashReportFraming.maxPayloadBytes`, and a newer report replaces it.
struct CrashReportStore {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("pending-crash-report.json")
    }

    /// Caches is the right home: small, regenerable, and not backed up.
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// The pending report, or nil when there is none (or it is unusable).
    var pending: Data? {
        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty, data.count <= CrashReportFraming.maxPayloadBytes else { return nil }
        return data
    }

    @discardableResult
    func save(_ payload: Data) -> Bool {
        guard !payload.isEmpty, payload.count <= CrashReportFraming.maxPayloadBytes else { return false }
        do {
            try payload.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Deletes the pending report only if it is still `delivered`. A newer report
    /// saved while the older one was being sent must survive the older one's ack.
    @discardableResult
    func clear(matching delivered: Data) -> Bool {
        guard pending == delivered else { return false }
        clear()
        return true
    }

    /// Wraps MetricKit's JSON with the context a debugger needs. If the result
    /// would exceed the size cap, the diagnostics shrink to a text head, then to
    /// a stub, so a report is always small enough to store and send.
    static func envelope(diagnostics: Data, receivedAt: Date, app: String, os: String, device: String) -> Data {
        func encode(_ diagnosticsValue: Any) -> Data? {
            let object: [String: Any] = [
                "receivedAt": ISO8601DateFormatter().string(from: receivedAt),
                "app": app,
                "os": os,
                "device": device,
                "diagnostics": diagnosticsValue,
            ]
            guard JSONSerialization.isValidJSONObject(object) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let parsed = (try? JSONSerialization.jsonObject(with: diagnostics)) ?? NSNull()
        if let full = encode(parsed), full.count <= CrashReportFraming.maxPayloadBytes { return full }
        let head = String(decoding: diagnostics.prefix(64 * 1024), as: UTF8.self)
        let shrunk: [String: Any] = ["truncated": true, "originalBytes": diagnostics.count, "head": head]
        if let data = encode(shrunk), data.count <= CrashReportFraming.maxPayloadBytes { return data }
        let stub: [String: Any] = ["truncated": true, "originalBytes": diagnostics.count]
        return encode(stub) ?? Data("{\"truncated\":true}".utf8)
    }
}
