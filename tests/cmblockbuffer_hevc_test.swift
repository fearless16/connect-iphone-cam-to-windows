import CoreMedia
import Foundation

@main
struct CMBlockBufferHEVCTests {
    private static func makeBlock(_ bytes: [UInt8]) -> CMBlockBuffer {
        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block)
        precondition(createStatus == kCMBlockBufferNoErr)
        precondition(CMBlockBufferAssureBlockMemory(block!) == kCMBlockBufferNoErr)
        let copyStatus = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                                          blockBuffer: block!,
                                          offsetIntoDestination: 0,
                                          dataLength: bytes.count)
        }
        precondition(copyStatus == kCMBlockBufferNoErr)
        return block!
    }

    private static func makeFragmentedBlock(_ first: [UInt8],
                                            _ second: [UInt8]) -> CMBlockBuffer {
        let firstBlock = makeBlock(first)
        let secondBlock = makeBlock(second)
        var parent: CMBlockBuffer?
        precondition(CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault,
                                              capacity: 2,
                                              flags: 0,
                                              blockBufferOut: &parent) == kCMBlockBufferNoErr)
        precondition(CMBlockBufferAppendBufferReference(parent!,
                                                        targetBBuf: firstBlock,
                                                        offsetToData: 0,
                                                        dataLength: first.count,
                                                        flags: 0) == kCMBlockBufferNoErr)
        precondition(CMBlockBufferAppendBufferReference(parent!,
                                                        targetBBuf: secondBlock,
                                                        offsetToData: 0,
                                                        dataLength: second.count,
                                                        flags: 0) == kCMBlockBufferNoErr)
        return parent!
    }

    private static func assertFragmented(_ block: CMBlockBuffer) {
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &pointer)
        precondition(status != kCMBlockBufferNoErr || lengthAtOffset < totalLength,
                     "test fixture unexpectedly became contiguous")
    }

    static func main() throws {
        // Split the four-byte NAL length prefix across two backing blocks. A
        // parser using totalLength against the first pointer would over-read.
        let valid = makeFragmentedBlock([0x00, 0x00],
                                        [0x00, 0x02, 0x26, 0x01])
        assertFragmented(valid)
        let converted = try LengthPrefixedHEVC.convert(valid, lengthFieldBytes: 4)
        precondition([UInt8](converted) == [0, 0, 0, 1, 0x26, 0x01])

        let truncated = makeFragmentedBlock([0x00, 0x00],
                                            [0x00, 0x05, 0x26, 0x01])
        assertFragmented(truncated)
        do {
            _ = try LengthPrefixedHEVC.convert(truncated, lengthFieldBytes: 4)
            preconditionFailure("fragmented truncated sample must be rejected")
        } catch let error as LengthPrefixedHEVCConversionError {
            precondition(error == .nalExceedsSample(offset: 0,
                                                     declared: 5,
                                                     remaining: 2))
        }

        print("cmblockbuffer_hevc_test: PASS")
    }
}
