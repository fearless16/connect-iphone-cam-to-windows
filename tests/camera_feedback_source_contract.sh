#!/usr/bin/env sh
set -eu

streamer="$1"
sender="$2"
view_controller="$3"

# The app must expose persistent user-facing camera/USB state rather than
# replacing the label with whichever low-level event happened most recently.
grep -q 'var onStreamHealth' "$streamer"
grep -q 'CAMERA active • first 4K frame received' "$streamer"
grep -q 'CAMERA interrupted • recovering' "$streamer"
grep -q 'USB waiting for Windows receiver' "$streamer"
grep -q 'PC receiver connected • waiting for first video frame' "$streamer"
grep -q 'USB connected • PC receiver receiving video' "$streamer"
grep -q 'PC receiver disconnected • waiting for receiver' "$streamer"
grep -q 'USB connection error' "$streamer"
grep -q 'healthRevision' "$streamer"
grep -q 'isCurrentHealthRevision' "$streamer"
grep -q 'healthRevision &+= 1' "$streamer"
grep -q 'startLivenessWatchdog' "$streamer"
grep -q 'evaluateLiveness' "$streamer"
grep -q 'lastCaptureUptime' "$streamer"
grep -q 'lastSuccessfulSendUptime' "$streamer"
grep -q 'diagnosticsRevision' "$streamer"
grep -q 'isCurrentDiagnosticsRevision' "$streamer"

# Transport state is structured at the sender boundary, so camera and USB
# feedback cannot be inferred from incidental log wording.
grep -q 'enum StreamSenderConnectionState' "$sender"
grep -q 'var onConnectionState' "$sender"
grep -q 'publishConnectionState(.connected)' "$sender"
grep -q 'publishConnectionState(.sending)' "$sender"
grep -q 'publishConnectionState(.waiting)' "$sender"
grep -q 'publishConnectionState(.disconnected)' "$sender"
grep -q 'publishConnectionState(.failed)' "$sender"
grep -q 'var onFrameSent' "$sender"
grep -q 'var onDisconnect' "$sender"
grep -q 'noteDisconnect' "$sender"
grep -q 'LINK reconnects' "$streamer"

# Receiving a socket connection is not proof that OBS is receiving video. The
# sending state must be emitted only from the successful send completion path.
first_send_line=$(grep -n 'if self.sentFrameCount == 1' "$sender" | head -n1 | cut -d: -f1)
sending_line=$(grep -n 'self.publishConnectionState(.sending)' "$sender" | head -n1 | cut -d: -f1)
[ "$first_send_line" -lt "$sending_line" ]

# Every health mutation advances its revision before taking the UI snapshot.
awk '
  /private func updateStreamHealth\(/ { in_update = 1 }
  in_update && /healthRevision &\+= 1/ { revision_line = NR }
  in_update && /let revision = healthRevision/ { snapshot_line = NR }
  in_update && /^    }$/ { exit !(revision_line && snapshot_line && revision_line < snapshot_line) }
' "$streamer"

# UIKit is fed only from the health snapshot callback; CameraStreamer gates
# stale callbacks before each main-thread update.
grep -q 'streamer.onStreamHealth' "$view_controller"
grep -q 'DispatchQueue.main.async' "$streamer"

# T5.2: the capability report is a read-only, button-triggered probe. The
# view controller asks CameraStreamer for it and never touches StreamSender.
grep -q 'func capabilityReport(completion:' "$streamer"
grep -q 'streamer.capabilityReport' "$view_controller"
