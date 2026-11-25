import Foundation

@main
struct QualityAdvisorTests {
    static let target = 40_000_000

    static func window(queueMs: Double = 0,
                       drops: UInt64 = 0,
                       retransmit: Double = 0,
                       thermal: ProcessInfo.ThermalState = .nominal) -> LinkWindow {
        LinkWindow(drops: drops, maxQueueMs: queueMs, rttMs: 5, rttVarMs: 1,
                   retransmitRatio: retransmit, thermal: thermal)
    }

    /// One advisor window at time `now`, with the 3 presets and Wi-Fi by default.
    static func advise(_ advisor: inout PresetAdvisor,
                       index: Int = 1,
                       wifi: Bool = true,
                       floor: Bool = false,
                       full: Bool = false,
                       _ window: LinkWindow,
                       at now: TimeInterval) -> Advice? {
        advisor.advice(presetIndex: index, presetCount: 3, overWiFi: wifi,
                       bitrateAtFloor: floor, bitrateAtFull: full,
                       window: window, now: now)
    }

    static func testAdvisor() {
        // Down after 3 windows in a row at the bit rate floor, with a short reason.
        var advisor = PresetAdvisor()
        let weakLink = window(retransmit: 0.04)
        expect(advise(&advisor, index: 2, floor: true, weakLink, at: 0) == nil, "1 floor window is not enough")
        expect(advise(&advisor, index: 2, floor: true, weakLink, at: 2) == nil, "2 floor windows are not enough")
        expect(advise(&advisor, index: 2, floor: true, weakLink, at: 4)
                == .down(toIndex: 1, reason: "Wi-Fi retransmits 4%"),
               "3 floor windows must advise one preset down")

        // At most one advice per 60 s, even though the evidence continues.
        for now in stride(from: 6.0, to: 64.0, by: 2.0) {
            expect(advise(&advisor, index: 2, floor: true, weakLink, at: now) == nil,
                   "no second advice before 60 s have passed (t=\(now))")
        }
        expect(advise(&advisor, index: 2, floor: true, weakLink, at: 64)
                == .down(toIndex: 1, reason: "Wi-Fi retransmits 4%"),
               "advice is allowed again after 60 s")

        // A floor streak that is broken does not count.
        advisor = PresetAdvisor()
        _ = advise(&advisor, index: 2, floor: true, weakLink, at: 0)
        _ = advise(&advisor, index: 2, floor: true, weakLink, at: 2)
        expect(advise(&advisor, index: 2, floor: false, weakLink, at: 4) == nil, "leaving the floor resets the streak")
        expect(advise(&advisor, index: 2, floor: true, weakLink, at: 6) == nil, "the streak starts again at 1")

        // USB wording does not mention Wi-Fi.
        advisor = PresetAdvisor()
        _ = advise(&advisor, index: 2, wifi: false, floor: true, window(), at: 0)
        _ = advise(&advisor, index: 2, wifi: false, floor: true, window(), at: 2)
        expect(advise(&advisor, index: 2, wifi: false, floor: true, window(), at: 4)
                == .down(toIndex: 1, reason: "USB link is too slow"), "USB reason")

        // Up after 30 s in a row at the full rate, then rate limited.
        advisor = PresetAdvisor()
        let calm = window(queueMs: 5)
        for now in stride(from: 0.0, to: 30.0, by: 2.0) {
            expect(advise(&advisor, full: true, calm, at: now) == nil, "no up-advice before 30 s (t=\(now))")
        }
        expect(advise(&advisor, full: true, calm, at: 30)
                == .up(toIndex: 2, reason: "Link has been steady for 30 s"), "30 calm seconds advise up")
        for now in stride(from: 32.0, to: 90.0, by: 2.0) {
            expect(advise(&advisor, full: true, calm, at: now) == nil, "no second advice before 60 s (t=\(now))")
        }
        expect(advise(&advisor, full: true, calm, at: 90) != nil, "up-advice is allowed again after 60 s")

        // Up needs every window calm: a queue of 20 ms (limit 15) or a drop blocks it,
        // and a window at less than the full rate restarts the 30 s.
        advisor = PresetAdvisor()
        for now in stride(from: 0.0, through: 120.0, by: 2.0) {
            expect(advise(&advisor, full: true, window(queueMs: 20), at: now) == nil, "queue 20 ms blocks up")
        }
        advisor = PresetAdvisor()
        for now in stride(from: 0.0, to: 28.0, by: 2.0) { _ = advise(&advisor, full: true, calm, at: now) }
        _ = advise(&advisor, full: false, calm, at: 28)
        expect(advise(&advisor, full: true, calm, at: 30) == nil, "a window below the full rate restarts the 30 s")
        expect(advise(&advisor, full: true, calm, at: 58) == nil, "28 s after the restart is still too early")
        expect(advise(&advisor, full: true, calm, at: 60) != nil, "30 s after the restart advises up")

        // Hot phone: down advice, and never up-advice, whatever else is true.
        advisor = PresetAdvisor()
        expect(advise(&advisor, index: 1, full: true, window(thermal: .serious), at: 0)
                == .down(toIndex: 0, reason: "Phone is hot"), "serious thermal advises down")
        advisor = PresetAdvisor()
        for now in stride(from: 0.0, through: 120.0, by: 2.0) {
            expect(advise(&advisor, index: 0, full: true, window(thermal: .serious), at: now) == nil,
                   "no up-advice while thermal is serious")
            expect(advise(&advisor, index: 0, full: true, window(thermal: .critical), at: now + 1) == nil,
                   "no up-advice while thermal is critical")
        }
        advisor = PresetAdvisor()
        for now in stride(from: 0.0, to: 30.0, by: 2.0) { _ = advise(&advisor, index: 0, full: true, window(thermal: .fair), at: now) }
        expect(advise(&advisor, index: 0, full: true, window(thermal: .fair), at: 30)
                == .up(toIndex: 1, reason: "Link has been steady for 30 s"), "thermal fair still allows up")

        // Drops in 2 of the last 5 windows advise down; 2 drops 5 windows apart do not.
        advisor = PresetAdvisor()
        let dropping = window(drops: 2)
        expect(advise(&advisor, dropping, at: 0) == nil, "one drop window is not enough")
        expect(advise(&advisor, window(), at: 2) == nil, "a good window in between")
        expect(advise(&advisor, dropping, at: 4) == .down(toIndex: 0, reason: "Frames are being dropped"),
               "2 drop windows in 5 advise down")
        advisor = PresetAdvisor()
        _ = advise(&advisor, dropping, at: 0)
        for now in stride(from: 2.0, through: 8.0, by: 2.0) { _ = advise(&advisor, window(), at: now) }
        expect(advise(&advisor, dropping, at: 10) == nil, "drops 5 windows apart are not 2 of the last 5")

        // Steady good windows give no advice at all.
        advisor = PresetAdvisor()
        for now in stride(from: 0.0, through: 300.0, by: 2.0) {
            expect(advise(&advisor, index: 2, full: true, calm, at: now) == nil, "no up-advice from the top preset")
        }
        advisor = PresetAdvisor()
        for now in stride(from: 0.0, through: 300.0, by: 2.0) {
            expect(advise(&advisor, index: 1, full: false, calm, at: now) == nil, "steady windows below full: no advice")
        }

        // The lowest preset never gets down-advice.
        advisor = PresetAdvisor()
        for now in stride(from: 0.0, through: 200.0, by: 2.0) {
            expect(advise(&advisor, index: 0, floor: true, window(drops: 4, thermal: .serious), at: now) == nil,
                   "no down-advice from the lowest preset")
        }
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("quality_advisor_test: \(message)") }
    }

    static func main() {
        // One bad window lowers the rate to 80%, for each of the three signals.
        for bad in [window(queueMs: 60), window(drops: 1), window(retransmit: 0.03)] {
            var controller = BitrateController()
            expect(controller.nextBitrate(current: target, presetTarget: target, window: bad) == 32_000_000,
                   "a bad window must give 80%")
        }

        // The limits are exclusive: exactly 50 ms or 2% is still good.
        do {
            var controller = BitrateController()
            let edge = window(queueMs: 50, retransmit: 0.02)
            expect(controller.nextBitrate(current: 32_000_000, presetTarget: target, window: edge) == 32_000_000,
                   "50 ms and 2% are not bad")
            expect(controller.goodWindows == 1, "an edge window counts as good")
        }

        // Repeated bad windows stop at 50% of the preset target.
        do {
            var controller = BitrateController()
            var rate = target
            var seen: [Int] = []
            for _ in 0..<8 {
                rate = controller.nextBitrate(current: rate, presetTarget: target, window: window(drops: 3))
                seen.append(rate)
            }
            expect(seen.prefix(3) == [32_000_000, 25_600_000, 20_480_000], "80% steps: \(seen)")
            expect(seen.dropFirst(3).allSatisfy { $0 == 20_000_000 }, "floor is 50%: \(seen)")
        }

        // Five good windows raise the rate by 10%; the first four do not.
        do {
            var controller = BitrateController()
            var rate = 32_000_000
            for index in 1...4 {
                rate = controller.nextBitrate(current: rate, presetTarget: target, window: window())
                expect(rate == 32_000_000, "window \(index) must not raise the rate")
            }
            rate = controller.nextBitrate(current: rate, presetTarget: target, window: window())
            expect(rate == 35_200_000, "five good windows give +10%, got \(rate)")
            expect(controller.goodWindows == 0, "the counter restarts after a raise")
        }

        // The rate never exceeds the preset target.
        do {
            var controller = BitrateController()
            var rate = target
            for _ in 0..<20 {
                rate = controller.nextBitrate(current: rate, presetTarget: target, window: window())
                expect(rate == target, "rate must stay at the target, got \(rate)")
            }
        }

        // A bad window resets the good-window counter.
        do {
            var controller = BitrateController()
            var rate = 32_000_000
            for _ in 0..<3 { rate = controller.nextBitrate(current: rate, presetTarget: target, window: window()) }
            expect(controller.goodWindows == 3, "three good windows counted")
            rate = controller.nextBitrate(current: rate, presetTarget: target, window: window(queueMs: 80))
            expect(rate == 25_600_000 && controller.goodWindows == 0, "bad window resets the counter")
            for index in 1...4 {
                rate = controller.nextBitrate(current: rate, presetTarget: target, window: window())
                expect(rate == 25_600_000, "window \(index) after the reset must not raise the rate")
            }
            rate = controller.nextBitrate(current: rate, presetTarget: target, window: window())
            expect(rate == 28_160_000, "fifth good window after the reset gives +10%, got \(rate)")
        }

        // A current rate outside the range is clamped back into it.
        do {
            var controller = BitrateController()
            expect(controller.nextBitrate(current: 5_000_000, presetTarget: target, window: window()) == 20_000_000,
                   "below the floor is raised to the floor")
            expect(controller.nextBitrate(current: 90_000_000, presetTarget: target, window: window()) == target,
                   "above the target is lowered to the target")
        }

        testAdvisor()

        print("quality_advisor_test: OK")
    }
}
