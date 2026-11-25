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

## PART B — Windows: build and run the OBS relay

`receiver.exe` is the supported single-PC path. It relays the iPhone's HEVC feed
over local UDP to an OBS Media Source.

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
4. Build **libusbmuxd** (`usbmuxd.lib`):
   - From https://github.com/libimobiledevice/libusbmuxd (cmake, x64-windows). Note its `include/` and `usbmuxd.lib`.
5. Install **Apple Devices** from Microsoft Store (already installed on this PC).
6. Configure & build this project:
   ```
   cd windows
   cmake -B build -S . ^
     -DCMAKE_TOOLCHAIN_FILE=C:\vcpkg\scripts\buildsystems\vcpkg.cmake ^
     -DUSBMUXD_INCLUDE_DIR=C:\path\to\libusbmuxd\include ^
     -DUSBMUXD_LIBRARY=C:\path\to\libusbmuxd\lib\usbmuxd.lib
   cmake --build build --config Release
   ```
7. On iPhone: **Settings → Personal Hotspot → Allow Others to Join → On**.
   Keep the iPhone USB cable connected and tap **Trust** if requested. Apple
   Devices provides the Windows USB-network driver. This is still USB (not
   Wi-Fi), but it avoids the incomplete Windows `usbmuxd` implementation.
8. In OBS, follow [OBS-SETUP.md](../OBS-SETUP.md) to add the Media Source.
9. Start the receiver:
   ```
   cd windows\build\Release
   receiver.exe
   ```
   Confirm `mode=OBS_UDP_HEVC` and a stable receive rate while the iPhone app is
   running. Perform the planned 30-minute soak test before treating 4K60 as
   reliable.

---

## PART C — Run

- Phone must be plugged into the Windows PC via USB and the app running (`STATUS: Camera Active` on the Mac console earlier; the app keeps running after unplug once launched).
- Start the OBS Media Source before `receiver.exe`; relay-write errors are
  counted as `relayDrop` and do not end the iPhone connection.

---

## Troubleshooting (first things to check)

| Symptom | Fix |
|---|---|
| Xcode: "Failed to code sign" | Set a Team in Signing & Capabilities (Part A step 4). |
| App won't launch on phone | Trust developer: Settings → General → VPN & Device Management. |
| Receiver keeps retrying | Turn on iPhone Personal Hotspot, keep USB connected, and leave the camera app open. |
| Receiver needs a different iPhone USB address | Run `receiver.exe <iPhone-USB-gateway>` or set `IPHONE_CAMERA_HOST`; normally it auto-detects it. |
| OBS Media Source shows no video | Confirm its input is `udp://127.0.0.1:12346`, then check the receiver console and phone stream. |
| Video froze after clicking the receiver window | Fixed in this receiver build (QuickEdit is disabled). On old builds, press Esc in the console. |
| Black frame in OBS | Transport not yet flowing; check the receiver console / phone is streaming. |

---

## What is deliberately NOT built yet (per plan)

Audio, settings, installer, and segmentation/blur. We stabilize **4K60 over USB
with `receiver.exe` and OBS** first. Background blur comes last, only after a
clean 30-minute stream.
