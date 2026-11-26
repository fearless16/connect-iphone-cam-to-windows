#!/usr/bin/env sh
set -eu

app_delegate="$1"
view_controller="$2"
project="$3"
# Review fix: UIScene lifecycle (TN3187). The window moved from AppDelegate to
# SceneDelegate, next to it in ios/.
scene_delegate="$(dirname "$app_delegate")/SceneDelegate.swift"
info_plist="$(dirname "$app_delegate")/Info.plist"

grep -q 'delegateClass = SceneDelegate.self' "$app_delegate"
grep -q 'let streamer = CameraStreamer()' "$app_delegate"
if grep -q 'UIScreen.main' "$app_delegate" "$scene_delegate"; then
  echo "use the window scene, not UIScreen.main" >&2
  exit 1
fi
grep -q 'CameraViewController' "$scene_delegate"
grep -q 'var window: UIWindow?' "$scene_delegate"
grep -q 'UIWindow(windowScene: windowScene)' "$scene_delegate"
grep -q '<key>UIApplicationSceneManifest</key>' "$info_plist"
grep -q 'AVCaptureVideoPreviewLayer' "$view_controller"
grep -q 'statusLabel' "$view_controller"
grep -q 'iPhone Camera Stream 0.4' "$view_controller"
grep -q 'CameraViewController.swift in Sources' "$project"
grep -q 'SceneDelegate.swift in Sources' "$project"
grep -q 'CapabilityReport.swift in Sources' "$project"
