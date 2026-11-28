#include <cassert>
#include <cstdint>
#include <vector>

#include "obs_tcp_flow.h"

namespace {

constexpr uint64_t kFrameUs = 16'667;
constexpr uint64_t kMaxAge = ObsTcpFlowControl::kMaxBacklogUs;

std::vector<uint8_t> Bytes(size_t count, uint8_t value) {
    return std::vector<uint8_t>(count, value);
}

void Add(ObsTcpSendQueue& queue, uint64_t arrivalUs, size_t count, uint8_t value) {
    queue.BeginFrame(arrivalUs);
    const std::vector<uint8_t> data = Bytes(count, value);
    queue.Append(data.data(), data.size());
}

void SendQueueTests() {
    ObsTcpSendQueue queue;
    assert(queue.Size() == 0);
    assert(!queue.IsBacklogged(1'000'000, kMaxAge));
    assert(queue.DropUnsentFrames() == 0);

    // Header bytes before any BeginFrame still belong to a frame record.
    const std::vector<uint8_t> header = Bytes(188, 0x47);
    queue.Append(header.data(), header.size());
    assert(queue.Size() == 188);
    queue.Consume(188);
    assert(queue.Size() == 0);

    // Fully sent data leaves nothing behind.
    Add(queue, 1'000, 376, 1);
    queue.Consume(376);
    assert(queue.Size() == 0);
    assert(!queue.IsBacklogged(10'000'000, kMaxAge));

    // A dropped frame's empty record is reused, not stacked.
    queue.BeginFrame(2'000);
    queue.BeginFrame(3'000);
    Add(queue, 4'000, 188, 2);
    assert(queue.Size() == 188);
    assert(!queue.IsBacklogged(4'000 + kMaxAge, kMaxAge));
    assert(queue.IsBacklogged(4'000 + kMaxAge + 1, kMaxAge));
    queue.Consume(188);

    // OBS stops reading in the middle of frame A. B and C queue behind it.
    Add(queue, 10'000, 1'880, 0xA);
    Add(queue, 20'000, 940, 0xB);
    Add(queue, 30'000, 564, 0xC);
    queue.Consume(1'000);  // part of A went out
    assert(queue.Size() == 880 + 940 + 564);
    // Age follows the frame being sent (A), not the newest one.
    assert(queue.IsBacklogged(10'000 + kMaxAge + 1, kMaxAge));
    // B and C go; the rest of A stays so the TS stream stays aligned.
    assert(queue.DropUnsentFrames() == 940 + 564);
    assert(queue.Size() == 880);
    assert(queue.Data()[0] == 0xA && queue.Data()[879] == 0xA);
    assert(queue.DropUnsentFrames() == 0);  // idempotent while OBS is away
    queue.Consume(880);
    assert(queue.Size() == 0);

    // The oldest unsent frame stays even when none of it went out, so the
    // queue empties only once OBS takes data again.
    Add(queue, 40'000, 188, 0xD);
    Add(queue, 50'000, 188, 0xE);
    Add(queue, 60'000, 376, 0xF);
    queue.Consume(188);  // exactly D
    assert(queue.Data()[0] == 0xE);
    assert(queue.IsBacklogged(50'000 + kMaxAge + 1, kMaxAge));
    assert(!queue.IsBacklogged(40'000 + kMaxAge + 1 + 9'999, kMaxAge));  // E's age decides
    assert(queue.DropUnsentFrames() == 376);
    assert(queue.Size() == 188 && queue.Data()[0] == 0xE);
    assert(queue.IsBacklogged(50'000 + kMaxAge + 1, kMaxAge));
    queue.Consume(188);
    assert(queue.Size() == 0);

    // Slow draining compacts without losing order or alignment.
    const size_t chunk = 188 * 1'000;
    for (int frame = 0; frame < 40; ++frame) {
        Add(queue, 100'000 + static_cast<uint64_t>(frame), chunk, static_cast<uint8_t>(frame));
    }
    size_t total = 40 * chunk;
    size_t consumed = 0;
    while (queue.Size() > 0) {
        const size_t step = queue.Size() < 77'777 ? queue.Size() : 77'777;
        const uint8_t expected = static_cast<uint8_t>(consumed / chunk);
        assert(queue.Data()[0] == expected);
        queue.Consume(step);
        consumed += step;
    }
    assert(consumed == total);
}

void FlowControlTests() {
    ObsTcpFlowControl flow;
    // No client: drop; the first written AU must be a join point.
    assert(flow.OnFrame(false, false, true) == ObsTcpAction::Drop);
    assert(!flow.Stalled());
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Drop);
    assert(flow.OnFrame(true, false, true) == ObsTcpAction::Write);
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Write);

    // OBS stops reading: one stall, every frame dropped, join points too.
    assert(flow.OnFrame(true, true, false) == ObsTcpAction::Drop);
    assert(flow.Stalled());
    assert(flow.OnFrame(true, true, true) == ObsTcpAction::Drop);
    assert(flow.Stalls() == 1);
    // OBS reads again: wait for the next join point.
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Drop);
    assert(flow.Stalled());
    assert(flow.OnFrame(true, false, true) == ObsTcpAction::Write);
    assert(!flow.Stalled());
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Write);
    assert(flow.Stalls() == 1);

    // A new client also restarts at a join point, without counting a stall.
    flow.OnClientChanged();
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Drop);
    assert(flow.OnFrame(true, false, true) == ObsTcpAction::Write);
    assert(flow.Stalls() == 1);
    assert(flow.DroppedFrames() == 6);
}

void TimelineTests() {
    ObsTcpFlowControl flow;
    // The first write keeps its own time; steady frames keep their spacing.
    assert(flow.OnFrame(true, false, true) == ObsTcpAction::Write);
    assert(flow.MapTimelineUs(0, kFrameUs) == 0);
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Write);
    assert(flow.MapTimelineUs(kFrameUs, kFrameUs) == kFrameUs);
    // A gap while frames keep flowing (phone reconnect) stays a gap.
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Write);
    assert(flow.MapTimelineUs(900'000, kFrameUs) == 900'000);

    // OBS stalls for 2 s: the resumed join point continues one frame later.
    assert(flow.OnFrame(true, true, false) == ObsTcpAction::Drop);
    assert(flow.OnFrame(true, false, true) == ObsTcpAction::Write);
    const uint64_t resumed = flow.MapTimelineUs(2'900'000, kFrameUs);
    assert(resumed == 900'000 + kFrameUs);
    // Later frames keep their real spacing from there.
    assert(flow.OnFrame(true, false, false) == ObsTcpAction::Write);
    assert(flow.MapTimelineUs(2'900'000 + kFrameUs, kFrameUs) == resumed + kFrameUs);

    // A join point that resumes sooner than one frame is never pushed later.
    flow.OnClientChanged();
    assert(flow.OnFrame(true, false, true) == ObsTcpAction::Write);
    const uint64_t last = resumed + kFrameUs;
    assert(flow.MapTimelineUs(2'900'000 + kFrameUs + 5'000, kFrameUs) == last + 5'000);

    // Strictly increasing across many stalls.
    uint64_t previous = last + 5'000;
    uint64_t arrival = 3'000'000;
    for (int cycle = 0; cycle < 10'000; ++cycle) {
        assert(flow.OnFrame(true, true, false) == ObsTcpAction::Drop);
        assert(flow.OnFrame(true, false, true) == ObsTcpAction::Write);
        arrival += 1'234'567;
        const uint64_t out = flow.MapTimelineUs(arrival, kFrameUs);
        assert(out == previous + kFrameUs);
        previous = out;
        assert(flow.OnFrame(true, false, false) == ObsTcpAction::Write);
        arrival += kFrameUs;
        const uint64_t next = flow.MapTimelineUs(arrival, kFrameUs);
        assert(next == previous + kFrameUs);
        previous = next;
    }
}

}  // namespace

int main() {
    SendQueueTests();
    FlowControlTests();
    TimelineTests();
    return 0;
}
