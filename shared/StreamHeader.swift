import Foundation

/// Mirrors `stream_protocol.h`. Keep both files in sync by hand.
/// Wire format: one Annex-B encoded frame per packet, little-endian.

enum StreamCodec: UInt8 {
    case hevc = 0
    case h264 = 1
}

struct StreamHeader {
    static let magic: UInt32 = 0x4950434D // "IPCM"
    static let size = 21                  // magic(4)+frame(4)+ts(8)+codec(1)+size(4)

    let magic: UInt32
    let frameNumber: UInt32
    let timestampUs: UInt64
    let codec: UInt8
    let frameSize: UInt32

    func encode() -> Data {
        var out = Data(count: StreamHeader.size)
        out[0]  = UInt8(StreamHeader.magic & 0xFF)
        out[1]  = UInt8((StreamHeader.magic >> 8) & 0xFF)
        out[2]  = UInt8((StreamHeader.magic >> 16) & 0xFF)
        out[3]  = UInt8((StreamHeader.magic >> 24) & 0xFF)
        out[4]  = UInt8(frameNumber & 0xFF)
        out[5]  = UInt8((frameNumber >> 8) & 0xFF)
        out[6]  = UInt8((frameNumber >> 16) & 0xFF)
        out[7]  = UInt8((frameNumber >> 24) & 0xFF)
        out[8]  = UInt8(timestampUs & 0xFF)
        out[9]  = UInt8((timestampUs >> 8) & 0xFF)
        out[10] = UInt8((timestampUs >> 16) & 0xFF)
        out[11] = UInt8((timestampUs >> 24) & 0xFF)
        out[12] = UInt8((timestampUs >> 32) & 0xFF)
        out[13] = UInt8((timestampUs >> 40) & 0xFF)
        out[14] = UInt8((timestampUs >> 48) & 0xFF)
        out[15] = UInt8((timestampUs >> 56) & 0xFF)
        out[16] = codec
        out[17] = UInt8(frameSize & 0xFF)
        out[18] = UInt8((frameSize >> 8) & 0xFF)
        out[19] = UInt8((frameSize >> 16) & 0xFF)
        out[20] = UInt8((frameSize >> 24) & 0xFF)
        return out
    }
}
