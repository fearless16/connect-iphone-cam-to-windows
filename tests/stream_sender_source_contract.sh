#!/usr/bin/env sh
set -eu

sender="$1"

grep -q 'connectionReady' "$sender"
grep -q 'stateUpdateHandler' "$sender"
grep -q 'PC connected' "$sender"
grep -q 'First video frame sent' "$sender"
grep -q 'guard listener == nil' "$sender"
grep -q 'conn.cancel()' "$sender"
grep -q 'maxQueuedPackets = 8' "$sender"
grep -q 'pumpSend' "$sender"
grep -q 'onFrameRate' "$sender"
grep -q 'func stop()' "$sender"
