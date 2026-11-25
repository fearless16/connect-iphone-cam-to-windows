# Latency and A/V sync

How to measure the delay between the real world and OBS, and how to line up a
microphone with the video. OBS source settings are in
[OBS-SETUP.md](../OBS-SETUP.md).

None of the numbers below have been measured on a real device yet. Record your
own results in section 10 of `docs/plan/EXECUTION_PLAN.md`.

## Glass-to-glass measurement

1. Show a millisecond stopwatch on the PC monitor.
2. Point the iPhone at it.
3. Take a screenshot that shows both the real stopwatch and OBS's preview of
   it. Latency = real time − time shown in OBS.
4. Take 5 samples at t=0, after 10 minutes, and after 30 minutes. Record the
   median of each set. Growth over time means delay is building up somewhere.

The monitor's refresh rate and the OBS preview add a few frames of error. Use
the same setup for every sample so the comparison is fair.

## Microphone sync

The video path is slower than a local microphone, so the audio needs a delay.

1. In OBS open **Edit → Advanced Audio Properties**.
2. Set your microphone's **Sync Offset** to the measured median glass-to-glass
   latency in ms.
3. Record a local clap test. Step through it frame by frame and adjust the
   offset until the clap sound and the image line up.
4. Re-check after 30 minutes. If it drifted, report the receiver's `skewMs`
   trend (see below). Drift is what triggers gate G5.

## Reading the numbers

Phone screen, `LATENCY encode %.0f ms • queue %.0f ms (max per 1 s)`:

- **encode**: the largest time, in the last second, from camera capture to the
  HEVC encoder returning that frame.
- **queue**: the largest time, in the last second, a frame waited in the
  phone's send queue until the system finished sending it. It is the phone-side
  half of a stalled USB link.

Receiver console, `STAT:` line (printed every 120 frames):

- **extraDelayMs**: how far the current frame arrived behind the earliest
  arrival seen in this session, compared with the phone's own timestamps. Near 0
  is healthy. It grows when frames are held up.
- **maxExtraMs**: the largest `extraDelayMs` since the previous `STAT` line.
- **maxGapMs**: the longest pause between two frames since the previous line.
- **burst**: how many frames arrived less than 2 ms after the previous one
  since the previous line. A backlog draining shows up as a high count.
- **skewMs**: the change in arrival-minus-source offset since the first frame of
  the session. A slow steady climb means the two clocks drift apart or delay
  never drains. The phone and PC clocks have unrelated origins, so only this
  change is meaningful, never the absolute value.
- **recv / sourcePTS**: frames per second measured on the PC clock and on the
  phone's timestamps. They should both sit near 60.

## What these numbers do not cover

- Delay inside OBS (decode, scene render, output encoder) is not visible to the
  receiver. Only the glass-to-glass test captures it.
- Lost UDP datagrams between the receiver and OBS show up as picture breakage
  until the next keyframe, not in `STAT`. If you see it, raise Network
  Buffering in OBS first.
