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
# T1.2: rebind must not wait on TIME_WAIT; retry fast and forever.
grep -q 'allowLocalEndpointReuse = true' "$sender"
grep -q 'noDelay = true' "$sender"
grep -q 'min(2.0, 0.25 \* pow(2.0' "$sender"

# A transient Network.framework wait is a transport discontinuity: stop frame
# admission, discard queued delta frames, and require a fresh random-access
# frame when the same connection becomes ready again.
waiting_handler=$(awk '
  /private func pauseForConnectionWaiting\(\)/ { in_handler = 1 }
  in_handler { print }
  in_handler && /^    }$/ { exit }
' "$sender")
printf '%s\n' "$waiting_handler" | grep -q 'connectionReady = false'
printf '%s\n' "$waiting_handler" | grep -q 'pendingPackets.removeAll'
printf '%s\n' "$waiting_handler" | grep -q 'waitingForKeyFrame = true'
printf '%s\n' "$waiting_handler" | grep -q 'sendGeneration &+= 1'
printf '%s\n' "$waiting_handler" | grep -q 'publishConnectionState(.waiting)'
grep -q 'case .waiting(let error):' "$sender"
grep -q 'self.pauseForConnectionWaiting()' "$sender"

# A completion submitted before the wait must not publish sending health or
# advance counters after recovery. The generation check fences it out while
# allowing the one physical Network.framework send to finish in order.
grep -q 'let generation = sendGeneration' "$sender"
grep -q 'guard generation == self.sendGeneration else' "$sender"
grep -q 'guard connectionReady, !sendInFlight' "$sender"

# Once `.waiting` invalidates a send generation, its delayed completion is
# stale even if Network.framework attaches an error. Fence it before the
# current-generation failure path, otherwise recovery can cancel a healthy
# connection instead of draining the queued fresh IDR.
awk '
  /private func pumpSend\(connection: NWConnection\)/ { in_pump = 1 }
  in_pump && /self\.sendInFlight = false/ && !reset_line { reset_line = NR }
  in_pump && /guard generation == self\.sendGeneration else/ && !generation_line { generation_line = NR }
  in_pump && /if let error/ && !error_line { error_line = NR }
  END {
    exit !(reset_line && generation_line && error_line &&
           reset_line < generation_line && generation_line < error_line)
  }
' "$sender"
