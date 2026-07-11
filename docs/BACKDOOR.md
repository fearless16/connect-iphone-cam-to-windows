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
   - Run `regsvr32 iphonecamera.ax` (Admin Command Prompt) if the `.ax` was built.
   - Run `receiver.exe` to test the transport / measure FPS.
   - Open OBS → Video Capture Device → **iPhone Camera**.
6. Plug the iPhone (app running) into the Windows PC via USB. Done.

## Why this works
- A **macOS CI runner** compiles the Swift app and exports an **unsigned IPA**
  (`CODE_SIGNING_ALLOWED=NO`). TrollStore re-signs it locally on the device.
- A **Windows CI runner** uses MSYS2, which ships **prebuilt ffmpeg + libusbmuxd**
  dev packages — no manual `.lib` hunting. BaseClasses is cloned from Microsoft's
  samples repo. `receiver.exe` always builds; `iphonecamera.ax` is best-effort
  (it needs the DirectShow base classes, which sometimes needs a tweak on MinGW).

## Fallbacks if a step fails
- **No `.ax` artifact:** the transport still works — run `receiver.exe` to confirm
  frames arrive and measure FPS. The virtual camera `.ax` can be built later on any
  full Visual Studio machine (see `docs/QUICKSTART.md`), or you can grab a prebuilt
  DirectShow virtual-camera wrapper.
- **IPA won't install:** your iOS version may be outside TrollStore's supported range.
  Use Esign/Scarlet, or temporarily use a friend's Mac to sign once.

## What you still need (can't be avoided)
- A **Windows PC** running OBS (you operate it, you just don't compile on it).
- The **iPhone app actually running** when you stream.
