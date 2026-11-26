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
   - The app shows a camera preview, status and diagnostics lines, and a Landscape/Portrait switch. Xcode's console prints `STATUS: Camera Active`.
9. Unplug from Mac, plug the **same iPhone into the Windows PC** now.

> The free account re-signs every 7 days; just re-Run from the Mac when it expires.

---

## PART B — Windows: build and run the OBS relay

`receiver.exe` is the supported single-PC path. It relays the iPhone's HEVC feed
over local UDP to an OBS Media Source.

**USB path:** the receiver first tries **Apple Devices** (usbmux) over the USB cable.
Only if that fails does it fall back to the iPhone **Personal Hotspot** USB network.
So install Apple Devices and keep Personal Hotspot as a backup, not the first choice.

### Option 1 (recommended): build exactly like CI with MSYS2

1. Install MSYS2 from msys2.org and open the **MSYS2 UCRT64** shell.
2. Install the toolchain and libraries:
   ```
   pacman -S --needed mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-ffmpeg mingw-w64-ucrt-x86_64-libusbmuxd mingw-w64-ucrt-x86_64-python mingw-w64-ucrt-x86_64-pkgconf git
   ```
3. From the repo root run `sh scripts/build_receiver_msys2.sh`. It runs the C++
   tests and writes `build/windows-binaries/receiver.exe` plus its DLLs, so the
   folder also runs outside the MSYS2 shell. The **MINGW64** shell works too if
   you installed the `mingw-w64-x86_64-*` packages instead.

### Option 2: Visual Studio and vcpkg

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
7. Keep the iPhone USB cable connected and tap **Trust** if requested. If the
   receiver cannot reach the phone through Apple Devices, turn on **Settings →
   Personal Hotspot → Allow Others to Join** as the fallback. Apple Devices
   provides the Windows USB-network driver for it. This is still USB (not Wi-Fi).
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

- Phone must be plugged into the Windows PC via USB, with the app open in the foreground (the screen stays awake by design).
- The phone encodes video only while `receiver.exe` is connected. Until then the
  preview stays live, the status shows `HEVC paused` and the HEVC rate is 0, which
  keeps the phone cooler. Video starts on a keyframe within about a second of the
  receiver connecting.
- Start the OBS Media Source before `receiver.exe`; relay-write errors are
  counted as `relayDrop` and do not end the iPhone connection.

---

## Wi-Fi mode (optional)

USB is the default and the best path. Wi-Fi is an opt-in alternative for when a
cable is not practical.

1. Put the phone and the PC on the same network.
2. On the phone, turn on the **Wi-Fi** switch (top right). It is off by default
   and remembers its setting. The status panel then shows
   `WI-FI <ip>:12345 • visible to this network`.
3. On the PC run `receiver.exe --wifi`. It finds the phone through Bonjour
   (`_ipcamstream._tcp`) and looks it up again on every reconnect. If discovery
   finds nothing (some routers block multicast), run `receiver.exe --host <ip>`
   with the address from step 2.

Flipping the switch does not interrupt a USB stream that is already running;
turning it off ends only a Wi-Fi connection.

Expect more latency and jitter than USB. While the switch is on, the stream is
unauthenticated and visible to every device on that network. Turn the switch off
when you finish: the phone then refuses Wi-Fi and cellular connections again and
only the USB path works.

---

## Crash reports (automatic)

If the app crashes, iOS (MetricKit) hands the app a crash report the next time it
launches. The app keeps only that newest report (at most 256 KB, one small file)
and offers it to the PC once, over USB or Wi-Fi, on a separate port (12347) that
is open only while a report is waiting. When `receiver.exe` connects, it saves
the report to a `crash-reports` folder next to `receiver.exe` and prints
`iPhone crash report saved to ...`. Only then does the phone delete its copy.
Send that file when asking for help debugging a crash. With Wi-Fi mode off, the
report can only travel over USB. iOS can take a while to deliver a report, and
may not deliver one at all if analytics sharing is off in iPhone Settings.

## Troubleshooting (first things to check)

| Symptom | Fix |
|---|---|
| Xcode: "Failed to code sign" | Set a Team in Signing & Capabilities (Part A step 4). |
| App won't launch on phone | Trust developer: Settings → General → VPN & Device Management. |
| Receiver keeps retrying | Keep USB connected, leave the camera app open in the foreground, and answer any "Trust This Computer" prompt. If Apple Devices cannot connect, turn on Personal Hotspot as the fallback. |
| Stream stalls or drops at random | Windows: Control Panel → Power Options → Change plan settings → Change advanced power settings → USB settings → USB selective suspend setting → **Disabled**. |
| Connection is unreliable | Use a USB port directly on the motherboard (no hub) and a data-capable cable, not a charge-only one. |
| Phone asks "Trust This Computer?" | Tap Trust and enter the passcode once. Without it the PC cannot reach the app. |
| iOS asks "Allow accessory to connect?" | Allow it. |
| Find the phone on Wi-Fi without typing its address | Run `receiver.exe --wifi` (Wi-Fi mode must be on in the app). `--host` wins if both are given. |
| Connect to a specific phone address (Wi-Fi or tests) | Run `receiver.exe --host <ip>`. It connects straight to `<ip>:12345` and skips usbmux. |
| Receiver needs a different iPhone USB address | Run `receiver.exe <iPhone-USB-gateway>` or set `IPHONE_CAMERA_HOST`; normally it auto-detects it. |
| Several iPhones/iPads plugged in, receiver picks the wrong one | The receiver lists every USB device's `udid` once. Set `IPHONE_CAMERA_UDID=<udid>` before starting it. |
| `avformat-*.dll was not found` when starting receiver.exe | Keep every DLL from the `windows-binaries` folder next to `receiver.exe`. CI builds before this fix shipped the exe alone; download a newer artifact. |
| OBS Media Source shows no video | Confirm its input is `udp://127.0.0.1:12346`, then check the receiver console and phone stream. |
| Video froze after clicking the receiver window | Fixed in this receiver build (QuickEdit is disabled). On old builds, press Esc in the console. |
| Black frame in OBS | Transport not yet flowing; check the receiver console / phone is streaming. |

---

## What is deliberately NOT built yet (per plan)

Audio, settings, installer, and segmentation/blur. We stabilize **4K60 over USB
with `receiver.exe` and OBS** first. Background blur comes last, only after a
clean 30-minute stream.
