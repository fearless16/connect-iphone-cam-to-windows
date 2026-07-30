#!/usr/bin/env sh
set -eu

app_delegate="$1"
view_controller="$2"
project="$3"

grep -q 'CameraViewController' "$app_delegate"
grep -q 'AVCaptureVideoPreviewLayer' "$view_controller"
grep -q 'statusLabel' "$view_controller"
grep -q 'CameraViewController.swift in Sources' "$project"
