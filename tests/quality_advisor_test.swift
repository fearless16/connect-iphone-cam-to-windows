import Foundation

@main
struct QualityAdvisorTests {
    static let target = 40_000_000

    static func window(queueMs: Double = 0,
                       drops: UInt64 = 0,
                       retransmit: Double = 0) -> LinkWindow {
        LinkWindow(drops: drops, maxQueueMs: queueMs, rttMs: 5, rttVarMs: 1,
                   retransmitRatio: retransmit, thermal: .nominal)
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

        print("quality_advisor_test: OK")
    }
}
