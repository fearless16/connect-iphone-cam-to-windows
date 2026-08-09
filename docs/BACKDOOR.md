# The iPhone-only backdoor

You can't run a Mac or Windows toolchain. So **the cloud builds everything** and you
only **download + install**. This is the whole point of `.github/workflows/build.yml`.

## What you do (all on the phone)

1. Put this folder into a **GitHub repo**. Easiest from the iPhone:
   - Install the **GitHub Mobile** app or use Safari → github.com.
   - Create a repo, then upload the whole `project/` folder (or push via Working Copy app).
2. In the repo, go to **Actions → "Build (iPhone-only backdoor)" → Run workflow**.
   (It also runs automatically on every push to `main`.)
3. Wait ~5–10 min. Two artifacts appear under the run:
   - `iPhoneCameraStream-ipa`
   - `windows-binaries`
4. **Download the IPA** to your iPhone. Install it with **TrollStore**
   (TrollStore installs unsigned apps permanently — no Mac, no PC, no Apple ID cert).
   - If you don't have TrollStore: use **Esign** / **Scarlet** (also phone-only sideloaders).
5. **Download `windows-binaries`** and copy it to the Windows PC that runs OBS.
   - Run `receiver.exe` to start the supported USB-to-OBS relay.
   - In OBS, add a **Media Source** with input `udp://127.0.0.1:12346` and
     input format `mpegts`.
6. Plug the iPhone (app running) into the Windows PC via USB. Done.

## Why this works
- A **macOS CI runner** compiles the Swift app and exports an **unsigned IPA**
  (`CODE_SIGNING_ALLOWED=NO`). TrollStore re-signs it locally on the device.
- A **Windows CI runner** uses MSYS2, which ships **prebuilt ffmpeg + libusbmuxd**
  dev packages — no manual `.lib` hunting. `receiver.exe` is the supported
  artifact and relays the stream to OBS over local UDP.

## Fallbacks if a step fails
- **No video in OBS:** confirm that `receiver.exe` is running and the OBS Media
  Source input is `udp://127.0.0.1:12346` with format `mpegts`.
- **IPA won't install:** your iOS version may be outside TrollStore's supported range.
  Use Esign/Scarlet, or temporarily use a friend's Mac to sign once.

## What you still need (can't be avoided)
- A **Windows PC** running OBS (you operate it, you just don't compile on it).
- The **iPhone app actually running** when you stream.

## Legacy virtual camera

The repository retains old virtual-camera sources for research only. They are
disabled and unsupported; do not register or use them. The supported path is
always `receiver.exe` plus the OBS UDP Media Source.
