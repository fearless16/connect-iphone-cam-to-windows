# Receiver end-to-end tests (gate G1)

`ipcam_e2e.py` runs the real `receiver.exe` with no iPhone:

```
fake iPhone (TCP 127.0.0.1:12345) -> receiver.exe --host 127.0.0.1
    -> MPEG-TS over UDP -> sink on 127.0.0.1:12346 (stands in for OBS) -> analyzer
       (tcp_* scenarios: receiver --obs-tcp, and the sink connects over TCP)
```

It needs Python 3.8+ (standard library only) and, for the decode check, the
`ffprobe` CLI on PATH (`ffmpeg` only to regenerate fixtures). Nothing else is installed.

```sh
sh scripts/build_receiver_msys2.sh                  # builds build/windows-binaries/receiver.exe
sh tests/receiver_e2e_test.sh                       # steady scenario
sh tests/receiver_e2e_test.sh build/windows-binaries/receiver.exe "steady burst soak"
python tests/e2e/ipcam_e2e.py --receiver build/windows-binaries/receiver.exe \
    --scenario soak --duration 3600 --session-seconds 600   # one-hour soak by hand
```

Close OBS first: the sink binds UDP 12346, the port OBS listens on. `crash_report`
also binds TCP 12347 and removes the report file it caused.

Each run prints `E2E_SUMMARY {json}` and `E2E PASS|FAIL <scenario>`, and keeps
`receiver.log` and `capture.ts` in the printed work directory.

## Scenarios

| Scenario | Fake phone does | Checks |
|---|---|---|
| `steady` | 6 s at 60 fps from an IDR | receiver alive; first PES is VPS/SPS/PPS+IDR; every AU relayed; 0 CC errors; PTS strictly increasing; `ffprobe` decodes every frame of `capture.ts` without errors; relay latency p95 < 50 ms |
| `midgop` | starts each session on a delta frame | nothing relayed before the first join AU |
| `disconnect` | closes after 2 s, then a new session from an IDR | reconnect gap below the limit; session 2 starts at a join point; CC continuous |
| `stall` | 3 s silence between frames | no reconnect; relaying resumes |
| `stall_timeout` | stops in the middle of a frame | payload timeout logged; reconnect; relaying resumes within 10 s |
| `garbage` | a header with a bad magic | `invalid stream header`; session dropped; next session relays |
| `oversize` | a header with `frame_size` = 16 MiB + 1 | session dropped without reading a payload; next session relays |
| `burst` | 300 ms pause, then 18 queued frames at once | every frame relayed; PTS never behind arrival, and back within 5 ms of its pre-pause offset (G5) |
| `obs_restart` | (the sink closes UDP 12346 for 2 s mid-stream, like OBS restarting) | the phone session survives; at most one continuity gap per TS PID (the lost packets); relaying resumes and a keyframe reaches OBS within 1.2 s |
| `tcp_steady` | like `steady`, with `receiver --obs-tcp` and a TCP client standing in for OBS (T2.6) | the same checks as `steady`, from the first IDR after the client connects |
| `tcp_paused` | AUs padded with HEVC filler NALs to about 48 Mbit/s (4K60); the TCP client stops reading for 2 s without closing | the phone session and the one TCP connection survive; the receiver logs `OBS stopped reading` and `OBS reading again`; one to three drop runs (a TCP stack may take more bytes mid-pause and resume early), each at most one CC gap per PID; a keyframe within 1.2 s of reading again; an OBS-style PTS schedule, anchored at the first frame after the pause, holds frames for at most 150 ms (UDP would hold the whole pause) |
| `tcp_reconnect` | the TCP client disconnects for 2 s mid-stream, then connects again | the `obs_restart` checks, plus two connections accepted |
| `crash_report` | offers a crash report on port 12347 at each session start: bad magic, then a 4 GiB length, then a valid report (T6.1) | only the valid report is saved, byte for byte, to `crash-reports` next to `receiver.exe` and acknowledged; the bad ones get no ack; video flows in every session |
| `drift` | phone clock runs 1% fast for 20 s | relay PTS stays on the PC clock (G5): moves at most 15 ms against arrival |
| `soak` | repeated sessions (`--duration`, `--session-seconds`) | every session relays; CC continuous; receiver private bytes and handle count stay flat |

Frames carry their capture time on a 60 fps grid, like the phone's
`CMSampleBuffer` timestamps, so a queued burst arrives later than its PTS.

## Fixture

`fixtures/testsrc_360p60_k60.h265` is 240 frames with an IDR every 60 frames,
and every IDR access unit carries VPS+SPS+PPS, like the phone's. Regenerate it
with this exact command (`open-gop=0` matters: x265 otherwise emits CRA frames,
not IDRs, after the first keyframe):

```sh
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=60 -t 4 -pix_fmt yuv420p -c:v libx265 -preset fast -x265-params "keyint=60:min-keyint=60:bframes=0:scenecut=0:open-gop=0:repeat-headers=1:aud=1:log-level=error" -f hevc tests/e2e/fixtures/testsrc_360p60_k60.h265
```
