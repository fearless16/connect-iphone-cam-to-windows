#!/usr/bin/env sh
# T5.1: the iOS job must build with the iOS 26 SDK (Cinematic APIs).
set -eu
workflow="${1:-.github/workflows/build.yml}"
grep -q 'name: Require iOS 26 SDK' "$workflow"
grep -q 'show-sdk-version' "$workflow"
grep -q -- '-ge 26' "$workflow"
