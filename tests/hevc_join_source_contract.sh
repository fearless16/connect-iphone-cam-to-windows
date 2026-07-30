#!/usr/bin/env sh
set -eu

camera="$1"
sender="$2"

grep -q 'kVTEncodeFrameOptionKey_ForceKeyFrame' "$camera"
grep -q 'onClientConnected' "$camera"
grep -q 'onClientConnected' "$sender"
grep -q 'waitingForKeyFrame' "$sender"
grep -q 'isKeyframe: Bool' "$sender"
grep -q 'parameterSetCountOut: &parameterSetCount' "$camera"
grep -q 'var nalUnitHeaderLength: Int32 = 0' "$camera"
