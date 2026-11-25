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
   | Restart playback when source becomes active | **off** |
   | Close file when inactive | **off** |
   | Network Buffering | **4 MB** |

   Network Buffering sets FFmpeg's UDP receive buffer in current OBS versions.
   A larger buffer stops lost datagrams when a 4K keyframe (about 1,000
   back-to-back packets) arrives in a burst. It does not add delay. If your
   OBS build behaves differently, treat the buffer size as unverified.
4. If your OBS has an **FFmpeg Options** field, try
   `fflags=nobuffer probesize=1000000 analyzeduration=0`. It shrinks the
   startup backlog that otherwise becomes permanent delay. Keep it only if
   glass-to-glass latency improves and video still starts.
5. Set the OBS canvas/output to 3840x2160 at 60 FPS when the final stream or
   recording is intended to remain 4K60.

The receiver reports `mode=OBS_UDP_HEVC`; OBS must show the Media Source as
active. If the iPhone stream disconnects, the receiver reconnects and starts a
new MPEG-TS program with a fresh HEVC IDR. OBS then continues from the next
random-access frame.

If the delay seems to have grown, right-click the source and choose
**Restart**. Latency measurement, microphone sync, and how to read the
on-screen and console numbers are in [docs/LATENCY.md](docs/LATENCY.md).
