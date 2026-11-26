#!/usr/bin/env sh
# T6.1: the crash-report side channel stays small, off the video path, and gated
# like the stream. Usage: crash_report_source_contract.sh SERVICE STREAMER RECEIVER
set -eu

service="$1"
streamer="$2"
receiver="$3"

# Capture: Apple's MetricKit crash diagnostics, delivered on the next launch.
grep -q 'MXMetricManagerSubscriber' "$service"
grep -q 'MXMetricManager.shared.add(self)' "$service"
grep -q 'crashDiagnostics' "$service"

# D4: same USB-only default as the stream, and the port is distinct from 12345.
grep -Fq 'if !wifiEnabled { params.prohibitedInterfaceTypes = [.wifi, .cellular] }' "$service"
grep -Fq 'CrashReportFraming.port' "$service"
if grep -q '12345' "$service"; then echo "crash report service must not use the stream port" >&2; exit 1; fi

# The listener exists only while a report is waiting, and the phone deletes its
# copy only after the PC acknowledges.
grep -Fq 'store.pending != nil' "$service"
grep -Fq 'data?.first == CrashReportFraming.ack' "$service"
grep -q 'self.store.clear()' "$service"

# Never part of the video path: no frame, encoder or packet-framing code.
for forbidden in StreamHeader AVCapture VTCompressionSession sampleBuffer; do
  if grep -q "$forbidden" "$service"; then
    echo "crash report service must not reference $forbidden" >&2
    exit 1
  fi
done

# CameraStreamer owns it and passes the Wi-Fi choice on, before and after start.
grep -Fq 'private let crashReports = CrashReportService()' "$streamer"
grep -Fq 'crashReports.setWiFiEnabled(Self.isWiFiEnabledStored)' "$streamer"
grep -Fq 'crashReports.start()' "$streamer"
grep -Fq 'crashReports.setWiFiEnabled(enabled)' "$streamer"
grep -Fq 'self.crashReports.stop()' "$streamer"

# Receiver: validate the header before allocating, ack only after the file is
# saved, and fetch on its own thread so streaming is never delayed.
grep -q '#include "crash_report.h"' "$receiver"
grep -q 'crash_report::ParseHeader' "$receiver"
grep -q 'std::vector<uint8_t> payload(\*length)' "$receiver"
grep -q 'crash_report::kAck' "$receiver"
grep -q 'std::thread(fetch_crash_report' "$receiver"
grep -q 'start_crash_report_fetch(target' "$receiver"
