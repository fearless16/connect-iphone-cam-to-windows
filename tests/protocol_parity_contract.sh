#!/usr/bin/env sh
# R-ARCH-2: protocol/stream_protocol.h is the source of truth for the wire
# format; shared/StreamHeader.swift mirrors it by hand. This contract fails
# when the two drift. Byte order and field order are covered by the shared
# golden vector in tests/protocol_selftest.cpp and tests/stream_header_test.swift.
set -eu

c_header="${1:-protocol/stream_protocol.h}"
swift_header="${2:-shared/StreamHeader.swift}"
sender="${3:-ios/StreamSender.swift}"
receiver="${4:-windows/receiver.cpp}"

# extract FILE SED_EXPRESSION -> first match, CR stripped, hex uppercased
extract() {
  tr -d '\r' < "$1" | sed -n "$2" | head -n 1 | tr 'abcdef' 'ABCDEF'
}

same() {
  if [ -z "$2" ] || [ "$2" != "$3" ]; then
    echo "PROTOCOL DRIFT [R-ARCH-2]: $1 differs ('$2' vs '$3')" >&2
    exit 1
  fi
}

same "magic (C vs Swift)" \
  "$(extract "$c_header" 's/^#define STREAM_MAGIC[[:space:]][[:space:]]*0x\([0-9A-Fa-f]*\)UL.*/\1/p')" \
  "$(extract "$swift_header" 's/.*static let magic: UInt32 = 0x\([0-9A-Fa-f]*\).*/\1/p')"

same "header size (C vs Swift)" \
  "$(extract "$c_header" 's/^#define STREAM_HEADER_SIZE[[:space:]][[:space:]]*\([0-9]*\).*/\1/p')" \
  "$(extract "$swift_header" 's/.*static let size = \([0-9]*\).*/\1/p')"

same "HEVC codec id (C vs Swift)" \
  "$(extract "$c_header" 's/.*STREAM_CODEC_HEVC = \([0-9]*\).*/\1/p')" \
  "$(extract "$swift_header" 's/.*case hevc = \([0-9]*\).*/\1/p')"

same "H264 codec id (C vs Swift)" \
  "$(extract "$c_header" 's/.*STREAM_CODEC_H264 = \([0-9]*\).*/\1/p')" \
  "$(extract "$swift_header" 's/.*case h264 = \([0-9]*\).*/\1/p')"

# Both encoders must write exactly STREAM_HEADER_SIZE bytes (indices 0..size-1).
size=$(extract "$c_header" 's/^#define STREAM_HEADER_SIZE[[:space:]][[:space:]]*\([0-9]*\).*/\1/p')
last_index() {
  tr -d '\r' < "$1" | grep -o 'out\[[0-9]*\]' | tr -cd '0-9\n' | sort -n | tail -n 1
}
same "last header byte written by C encoder" "$(last_index "$c_header")" "$((size - 1))"
same "last header byte written by Swift encoder" "$(last_index "$swift_header")" "$((size - 1))"

same "TCP port (iOS sender vs Windows receiver)" \
  "$(extract "$sender" 's/.*static let port: UInt16 = \([0-9]*\).*/\1/p')" \
  "$(extract "$receiver" 's/^#define DEVICE_PORT[[:space:]][[:space:]]*\([0-9]*\)u.*/\1/p')"

echo "protocol parity: OK"
