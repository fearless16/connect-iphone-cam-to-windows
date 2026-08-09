import Foundation
#if canImport(CoreMedia)
import CoreMedia
#endif

enum LengthPrefixedHEVCConversionError: Error, Equatable, CustomStringConvertible {
    case invalidLengthFieldSize(Int)
    case emptySample
    case truncatedLengthField(offset: Int, remaining: Int)
    case zeroLengthNAL(offset: Int)
    case nalTooShort(offset: Int, declared: Int)
    case nalExceedsSample(offset: Int, declared: Int, remaining: Int)
#if canImport(CoreMedia)
    case blockBufferCopyFailed(OSStatus)
#endif

    var description: String {
        switch self {
        case .invalidLengthFieldSize(let size):
            return "invalid NAL length-field size \(size)"
        case .emptySample:
            return "empty encoded sample"
        case .truncatedLengthField(let offset, let remaining):
            return "truncated NAL length at offset \(offset) (\(remaining) bytes remain)"
        case .zeroLengthNAL(let offset):
            return "zero-length NAL at offset \(offset)"
        case .nalTooShort(let offset, let declared):
            return "HEVC NAL at offset \(offset) is only \(declared) byte"
        case .nalExceedsSample(let offset, let declared, let remaining):
            return "NAL at offset \(offset) declares \(declared) bytes (\(remaining) remain)"
#if canImport(CoreMedia)
        case .blockBufferCopyFailed(let status):
            return "encoded block-buffer copy failed: \(status)"
#endif
        }
    }
}

enum LengthPrefixedHEVC {
    private static let annexBStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    static func convert(_ data: Data, lengthFieldBytes: Int) throws -> Data {
        try data.withUnsafeBytes {
            try convert($0, lengthFieldBytes: lengthFieldBytes)
        }
    }

#if canImport(CoreMedia)
    static func convert(_ blockBuffer: CMBlockBuffer,
                        lengthFieldBytes: Int) throws -> Data {
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else {
            throw LengthPrefixedHEVCConversionError.emptySample
        }

        var lengthAtOffset = 0
        var reportedTotalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &reportedTotalLength,
            dataPointerOut: &pointer)

        if pointerStatus == kCMBlockBufferNoErr,
           let base = pointer,
           reportedTotalLength == totalLength,
           lengthAtOffset == totalLength {
            // VideoToolbox normally produces one contiguous allocation. Parse
            // it synchronously and avoid copying on the 60 fps hot path.
            return try convert(
                UnsafeRawBufferPointer(start: UnsafeRawPointer(base),
                                       count: totalLength),
                lengthFieldBytes: lengthFieldBytes)
        }

        // GetDataPointer can expose only the first backing segment. Take one
        // exact-size owned snapshot before strict parsing; never build a
        // total-length view over a shorter contiguous region.
        var copiedSample = Data(count: totalLength)
        let copyStatus: OSStatus = copiedSample.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let destination = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer,
                                              atOffset: 0,
                                              dataLength: totalLength,
                                              destination: destination)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw LengthPrefixedHEVCConversionError.blockBufferCopyFailed(copyStatus)
        }
        return try convert(copiedSample, lengthFieldBytes: lengthFieldBytes)
    }
#endif

    static func convert(_ buffer: UnsafeRawBufferPointer,
                        lengthFieldBytes: Int) throws -> Data {
        guard (1...4).contains(lengthFieldBytes) else {
            throw LengthPrefixedHEVCConversionError.invalidLengthFieldSize(lengthFieldBytes)
        }
        guard !buffer.isEmpty else {
            throw LengthPrefixedHEVCConversionError.emptySample
        }

        let bytes = buffer.bindMemory(to: UInt8.self)
        var output = Data()
        output.reserveCapacity(buffer.count + annexBStartCode.count)
        var offset = 0

        while offset < bytes.count {
            let lengthOffset = offset
            let remainingLengthBytes = bytes.count - offset
            guard remainingLengthBytes >= lengthFieldBytes else {
                throw LengthPrefixedHEVCConversionError.truncatedLengthField(
                    offset: lengthOffset,
                    remaining: remainingLengthBytes)
            }

            var nalLength = 0
            for index in 0..<lengthFieldBytes {
                nalLength = (nalLength << 8) | Int(bytes[offset + index])
            }
            offset += lengthFieldBytes

            guard nalLength > 0 else {
                throw LengthPrefixedHEVCConversionError.zeroLengthNAL(offset: lengthOffset)
            }
            guard nalLength >= 2 else {
                throw LengthPrefixedHEVCConversionError.nalTooShort(
                    offset: lengthOffset,
                    declared: nalLength)
            }
            let remainingPayloadBytes = bytes.count - offset
            guard nalLength <= remainingPayloadBytes else {
                throw LengthPrefixedHEVCConversionError.nalExceedsSample(
                    offset: lengthOffset,
                    declared: nalLength,
                    remaining: remainingPayloadBytes)
            }

            output.append(contentsOf: annexBStartCode)
            output.append(Data(bytes: bytes.baseAddress!.advanced(by: offset),
                               count: nalLength))
            offset += nalLength
        }

        return output
    }

    /// Returns true only for HEVC IDR_W_RADL/IDR_N_LP NAL units (types 19/20).
    /// CRA/BLA pictures are deliberately not decoder join points for a newly
    /// connected Windows receiver because they may depend on earlier state.
    static func containsIDR(_ annexB: Data) -> Bool {
        let bytes = [UInt8](annexB)
        var index = 0
        while index + 3 <= bytes.count {
            let startCodeLength: Int
            if index + 3 <= bytes.count,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 1 {
                startCodeLength = 3
            } else if index + 4 <= bytes.count,
                      bytes[index] == 0,
                      bytes[index + 1] == 0,
                      bytes[index + 2] == 0,
                      bytes[index + 3] == 1 {
                startCodeLength = 4
            } else {
                index += 1
                continue
            }

            let nalOffset = index + startCodeLength
            guard nalOffset + 1 < bytes.count else { return false }
            let nalType = (bytes[nalOffset] >> 1) & 0x3f
            if (19...20).contains(nalType) { return true }
            index = nalOffset + 2
        }
        return false
    }
}
