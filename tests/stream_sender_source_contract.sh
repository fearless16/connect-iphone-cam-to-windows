#!/usr/bin/env sh
set -eu

sender="$1"

grep -q 'connectionReady' "$sender"
grep -q 'stateUpdateHandler' "$sender"
grep -q 'PC connected' "$sender"
grep -q 'First video frame sent' "$sender"
grep -q 'func stop()' "$sender"
