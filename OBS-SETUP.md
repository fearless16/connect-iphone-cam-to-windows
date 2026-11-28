# OBS 4K60 USB setup

Use the receiver's supported HEVC relay mode. It keeps the iPhone's HEVC
bitstream compressed through the USB receiver and lets OBS perform hardware
decode on the selected GPU. It does not use the Windows Camera Frame Server,
`regsvr32`, or the deprecated virtual-camera artifact.

1. Start the iPhone app and leave it open in the foreground.
2. Double-click `receiver.exe` (OBS relay is the default). Use
   `receiver.exe --gpu-ring` only for developer diagnostics.
3. In OBS, add a **Media Source** with these settings:

   | Setting | Value |
   |---|---|
   | Local File | off |
   | Input | `udp://127.0.0.1:12346` |
   | Input Format | `mpegts` |
   | Use hardware decoding when available | on |
   | Restart playback when source becomes active | **off** (OBS defaults to on) |
   | Close file when inactive | **off** |
   | Network Buffering | **0 MB** |
   | FFmpeg Options | leave empty |

   **Why these values matter.** OBS plays a Media Source by its timestamps,
   starting from the first frame it decodes. Any backlog it holds at that
   moment stays for the rest of the session.

   - **Restart playback when source becomes active = off.** With it on, hiding
     the source or switching scenes stops OBS from reading while the UDP socket
     stays open. On Windows, FFmpeg's receive thread keeps queueing the live
     stream into a 5.4 MB buffer. When the source becomes active again, OBS
     plays that buffer from its oldest frame, and the delay stays. The delay
     equals the time the source was hidden, up to about 5.4 MB ÷ bit rate:
     about 1 s at 4K (40 Mbps), 2–3 s at 1080p, and 4 s or more at 720p. Hidden
     any longer, the buffer overruns, and OBS logs `Circular buffer overrun`,
     then `I/O error`, and reconnects (about 2–3 s of frozen video). With it
     off, OBS keeps reading while the source is hidden, so the source always
     comes back live.
   - **Network Buffering = 0.** Any value above 0 turns off FFmpeg's
     `nobuffer` flag. OBS then plays the packets it read while probing the
     stream, so that probe time becomes permanent delay. On Windows, FFmpeg's
     receive thread already empties the socket, so a larger buffer does not
     prevent keyframe loss.
4. Set the OBS canvas/output to 3840x2160 at 60 FPS when the final stream or
   recording is intended to remain 4K60.

## TCP relay (`--obs-tcp`, in testing)

Over UDP the receiver can't see what OBS has queued. Over TCP it can. When
OBS stops reading (a hidden source, a scene switch, a busy PC), the receiver
drops frames instead of queueing them. When OBS reads again, the receiver
resumes at the next keyframe, with timestamps that carry no gap. A backlog
therefore can't build up, whatever the OBS settings are. Over UDP the delay
equals however long OBS stopped reading. Over TCP it stays at about 50–80 ms
of frames that are already in the socket buffers. TCP also never loses a
packet of a keyframe on loopback.

1. Start `receiver.exe --obs-tcp`. It logs
   `OBS relay listening; Media Source input=tcp://127.0.0.1:12346`. It
   listens on 127.0.0.1 only.
2. In the Media Source, set **Input** to `tcp://127.0.0.1:12346`. Keep the
   other settings from the table above, including **Input Format** `mpegts`.
3. The receiver logs `OBS connected to tcp://127.0.0.1:12346`, and video
   starts at the next keyframe (within about 1 s). The receiver reports
   `mode=OBS_TCP_HEVC`.

Start the receiver before OBS, or open the source's **Properties** and click
**OK** after starting it: OBS connects when it opens the input. If OBS
reconnects, the receiver replaces the old connection and starts a fresh
MPEG-TS program at the next keyframe. The log line `OBS stopped reading`
means OBS paused reading and frames are being dropped. That's expected while
a source is hidden. UDP stays the default until TCP has been checked on the
phone. Go back to it with plain `receiver.exe` and the `udp://` input.

The receiver reports `mode=OBS_UDP_HEVC`; OBS must show the Media Source as
active. If the iPhone stream disconnects, the receiver reconnects and starts a
new MPEG-TS program with a fresh HEVC IDR. OBS then continues from the next
random-access frame.

If the delay has grown on UDP, don't use right-click → **Restart**. It keeps the
same socket and plays the queued backlog. Restarting `receiver.exe` doesn't
help either, because OBS keeps its UDP socket open. Instead, open the source's
**Properties** and click **OK**. For a network input, OBS then closes and
reopens it with an empty buffer. Latency
measurement, microphone sync, and how to read the on-screen and console
numbers are in [docs/LATENCY.md](docs/LATENCY.md).
