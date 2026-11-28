# The iPhone-only backdoor

You can't run a Mac or Windows toolchain. So **the cloud builds everything** and you
only **download, sign + install**. This is the whole point of `.github/workflows/build.yml`.

## What you do

1. Put this folder into a **GitHub repo**. Easiest from the iPhone:
   - Install the **GitHub Mobile** app or use Safari → github.com.
   - Create a repo, then upload the whole `project/` folder (or push via Working Copy app).
2. In the repo, go to **Actions → "Build iPhone USB receiver" → Run workflow**.
   (It also runs automatically on every push to `main` and on pull requests.)
3. Wait ~5–10 min. Two artifacts appear under the run:
   - `iPhoneCameraStream-ipa`
   - `windows-binaries`
4. **Sign and install the IPA.** It is unsigned, so iOS needs it signed with your
   own Apple ID before it runs. TrollStore no longer helps: it only works up to
   iOS 17.0, and this app targets current iOS (the owner's phone runs iOS 26).
   - From the Windows PC: a sideloading tool such as **Sideloadly** or
     **AltStore** signs the IPA with your Apple ID and installs it over USB.
   - With a free Apple ID the signature expires after **7 days**; re-sign then.
     A paid Apple Developer account lasts a year.
   - First launch: Settings → General → VPN & Device Management → trust your
     Apple ID, and turn on Developer Mode if iOS asks.
5. **Download `windows-binaries`** and copy the whole folder to the Windows PC
   that runs OBS. It holds `receiver.exe` and the FFmpeg/libusbmuxd DLLs it
   needs; keep them together.
   - Run `receiver.exe` to start the supported USB-to-OBS relay.
   - In OBS, add a **Media Source** with input `udp://127.0.0.1:12346` and
     input format `mpegts`. With `receiver.exe --obs-tcp`, use
     `tcp://127.0.0.1:12346` instead (OBS-SETUP.md).
6. Plug the iPhone (app running) into the Windows PC via USB. Done.

## Why this works
- A **macOS CI runner** compiles the Swift app and exports an **unsigned IPA**
  (`CODE_SIGNING_ALLOWED=NO`). Your sideloading tool signs it with your Apple ID.
- A **Windows CI runner** uses MSYS2 (UCRT64), which ships **prebuilt ffmpeg +
  libusbmuxd** packages — no manual `.lib` hunting. The job copies their DLLs
  next to `receiver.exe` and fails if none were copied. `receiver.exe` is the
  supported artifact and relays the stream to OBS over local UDP.

## Fallbacks if a step fails
- **No video in OBS:** confirm that `receiver.exe` is running and the OBS Media
  Source input is `udp://127.0.0.1:12346` with format `mpegts`
  (`tcp://127.0.0.1:12346` when the receiver runs with `--obs-tcp`).
- **IPA won't install or stops opening:** the signature is missing or expired
  (7 days on a free Apple ID). Re-sign it with your sideloading tool, or build
  from Xcode on a Mac with your own team (docs/QUICKSTART.md Part A).
- **`receiver.exe` says a DLL is missing:** copy the whole `windows-binaries`
  folder, not just the exe. Artifacts built before this fix contained the exe only.

## What you still need (can't be avoided)
- A **Windows PC** running OBS (you operate it, you just don't compile on it).
- The **iPhone app actually running** when you stream.

## Legacy virtual camera

The repository retains old virtual-camera sources for research only. They are
disabled and unsupported; do not register or use them. The supported path is
always `receiver.exe` plus the OBS UDP Media Source.
