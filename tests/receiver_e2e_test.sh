#!/usr/bin/env sh
set -eu
# End-to-end: fake iPhone -> real receiver.exe -> UDP sink (tests/e2e, gate G1).
#   sh tests/receiver_e2e_test.sh [RECEIVER_EXE] ["scenario ..."]
receiver="${1:-build/windows-binaries/receiver.exe}"
scenarios="${2:-steady}"
py=""
for c in python3 python; do
  # python3 on Windows can be the Store stub, so probe each candidate.
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
    py="$c"; break
  fi
done
[ -n "$py" ] || { echo "receiver e2e: python 3.8+ not found" >&2; exit 1; }
[ -f "$receiver" ] || { echo "receiver e2e: $receiver not found" >&2; exit 1; }
for s in $scenarios; do
  "$py" "$(dirname "$0")/e2e/ipcam_e2e.py" --receiver "$receiver" --scenario "$s"
done
