# OBS 4K60 USB setup

Use the receiver's supported HEVC relay mode. It keeps the iPhone's HEVC
bitstream compressed through the USB receiver and lets OBS perform hardware
decode on the selected GPU. It does not use the Windows Camera Frame Server,
`regsvr32`, or the deprecated virtual-camera artifact.

1. Start the iPhone app and leave it open in the foreground.
2. Double-click `receiver.exe` (OBS relay is the default). Use
   `receiver.exe --gpu-ring` only for developer diagnostics.
3. In OBS, add **Media Source**, uncheck **Local File**, and set **Input** to
   `udp://127.0.0.1:12346`.
4. Set **Input Format** to `mpegts` and enable **Use hardware decoding when
   available**. Leave **Close file when inactive** disabled.
5. Set the OBS canvas/output to 3840x2160 at 60 FPS when the final stream or
   recording is intended to remain 4K60.

The receiver reports `mode=OBS_UDP_HEVC`; OBS must show the Media Source as
active. If the iPhone stream disconnects, the receiver reconnects and starts a
new MPEG-TS program with a fresh HEVC IDR. OBS then continues from the next
random-access frame.
