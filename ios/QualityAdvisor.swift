import Foundation

// Pure logic for the adaptive bit rate (T5.8, gate G14). No I/O and no app or
// SDK types beyond Foundation, so it compiles and is tested on its own.

/// What the link did during one 2-second window.
struct LinkWindow {
    /// Frames the sender dropped in this window.
    var drops: UInt64
    /// Largest time (ms) a packet waited in the send queue in this window.
    var maxQueueMs: Double
    var rttMs: Double
    var rttVarMs: Double
    /// Retransmitted bytes / sent bytes, 0 when nothing was sent.
    var retransmitRatio: Double
    /// Reserved for the quality advisor (T5.7); the controller does not use it.
    var thermal: ProcessInfo.ThermalState
}

/// Lowers the average bit rate quickly when the link struggles and raises it
/// slowly once it has been healthy. It never leaves
/// `[presetTarget / 2, presetTarget]`, and it never changes the resolution.
struct BitrateController {
    static let queueLimitMs = 50.0
    static let retransmitLimit = 0.02
    static let goodWindowsToRaise = 5

    private(set) var goodWindows = 0

    /// Returns the next average bit rate in bits per second.
    mutating func nextBitrate(current: Int, presetTarget: Int, window: LinkWindow) -> Int {
        let bad = window.maxQueueMs > Self.queueLimitMs ||
            window.drops > 0 ||
            window.retransmitRatio > Self.retransmitLimit
        var next = current
        if bad {
            goodWindows = 0
            next = current * 4 / 5          // -20%
        } else {
            goodWindows += 1
            if goodWindows >= Self.goodWindowsToRaise {
                goodWindows = 0
                next = current * 11 / 10    // +10%
            }
        }
        return min(presetTarget, max(presetTarget / 2, next))
    }
}
