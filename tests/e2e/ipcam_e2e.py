#!/usr/bin/env python3
"""End-to-end test of the real receiver.exe with no iPhone (gate G1).

    fake iPhone (TCP 127.0.0.1:12345) -> receiver.exe --host 127.0.0.1
        -> MPEG-TS over UDP -> sink (127.0.0.1:12346) -> analyzer

Python 3.8+ standard library only. Everything runs in one process, so every
timestamp comes from one clock (time.monotonic_ns). See tests/e2e/README.md.
"""
import argparse
import collections
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

MAGIC = 0x4950434D
HEADER = struct.Struct("<IIQBI")  # protocol/stream_protocol.h: 21 bytes, little endian
CODEC_HEVC = 0
MAX_FRAME_SIZE = 16 * 1024 * 1024
PHONE_PORT = 12345
OBS_PORT = 12346
FRAME_NS = 1_000_000_000 // 60
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "fixtures", "testsrc_360p60_k60.h265")


class ScenarioFailure(Exception):
    pass


def check(ok, label, detail=""):
    if not ok:
        raise ScenarioFailure("%s%s" % (label, (": " + detail) if detail else ""))


# --------------------------------------------------------------------------
# Access units from the Annex-B fixture


def split_nals(data):
    marks = []
    i = 0
    while True:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        marks.append((j - 1 if j > 0 and data[j - 1] == 0 else j, j + 3))
        i = j + 3
    return [data[p:(marks[k + 1][0] if k + 1 < len(marks) else len(data))]
            for k, (_, p) in enumerate(marks)]


def nal_type(nal):
    return (nal[0] >> 1) & 0x3F


def is_join(types):
    return {32, 33, 34} <= types and (19 in types or 20 in types)


class AccessUnit:
    __slots__ = ("data", "join")

    def __init__(self, nals):
        self.data = b"".join(b"\x00\x00\x00\x01" + n for n in nals)
        self.join = is_join({nal_type(n) for n in nals})


def load_access_units(path):
    with open(path, "rb") as f:
        nals = split_nals(f.read())
    units, current = [], []
    for nal in nals:
        if not nal:
            continue
        if nal_type(nal) == 35:  # AUD starts an access unit; the phone sends none
            if current:
                units.append(AccessUnit(current))
            current = []
            continue
        current.append(nal)
    if current:
        units.append(AccessUnit(current))
    check(units and units[0].join, "fixture", "first access unit must be a join point")
    return units


# --------------------------------------------------------------------------
# Fake iPhone: TCP server that speaks the wire format


class FakePhone:
    def __init__(self, units, session_fn, clock_rate=1.0):
        self.units = units
        self.session_fn = session_fn
        self.clock_rate = clock_rate
        self.stop_event = threading.Event()
        self.sends = []    # (session, au_index, is_join, send_done_ns)
        self.events = []   # (name, ns, session)
        self.lock = threading.Lock()
        self.frame_number = 0
        self.origin_ns = time.monotonic_ns()
        self.server = None
        self.thread = None
        self.session_index = 0
        self.conn = None

    def start(self):
        deadline = time.monotonic() + 10
        while True:
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if os.name != "nt":
                server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                server.bind(("127.0.0.1", PHONE_PORT))
                break
            except OSError:
                server.close()
                if time.monotonic() > deadline:
                    raise ScenarioFailure("fake phone could not bind 127.0.0.1:%d" % PHONE_PORT)
                time.sleep(0.2)
        server.listen(1)
        server.settimeout(0.2)
        self.server = server
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self.stop_event.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.settimeout(10)
            k = self.session_index
            self.session_index += 1
            self.event("accept", k)
            self.conn = conn
            try:
                self.session_fn(self, conn, k)
            except OSError:
                self.event("send_error", k)
            finally:
                self.conn = None
                conn.close()
                self.event("close", k)

    def stop(self):
        self.stop_event.set()
        if self.server:
            self.server.close()
        if self.thread:
            self.thread.join(5)

    def event(self, name, session):
        with self.lock:
            self.events.append((name, time.monotonic_ns(), session))

    def events_named(self, name):
        return [e for e in self.events if e[0] == name]

    def timestamp_us(self, capture_ns=None):
        """The phone stamps a frame with its capture time on the phone's clock.
        `clock_rate` != 1 models a phone clock that runs fast or slow."""
        if capture_ns is None:
            capture_ns = time.monotonic_ns()
        return (self.origin_ns + int((capture_ns - self.origin_ns) * self.clock_rate)) // 1000

    def header(self, size, magic=MAGIC, capture_ns=None):
        self.frame_number += 1
        return HEADER.pack(magic, self.frame_number & 0xFFFFFFFF, self.timestamp_us(capture_ns),
                           CODEC_HEVC, size)

    def send_au(self, conn, index, session, capture_ns=None):
        unit = self.units[index % len(self.units)]
        conn.sendall(self.header(len(unit.data), capture_ns=capture_ns) + unit.data)
        with self.lock:
            self.sends.append((session, index, unit.join, time.monotonic_ns()))

    def stream(self, conn, session, start=0, seconds=None, count=None, paced=True,
               captured_from_ns=None):
        """Send AUs from `start` at 60 fps until stop, `seconds`, or `count`.
        Frames carry capture times on a 60 fps grid. Unpaced frames were
        captured earlier (from `captured_from_ns`) and queued: a backlog burst.
        Returns the next AU index."""
        index = start
        t0 = time.monotonic_ns()
        grid0 = t0 if captured_from_ns is None else captured_from_ns
        sent = 0
        while not self.stop_event.is_set():
            if seconds is not None and time.monotonic_ns() - t0 >= seconds * 1e9:
                break
            if count is not None and sent >= count:
                break
            if paced:
                due = t0 + sent * FRAME_NS
                delay = due - time.monotonic_ns()
                if delay > 0:
                    time.sleep(delay / 1e9)
            self.send_au(conn, index, session, capture_ns=grid0 + sent * FRAME_NS)
            index += 1
            sent += 1
        return index

    def idle(self, seconds):
        self.stop_event.wait(seconds)

    def next_join(self, index):
        while not self.units[index % len(self.units)].join:
            index += 1
        return index


# --------------------------------------------------------------------------
# UDP sink standing in for OBS


class UdpSink:
    """Receives datagrams on its own thread; the main thread drains them with
    take(), so a long soak keeps no backlog in memory."""

    def __init__(self, rcvbuf=16 * 1024 * 1024):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        try:
            self.sock.bind(("127.0.0.1", OBS_PORT))
        except OSError as error:
            raise ScenarioFailure("UDP sink could not bind 127.0.0.1:%d (is OBS or another "
                                  "receiver test running?): %s" % (OBS_PORT, error))
        self.sock.settimeout(0.2)
        self.queue = collections.deque()  # (arrival_ns, bytes); deque is thread-safe
        self.count = 0
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()

    def _run(self):
        while not self.stop_event.is_set():
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            self.queue.append((time.monotonic_ns(), data))
            self.count += 1

    def take(self):
        while True:
            try:
                yield self.queue.popleft()
            except IndexError:
                return

    def stop(self):
        self.stop_event.set()
        self.thread.join(5)
        self.sock.close()


# --------------------------------------------------------------------------
# MPEG-TS analyzer


class Pes:
    """One relayed video PES. Its payload is dropped once it is complete."""
    __slots__ = ("arrival_ns", "pts", "types")

    def __init__(self, arrival_ns):
        self.arrival_ns = arrival_ns
        self.pts = None
        self.types = frozenset()

    def nal_types(self):
        return self.types


def parse_pts(b):
    return (((b[0] >> 1) & 0x07) << 30) | (b[1] << 22) | ((b[2] >> 1) << 15) | (b[3] << 7) | (b[4] >> 1)


def section_payload(pkt, start):
    pointer = pkt[start]
    return pkt[start + 1 + pointer:]


class TsAnalyzer:
    """Incremental MPEG-TS parser: PAT -> PMT -> HEVC PID (stream_type 0x24),
    continuity counters, and PES packets with PTS and NAL types."""

    def __init__(self, capture_path, capture_limit=256 * 2**20):
        self.pmt_pids = set()
        self.video_pid = None
        self.last_cc = {}
        self.cc_errors = 0
        self.pes = []
        self.stray = 0
        self.current = None
        self.current_data = bytearray()
        self.capture = open(capture_path, "wb")
        self.capture_left = capture_limit

    def _finish_pes(self):
        pes, data = self.current, self.current_data
        if pes is None:
            return
        if len(data) >= 14 and data[:3] == b"\x00\x00\x01" and data[7] & 0x80:
            pes.pts = parse_pts(data[9:14])
        if len(data) >= 9:
            pes.types = frozenset(nal_type(n) for n in split_nals(bytes(data[9 + data[8]:])) if n)
        self.current, self.current_data = None, bytearray()

    def feed(self, arrival, data):
        if self.capture_left > 0:
            self.capture.write(data)
            self.capture_left -= len(data)
        if len(data) % 188:
            self.stray += 1
        for off in range(0, len(data) - 187, 188):
            pkt = data[off:off + 188]
            if pkt[0] != 0x47:
                self.stray += 1
                continue
            pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
            pusi = bool(pkt[1] & 0x40)
            afc = (pkt[3] >> 4) & 0x3
            cc = pkt[3] & 0x0F
            start = 4
            discontinuity = False
            if afc & 0x2:
                af_len = pkt[4]
                discontinuity = af_len > 0 and bool(pkt[5] & 0x80)
                start = 5 + af_len
            if afc & 0x1:
                last = self.last_cc.get(pid)
                if last is not None and not discontinuity and cc != (last + 1) & 0xF and cc != last:
                    self.cc_errors += 1
                self.last_cc[pid] = cc
            if not afc & 0x1 or start >= 188:
                continue
            if pid == 0 and pusi:
                table = section_payload(pkt, start)
                length = ((table[1] & 0x0F) << 8) | table[2]
                for i in range(8, 3 + length - 4, 4):
                    if (table[i] << 8) | table[i + 1]:
                        self.pmt_pids.add(((table[i + 2] & 0x1F) << 8) | table[i + 3])
            elif pid in self.pmt_pids and pusi:
                table = section_payload(pkt, start)
                length = ((table[1] & 0x0F) << 8) | table[2]
                i = 12 + (((table[10] & 0x0F) << 8) | table[11])
                while i + 5 <= 3 + length - 4:
                    if table[i] == 0x24:
                        self.video_pid = ((table[i + 1] & 0x1F) << 8) | table[i + 2]
                    i += 5 + (((table[i + 3] & 0x0F) << 8) | table[i + 4])
            elif pid == self.video_pid:
                if pusi:
                    self._finish_pes()
                    self.current = Pes(arrival)
                    self.pes.append(self.current)
                if self.current is not None:
                    self.current_data += pkt[start:]

    def result(self):
        self._finish_pes()
        self.capture.close()
        return {"video_pid": self.video_pid, "cc_errors": self.cc_errors, "pes": self.pes,
                "stray": self.stray}


# --------------------------------------------------------------------------
# Receiver process


class WindowsProcessProbe:
    """Private bytes and handle count of a process (ctypes, Windows only)."""

    def __init__(self, pid):
        import ctypes
        from ctypes import wintypes
        self.ctypes = ctypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
                (name, ctypes.c_size_t) for name in (
                    "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                    "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage",
                    "PagefileUsage", "PeakPagefileUsage")]

        self.Counters = Counters
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel32.OpenProcess.restype = wintypes.HANDLE
        self.kernel32.K32GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD]
        self.kernel32.GetProcessHandleCount.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        self.kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.kernel32.OpenProcess(0x1000 | 0x0010, False, pid)

    def sample(self):
        if not self.handle:
            return None
        counters = self.Counters()
        counters.cb = self.ctypes.sizeof(counters)
        count = self.ctypes.c_ulong()
        if not self.kernel32.K32GetProcessMemoryInfo(self.handle, self.ctypes.byref(counters), counters.cb):
            return None
        if not self.kernel32.GetProcessHandleCount(self.handle, self.ctypes.byref(count)):
            return None
        return counters.PagefileUsage, count.value

    def close(self):
        if self.handle:
            self.kernel32.CloseHandle(self.handle)
            self.handle = None


class Receiver:
    def __init__(self, exe, workdir):
        self.log_path = os.path.join(workdir, "receiver.log")
        self.log = open(self.log_path, "wb")
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        self.proc = subprocess.Popen([os.path.abspath(exe), "--host", "127.0.0.1"], stdout=self.log,
                                     stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     creationflags=flags)
        self.probe = WindowsProcessProbe(self.proc.pid) if os.name == "nt" else None
        self.clean_stop = False

    def alive(self):
        return self.proc.poll() is None

    def memory(self):
        return self.probe.sample() if self.probe else None

    def stop(self):
        if self.alive() and os.name == "nt":
            try:
                os.kill(self.proc.pid, signal.CTRL_BREAK_EVENT)
                self.proc.wait(6)
                self.clean_stop = True
            except (OSError, subprocess.TimeoutExpired):
                pass
        if self.alive():
            self.proc.terminate()
            self.proc.wait(5)
        if self.probe:
            self.probe.close()
        self.log.close()

    def text(self):
        with open(self.log_path, "rb") as f:
            return f.read().decode("utf-8", "replace")


# --------------------------------------------------------------------------
# Scenarios


def ms(ns):
    return ns / 1e6


def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def pts_minus_arrival(pes_list):
    """PTS (ms) minus PC arrival (ms), both relative to the first PES."""
    timed = [p for p in pes_list if p.pts is not None]
    if not timed:
        return []
    p0, a0 = timed[0].pts, timed[0].arrival_ns
    return [((p.pts - p0) / 90.0) - ms(p.arrival_ns - a0) for p in timed]


def common_checks(ctx, summary):
    pes = ctx["ts"]["pes"]
    check(ctx["alive"], "A1 receiver stayed alive", "exit code %s" % ctx["receiver"].proc.returncode)
    check(ctx["ts"]["video_pid"] is not None, "relay produced an HEVC stream", "no PMT with stream_type 0x24")
    check(pes, "relay produced video PES packets")
    check(is_join(pes[0].nal_types()), "A2 first PES is a join point",
          "NAL types %s" % sorted(pes[0].nal_types()))
    pts = [p.pts for p in pes if p.pts is not None]
    check(all(b > a for a, b in zip(pts, pts[1:])), "A5 PTS strictly increasing")
    check(ctx["ts"]["stray"] == 0, "TS packets are 188-byte aligned")
    summary["pes"] = len(pes)
    summary["cc_errors"] = ctx["ts"]["cc_errors"]


def latency_summary(pes, relayed, summary):
    lat = [ms(p.arrival_ns - s[3]) for p, s in zip(pes, relayed)]
    summary["latency_ms"] = {"p50": percentile(lat, 0.5), "p95": percentile(lat, 0.95),
                             "max": max(lat) if lat else None}
    return lat


def ffmpeg_decode_errors(workdir):
    """Decodes every frame of capture.ts with ffprobe and returns its error output.
    ffprobe, not `ffmpeg -f null`: the ffmpeg CLI re-times frames to 1/60 s for
    its output, so two frames that arrived 1 ms apart (valid, strictly
    increasing 90 kHz PTS) are reported as a muxer DTS error that OBS never sees."""
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return None
    result = subprocess.run([ffprobe, "-v", "error", "-show_entries", "frame=key_frame",
                             "-of", "csv=p=0", os.path.join(workdir, "capture.ts")],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    frames = len(result.stdout.split())
    errors = result.stderr.decode("utf-8", "replace").strip()
    if result.returncode != 0 and not errors:
        errors = "ffprobe exited with %d" % result.returncode
    return errors if errors or frames else "ffprobe decoded no frames"


# steady: one 6 s session from an IDR.
def steady_session(ph, conn, k):
    ph.stream(conn, k, start=0)


def steady_check(ctx, summary):
    common_checks(ctx, summary)
    pes, sends = ctx["ts"]["pes"], ctx["phone"].sends
    first_join = next(i for i, s in enumerate(sends) if s[2])
    relayed = sends[first_join:]
    summary["sent"] = len(relayed)
    check(len(relayed) - 2 <= len(pes) <= len(relayed), "A3 relayed PES count",
          "%d PES for %d AUs sent" % (len(pes), len(relayed)))
    check(ctx["ts"]["cc_errors"] == 0, "A4 continuity-counter errors", str(ctx["ts"]["cc_errors"]))
    errors = ffmpeg_decode_errors(ctx["workdir"])
    summary["ffmpeg_decode"] = "skipped (no ffprobe on PATH)" if errors is None else (errors or "clean")
    check(not errors, "A6 ffprobe decodes capture.ts without errors", (errors or "")[:400])
    lat = latency_summary(pes, relayed, summary)
    check(percentile(lat, 0.95) < 50, "A7 relay latency p95 < 50 ms", "%.1f ms" % percentile(lat, 0.95))


# midgop: every session starts on a delta frame.
def midgop_session(ph, conn, k):
    ph.stream(conn, k, start=10)


def midgop_check(ctx, summary):
    common_checks(ctx, summary)
    check("waiting for HEVC VPS/SPS/PPS+IDR join AU" in ctx["log"], "receiver logged the join wait")
    pes, sends = ctx["ts"]["pes"], ctx["phone"].sends
    relayed = sends[next(i for i, s in enumerate(sends) if s[2]):]
    check(len(relayed) - 2 <= len(pes) <= len(relayed), "no PES before the first join AU",
          "%d PES for %d AUs from the first join" % (len(pes), len(relayed)))


# disconnect: the phone closes after 2 s; the next session starts on an IDR.
RECONNECT_GAP_LIMIT_S = 1.5  # T1.8: 250 ms reconnect delay (3.0 with the old 1 s delay)


def disconnect_session(ph, conn, k):
    ph.stream(conn, k, start=0, seconds=2.0 if k == 0 else None)


def first_pes_after(pes, ns):
    return next((p for p in pes if p.arrival_ns > ns), None)


def disconnect_check(ctx, summary):
    common_checks(ctx, summary)
    phone, pes = ctx["phone"], ctx["ts"]["pes"]
    closes = [e for e in phone.events_named("close") if e[2] == 0]
    check(closes, "phone closed session 1")
    check(len(phone.events_named("accept")) >= 2, "receiver reconnected")
    # Frames still in flight at the close are relayed after it, so measure to
    # the first PES of the next session.
    resumed = first_pes_after(pes, phone.events_named("accept")[1][1])
    check(resumed is not None, "relay resumed after the reconnect")
    gap = (resumed.arrival_ns - closes[0][1]) / 1e9
    summary["reconnect_gap_s"] = round(gap, 3)
    check(gap < RECONNECT_GAP_LIMIT_S, "reconnect gap < %.1f s" % RECONNECT_GAP_LIMIT_S, "%.3f s" % gap)
    check(is_join(resumed.nal_types()), "session 2 starts at a join point")
    check(ctx["ts"]["cc_errors"] == 0, "continuity counters survive the reconnect",
          str(ctx["ts"]["cc_errors"]))


# stall: 3 s pause between frames on the same socket.
def stall_session(ph, conn, k):
    index = ph.stream(conn, k, start=0, seconds=1.5)
    ph.event("stall_start", k)
    ph.idle(3.0)
    ph.event("stall_end", k)
    ph.stream(conn, k, start=index)


def stall_check(ctx, summary):
    common_checks(ctx, summary)
    phone = ctx["phone"]
    # One "stream ended" is the test teardown closing the fake phone.
    check(ctx["log"].count("stream ended") <= 1 and len(phone.events_named("accept")) == 1,
          "a 3 s idle stall does not reconnect")
    end = phone.events_named("stall_end")
    check(end, "stall happened")
    check(first_pes_after(ctx["ts"]["pes"], end[0][1]) is not None, "relaying resumed after the stall")
    check(ctx["ts"]["cc_errors"] == 0, "continuity-counter errors", str(ctx["ts"]["cc_errors"]))


# stall_timeout: the phone stops in the middle of a frame for 7 s.
def stall_timeout_session(ph, conn, k):
    if k > 0:
        ph.stream(conn, k, start=0)
        return
    index = ph.stream(conn, k, start=0, seconds=1.5)
    unit = ph.units[index % len(ph.units)]
    conn.sendall(ph.header(len(unit.data)) + unit.data[:len(unit.data) // 2])
    ph.event("stall_start", k)
    # A real phone sees the close: stay silent for up to 7 s, but stop as soon
    # as the receiver gives up on the frame, so accept() is not delayed.
    deadline = time.monotonic() + 7.0
    while time.monotonic() < deadline and not ph.stop_event.is_set():
        conn.settimeout(0.1)
        try:
            if conn.recv(1) == b"":
                ph.event("receiver_closed", k)
                return
        except socket.timeout:
            continue
        except OSError:
            ph.event("receiver_closed", k)
            return


def stall_timeout_check(ctx, summary):
    common_checks(ctx, summary)
    phone = ctx["phone"]
    check("timed out waiting for video frame" in ctx["log"], "receiver logged the payload timeout")
    start = phone.events_named("stall_start")
    check(start, "stall happened")
    accepts = phone.events_named("accept")
    check(len(accepts) >= 2, "receiver reconnected after the timeout")
    resumed = first_pes_after(ctx["ts"]["pes"], accepts[1][1])
    check(resumed is not None, "relaying resumed after the timeout")
    gap = (resumed.arrival_ns - start[0][1]) / 1e9
    summary["recovered_after_s"] = round(gap, 3)
    check(gap < 10.0, "relaying resumed within 10 s of the stall start", "%.3f s" % gap)


# garbage / oversize: one invalid header, then a good session.
def invalid_header_session(oversize):
    def session(ph, conn, k):
        if k == 0:
            if oversize:
                conn.sendall(ph.header(MAX_FRAME_SIZE + 1))
            else:
                conn.sendall(ph.header(100, magic=0xDEADBEEF))
            ph.event("bad_header", k)
            conn.settimeout(3)
            try:
                closed = conn.recv(1) == b""
            except socket.timeout:
                closed = False
            except OSError:
                closed = True
            ph.event("receiver_closed" if closed else "receiver_kept_open", k)
            return
        ph.stream(conn, k, start=0)
    return session


def invalid_header_check(ctx, summary):
    common_checks(ctx, summary)
    phone = ctx["phone"]
    check("invalid stream header" in ctx["log"], "receiver logged 'invalid stream header'")
    check(phone.events_named("receiver_closed"), "receiver dropped the session without reading a payload")
    check(len(phone.events_named("accept")) >= 2, "receiver reconnected")
    check(all(s[0] >= 1 for s in phone.sends), "no frame was sent in the bad session")
    check(len(ctx["ts"]["pes"]) > 60, "next session relays", "%d PES" % len(ctx["ts"]["pes"]))


# burst: a 300 ms pause, then 18 frames back to back.
BURST_OFFSET_LIMIT_MS = 5.0  # G5: PTS follows arrival, so a burst cannot leave it late


def burst_session(ph, conn, k):
    index = ph.stream(conn, k, start=0, seconds=2.0)
    paused_ns = time.monotonic_ns()
    ph.event("pause", k)
    ph.idle(0.3)
    ph.event("burst", k)
    # The camera kept capturing during the pause: 18 queued frames go out at once.
    index = ph.stream(conn, k, start=index, count=18, paced=False, captured_from_ns=paused_ns)
    ph.event("burst_end", k)
    ph.stream(conn, k, start=index)


def burst_check(ctx, summary):
    common_checks(ctx, summary)
    pes, sends = ctx["ts"]["pes"], ctx["phone"].sends
    check(len(sends) - 2 <= len(pes) <= len(sends), "every burst frame relayed",
          "%d PES for %d AUs" % (len(pes), len(sends)))
    check(ctx["ts"]["cc_errors"] == 0, "continuity-counter errors", str(ctx["ts"]["cc_errors"]))
    offsets = pts_minus_arrival(pes)
    pause_ns = ctx["phone"].events_named("pause")[0][1]
    before = [o for p, o in zip(pes, offsets) if p.arrival_ns < pause_ns]
    summary["pts_minus_arrival_ms"] = {"min": round(min(offsets), 2), "max": round(max(offsets), 2),
                                       "before_pause": round(before[-1], 2), "last": round(offsets[-1], 2)}
    if BURST_OFFSET_LIMIT_MS is not None:
        drift = abs(offsets[-1] - before[-1])
        check(min(offsets) > -BURST_OFFSET_LIMIT_MS, "burst frames are not stamped behind their arrival",
              "min %.1f ms" % min(offsets))
        check(drift <= BURST_OFFSET_LIMIT_MS, "PTS returns to the arrival timeline after a burst",
              "offset moved %.1f ms" % drift)


# drift: the phone clock runs 1% fast (real crystals differ by ~20-50 ppm, which
# is 0.07-0.18 s per hour; 1% makes an hour of drift visible in 20 s). OBS
# schedules frames by PTS, so a PTS timeline that outruns the PC clock is
# delay that OBS adds and never drains.
DRIFT_CLOCK_RATE = 1.01
DRIFT_LIMIT_MS = 15.0


def drift_session(ph, conn, k):
    ph.stream(conn, k, start=0)


def drift_check(ctx, summary):
    common_checks(ctx, summary)
    pes = ctx["ts"]["pes"]
    offsets = pts_minus_arrival(pes)
    settle = [o for p, o in zip(pes, offsets) if p.arrival_ns - pes[0].arrival_ns >= 2e9]
    check(len(settle) > 600, "drift ran long enough", "%d PES after 2 s" % len(settle))
    moved = settle[-1] - settle[0]
    summary["pts_minus_arrival_ms"] = {"at_2s": round(settle[0], 2), "last": round(settle[-1], 2),
                                       "moved": round(moved, 2)}
    check(abs(moved) <= DRIFT_LIMIT_MS, "relay PTS follows the PC clock, not the phone clock",
          "PTS moved %.1f ms against PC arrival with the phone clock %.0f%% fast"
          % (moved, (DRIFT_CLOCK_RATE - 1) * 100))


# soak: repeated sessions while the receiver's memory and handles are sampled.
def soak_session_fn(session_seconds):
    def session(ph, conn, k):
        ph.stream(conn, k, start=0, seconds=session_seconds)
    return session


def soak_check(ctx, summary):
    common_checks(ctx, summary)
    phone, pes = ctx["phone"], ctx["ts"]["pes"]
    accepts = phone.events_named("accept")
    summary["sessions"] = len(accepts)
    check(len(accepts) >= 2, "soak ran several sessions")
    for _, ns, k in accepts:
        check(first_pes_after(pes, ns) is not None, "session %d relayed video" % k)
    check(ctx["ts"]["cc_errors"] == 0, "continuity-counter errors", str(ctx["ts"]["cc_errors"]))
    samples = ctx["memory"]
    if samples:
        warm = [s for s in samples if s[0] >= 10.0] or samples
        third = max(1, len(warm) // 3)
        early_mem = min(s[1] for s in warm[:third])
        late_mem = max(s[1] for s in warm[-third:])
        early_handles = min(s[2] for s in warm[:third])
        late_handles = max(s[2] for s in warm[-third:])
        summary["private_mib"] = {"early": round(early_mem / 2**20, 2), "late": round(late_mem / 2**20, 2)}
        summary["handles"] = {"early": early_handles, "late": late_handles}
        check(late_mem - early_mem <= 8 * 2**20, "receiver memory stays flat",
              "%.2f MiB growth" % ((late_mem - early_mem) / 2**20))
        check(late_handles - early_handles <= 24, "receiver handle count stays flat",
              "%d -> %d" % (early_handles, late_handles))


SCENARIOS = {  # name: (seconds or None for --duration, session factory, checks[, phone clock rate])
    "steady": (6.0, lambda a: steady_session, steady_check),
    "midgop": (4.0, lambda a: midgop_session, midgop_check),
    "disconnect": (6.0, lambda a: disconnect_session, disconnect_check),
    "stall": (7.0, lambda a: stall_session, stall_check),
    "stall_timeout": (14.0, lambda a: stall_timeout_session, stall_timeout_check),
    "garbage": (4.0, lambda a: invalid_header_session(False), invalid_header_check),
    "oversize": (4.0, lambda a: invalid_header_session(True), invalid_header_check),
    "burst": (4.0, lambda a: burst_session, burst_check),
    "drift": (20.0, lambda a: drift_session, drift_check, DRIFT_CLOCK_RATE),
    "soak": (None, lambda a: soak_session_fn(a.session_seconds), soak_check),
}


def run(args):
    duration, make_session, verify = SCENARIOS[args.scenario][:3]
    clock_rate = SCENARIOS[args.scenario][3] if len(SCENARIOS[args.scenario]) > 3 else 1.0
    if duration is None:
        duration = args.duration
    units = load_access_units(args.fixture)
    workdir = args.workdir or tempfile.mkdtemp(prefix="ipcam_e2e_%s_" % args.scenario)
    os.makedirs(workdir, exist_ok=True)
    print("E2E %s: workdir %s" % (args.scenario, workdir), flush=True)
    sink = UdpSink()
    analyzer = TsAnalyzer(os.path.join(workdir, "capture.ts"))
    phone = FakePhone(units, make_session(args), clock_rate)
    receiver = None
    memory = []
    try:
        sink.start()
        phone.start()
        receiver = Receiver(args.receiver, workdir)
        t0 = time.monotonic()
        next_report = t0 + 60
        while time.monotonic() - t0 < duration and receiver.alive():
            time.sleep(1.0)
            for arrival, data in sink.take():
                analyzer.feed(arrival, data)
            sample = receiver.memory()
            if sample:
                memory.append((time.monotonic() - t0, sample[0], sample[1]))
            if time.monotonic() >= next_report:
                next_report += 60
                print("E2E %s: %.0f s, %d datagrams, %d PES, private %.1f MiB, %d handles" % (
                    args.scenario, time.monotonic() - t0, sink.count, len(analyzer.pes),
                    (sample[0] / 2**20) if sample else 0, sample[1] if sample else 0), flush=True)
        phone.stop()
        time.sleep(0.5)
        alive = receiver.alive()
    finally:
        phone.stop()
        sink.stop()
        if receiver:
            receiver.stop()
    for arrival, data in sink.take():
        analyzer.feed(arrival, data)
    ctx = {"alive": alive, "receiver": receiver, "phone": phone, "workdir": workdir,
           "ts": analyzer.result(), "log": receiver.text(), "memory": memory}
    summary = {"scenario": args.scenario, "seconds": duration, "datagrams": sink.count,
               "clean_stop": receiver.clean_stop}
    try:
        verify(ctx, summary)
    except ScenarioFailure as failure:
        summary["failed"] = str(failure)
        print("E2E_SUMMARY " + json.dumps(summary), flush=True)
        print("E2E FAIL %s: %s (see %s)" % (args.scenario, failure, receiver.log_path), flush=True)
        return 1
    print("E2E_SUMMARY " + json.dumps(summary), flush=True)
    print("E2E PASS %s" % args.scenario, flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--receiver", required=True, help="path to receiver.exe")
    parser.add_argument("--scenario", required=True, choices=sorted(SCENARIOS))
    parser.add_argument("--workdir", help="keep logs and capture.ts here (default: a temp dir)")
    parser.add_argument("--fixture", default=FIXTURE,
                        help="Annex-B HEVC file with AUDs and closed GOPs (see README); default the 360p fixture")
    parser.add_argument("--duration", type=float, default=45.0, help="soak: total seconds")
    parser.add_argument("--session-seconds", type=float, default=15.0, help="soak: seconds per phone session")
    args = parser.parse_args()
    try:
        return run(args)
    except ScenarioFailure as failure:
        print("E2E FAIL %s: %s" % (args.scenario, failure), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
