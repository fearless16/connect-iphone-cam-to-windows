# Quickstart (do exactly this, in order)

You need **two machines**: a Mac (to build the iPhone app) and a Windows PC (to receive + OBS).
The iPhone plugs into the **Windows PC** with a USB cable.

---

## PART A — Mac: build & install the iPhone app

1. Install **Xcode** from the Mac App Store. Open it once; let it install components.
2. Get a **free** Apple ID if you don't have one (Settings > Apple ID, or appleid.apple.com).
3. Open `ios/iPhoneCameraStream.xcodeproj` in Xcode.
4. Click the blue project (top-left) → **Signing & Capabilities**:
   - Team → "Add an Account…" → sign in with your Apple ID (free).
   - It auto-fills a "Personal Team". If `DEVELOPMENT_TEAM` is empty, Xcode fills it here.
5. Plug your iPhone into the Mac with a cable.
6. At top, pick your **iPhone** as the run target (not a simulator).
7. **Enable Developer Mode on the phone**: iPhone → Settings → Privacy & Security → Developer Mode → On. Reboot when prompted.
8. Press **Run (▶)**. Xcode installs & launches the app.
   - First launch: iPhone shows a "Trust this Developer?" prompt → Settings → General → VPN & Device Management → trust your Apple ID. Run again.
   - The app shows **nothing** (no UI by design). Xcode's console prints `STATUS: Camera Active`.
9. Unplug from Mac, plug the **same iPhone into the Windows PC** now.

> The free account re-signs every 7 days; just re-Run from the Mac when it expires.

---

## PART B — Windows: build the receiver + virtual camera

1. Install **Visual Studio 2022** (Community is free) with the **"Desktop development with C++"** workload.
2. Install **vcpkg** (one-time):
   ```
   git clone https://github.com/microsoft/vcpkg.git C:\vcpkg
   C:\vcpkg\bootstrap-vcpkg.bat
   ```
3. Install FFmpeg via vcpkg (takes a while):
   ```
   C:\vcpkg\vcpkg install ffmpeg --triplet x64-windows
   ```
4. Get **DirectShow BaseClasses** (`streams.h`):
   - It ships with the Windows SDK samples. If missing, download the "DirectX 9.0 SDK" or grab `BaseClasses` from the Windows SDK. Note the folder that contains `streams.h`.
5. Build **libusbmuxd** (`usbmuxd.lib`):
   - From https://github.com/libimobiledevice/libusbmuxd (cmake, x64-windows). Note its `include/` and `usbmuxd.lib`.
6. Install **Apple Devices** app (or iTunes) from Microsoft Store so `usbmuxd` service + drivers exist on Windows.
7. Configure & build this project:
   ```
   cd windows
   cmake -B build -S . ^
     -DCMAKE_TOOLCHAIN_FILE=C:\vcpkg\scripts\buildsystems\vcpkg.cmake ^
     -DUSBMUXD_INCLUDE_DIR=C:\path\to\libusbmuxd\include ^
     -DUSBMUXD_LIBRARY=C:\path\to\libusbmuxd\lib\usbmuxd.lib ^
     -DBASECLASSES_DIR=C:\path\to\BaseClasses
   cmake --build build --config Release
   ```
8. Register the virtual camera (run **Command Prompt as Administrator**):
   ```
   cd windows\build\Release
   regsvr32 iphonecamera.ax
   ```
9. Open **OBS** → Sources → **+ Video Capture Device** → Device: **iPhone Camera**.

---

## PART C — Run

- Phone must be plugged into the Windows PC via USB and the app running (`STATUS: Camera Active` on the Mac console earlier; the app keeps running after unplug once launched).
- OBS now shows the iPhone's 4K60 feed as a normal camera.

---

## Troubleshooting (first things to check)

| Symptom | Fix |
|---|---|
| Xcode: "Failed to code sign" | Set a Team in Signing & Capabilities (Part A step 4). |
| App won't launch on phone | Trust developer: Settings → General → VPN & Device Management. |
| Windows: `usbmuxd_connect failed` | Phone app not running, or not plugged into Windows, or Apple Devices drivers missing. |
| OBS: no "iPhone Camera" device | `regsvr32 iphonecamera.ax` failed (run cmd as Admin) or missing VC++/runtime. |
| Black frame in OBS | Transport not yet flowing; check the receiver console / phone is streaming. |

---

## What is deliberately NOT built yet (per plan)

Audio, settings, installer, segmentation/blur. We stabilize **4K60 over USB → OBS**
first. Background blur comes last, only after a clean 30-minute stream.
