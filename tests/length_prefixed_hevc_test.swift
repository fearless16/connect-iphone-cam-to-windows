import Foundation

@main
struct LengthPrefixedHEVCTests {
    private static func expectEqual(_ actual: Data,
                                    _ expected: [UInt8],
                                    _ message: String) {
        precondition([UInt8](actual) == expected, message)
    }

    private static func expectFailure(_ expected: LengthPrefixedHEVCConversionError,
                                      _ bytes: [UInt8],
                                      lengthFieldBytes: Int,
                                      _ message: String) {
        do {
            _ = try LengthPrefixedHEVC.convert(Data(bytes),
                                               lengthFieldBytes: lengthFieldBytes)
            preconditionFailure("Expected failure: \(message)")
        } catch let error as LengthPrefixedHEVCConversionError {
            precondition(error == expected, "\(message): got \(error)")
        } catch {
            preconditionFailure("\(message): unexpected error \(error)")
        }
    }

    static func main() throws {
        let converted = try LengthPrefixedHEVC.convert(
            Data([0, 0, 0, 2, 0x26, 0x01,
                  0, 0, 0, 3, 0x02, 0xAA, 0xBB]),
            lengthFieldBytes: 4)
        expectEqual(converted,
                    [0, 0, 0, 1, 0x26, 0x01,
                     0, 0, 0, 1, 0x02, 0xAA, 0xBB],
                    "valid multi-NAL conversion")

        for lengthFieldBytes in 1...3 {
            let prefix = Array(repeating: UInt8(0), count: lengthFieldBytes - 1) + [2]
            let shortPrefixConverted = try LengthPrefixedHEVC.convert(
                Data(prefix + [0x26, 0x01]),
                lengthFieldBytes: lengthFieldBytes)
            expectEqual(shortPrefixConverted,
                        [0, 0, 0, 1, 0x26, 0x01],
                        "valid \(lengthFieldBytes)-byte length field")
        }
        precondition(LengthPrefixedHEVC.containsIDR(
            Data([0, 0, 0, 1, 0x26, 0x01])),
            "NAL type 19 must be an IDR")
        precondition(LengthPrefixedHEVC.containsIDR(
            Data([0, 0, 0, 1, 0x28, 0x01])),
            "NAL type 20 must be an IDR")
        precondition(!LengthPrefixedHEVC.containsIDR(
            Data([0, 0, 0, 1, 0x02, 0x01])),
            "non-IDR NAL must not be admitted as keyframe")
        // Parameter sets (VPS 32, SPS 33, PPS 34) before the IDR slice are skipped.
        precondition(LengthPrefixedHEVC.containsIDR(
            Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 1, 0x42, 0x01,
                  0, 0, 0, 1, 0x44, 0x01, 0, 0, 1, 0x26, 0x01, 0xaa])),
            "IDR after VPS/SPS/PPS must be found")
        // The first slice decides: bytes that look like an IDR header inside a
        // later NAL of a delta picture do not make it a keyframe.
        precondition(!LengthPrefixedHEVC.containsIDR(
            Data([0, 0, 0, 1, 0x02, 0x01, 0xaa, 0, 0, 1, 0x26, 0x01])),
            "the first VCL NAL (a delta slice) must decide")
        precondition(!LengthPrefixedHEVC.containsIDR(Data()), "empty data is not a keyframe")

        expectFailure(.zeroLengthNAL(offset: 0),
                      [0, 0, 0, 0],
                      lengthFieldBytes: 4,
                      "zero-length NAL")
        expectFailure(.emptySample,
                      [],
                      lengthFieldBytes: 4,
                      "empty sample")
        expectFailure(.invalidLengthFieldSize(0),
                      [1, 0x26],
                      lengthFieldBytes: 0,
                      "zero-byte length field")
        expectFailure(.invalidLengthFieldSize(5),
                      [0, 0, 0, 0, 2, 0x26, 0x01],
                      lengthFieldBytes: 5,
                      "five-byte length field")
        expectFailure(.nalTooShort(offset: 0, declared: 1),
                      [0, 0, 0, 1, 0x26],
                      lengthFieldBytes: 4,
                      "one-byte HEVC NAL")
        expectFailure(.truncatedLengthField(offset: 0, remaining: 3),
                      [0, 0, 1],
                      lengthFieldBytes: 4,
                      "truncated length field")
        expectFailure(.nalExceedsSample(offset: 0, declared: 5, remaining: 2),
                      [0, 0, 0, 5, 0x26, 0x01],
                      lengthFieldBytes: 4,
                      "oversize NAL")
        expectFailure(.truncatedLengthField(offset: 6, remaining: 2),
                      [0, 0, 0, 2, 0x26, 0x01, 0x00, 0x00],
                      lengthFieldBytes: 4,
                      "valid NAL followed by trailing bytes")

        print("length_prefixed_hevc_test: PASS")
    }
}
