#!/usr/bin/env sh
set -eu

sender="$1"

grep -q 'connectionReady' "$sender"
grep -q 'stateUpdateHandler' "$sender"
grep -q 'PC connected' "$sender"
grep -q 'First video frame sent' "$sender"
grep -q 'guard listener == nil' "$sender"
# A newly accepted connection must replace and close the previous one.  The
# implementation deliberately calls through the stored connection so it never
# accidentally cancels the new `conn` passed by Network.framework.
grep -q 'connection?.cancel()' "$sender"
grep -q 'maxQueuedPackets = 8' "$sender"
grep -q 'pumpSend' "$sender"
grep -q 'onFrameRate' "$sender"
grep -q 'func stop()' "$sender"
grep -q 'desiredRunning' "$sender"
grep -q 'scheduleRestart' "$sender"
grep -q 'listenerRetryAttempt' "$sender"
grep -q 'NWPathMonitor' "$sender"
grep -q 'func restartListening' "$sender"
grep -q 'USB network path changed' "$sender"
