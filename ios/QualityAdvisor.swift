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

/// A recommendation to move to another preset. The app only shows it; the user
/// decides (T5.7). Indexes are positions in the 60 fps presets, 720p first.
enum Advice: Equatable {
    case down(toIndex: Int, reason: String)
    case up(toIndex: Int, reason: String)
}

/// Decides when to suggest a lower or higher preset from the same 2-second
/// windows the bit rate controller sees. Reasons never name a preset: the
/// caller owns the preset names.
struct PresetAdvisor {
    static let floorWindowsToStepDown = 3
    static let dropWindowsToStepDown = 2
    static let recentWindowCount = 5
    static let calmSecondsToStepUp: TimeInterval = 30
    static let calmQueueMs = 15.0
    static let minSecondsBetweenAdvice: TimeInterval = 60

    private var floorWindows = 0
    private var recentDrops: [Bool] = []
    private var calmSince: TimeInterval?
    private var lastAdviceAt: TimeInterval?

    /// Call once per window. `now` is in seconds and is injected for tests.
    /// `bitrateAtFloor` and `bitrateAtFull` describe the rate after this window.
    mutating func advice(presetIndex: Int, presetCount: Int, overWiFi: Bool,
                         bitrateAtFloor: Bool, bitrateAtFull: Bool,
                         window: LinkWindow, now: TimeInterval) -> Advice? {
        floorWindows = bitrateAtFloor ? floorWindows + 1 : 0
        recentDrops.append(window.drops > 0)
        if recentDrops.count > Self.recentWindowCount { recentDrops.removeFirst() }

        let thermal = window.thermal.rawValue
        let hot = thermal >= ProcessInfo.ThermalState.serious.rawValue
        let calm = bitrateAtFull && window.drops == 0 &&
            window.maxQueueMs < Self.calmQueueMs &&
            thermal <= ProcessInfo.ThermalState.fair.rawValue
        calmSince = calm ? (calmSince ?? now) : nil

        if let last = lastAdviceAt, now - last < Self.minSecondsBetweenAdvice { return nil }

        if presetIndex > 0 {
            let dropWindows = recentDrops.filter { $0 }.count
            var reason: String?
            if hot {
                reason = "Phone is hot"
            } else if floorWindows >= Self.floorWindowsToStepDown {
                if overWiFi && window.retransmitRatio >= 0.01 {
                    reason = String(format: "Wi-Fi retransmits %.0f%%", window.retransmitRatio * 100)
                } else {
                    reason = overWiFi ? "Wi-Fi link is weak" : "USB link is too slow"
                }
            } else if dropWindows >= Self.dropWindowsToStepDown {
                reason = "Frames are being dropped"
            }
            if let reason {
                issued(at: now)
                return .down(toIndex: presetIndex - 1, reason: reason)
            }
        }

        if presetIndex < presetCount - 1, let since = calmSince,
           now - since >= Self.calmSecondsToStepUp {
            issued(at: now)
            return .up(toIndex: presetIndex + 1, reason: "Link has been steady for 30 s")
        }
        return nil
    }

    /// Fresh evidence is needed for the next recommendation.
    private mutating func issued(at now: TimeInterval) {
        lastAdviceAt = now
        floorWindows = 0
        recentDrops.removeAll()
        calmSince = nil
    }
}
