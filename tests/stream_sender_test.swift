import Foundation

// Real-socket test of StreamSender (T0.7). Runs on macOS: the sender only
// needs Foundation and Network. Payload byte 0 is "K" (keyframe) or "D"
// (delta); byte 1 is a sequence number.

func check(_ ok: Bool, _ msg: String) {
    if !ok {
        print("FAIL: \(msg)")
        exit(1)
    }
}

func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return cond()
}

func connectClient(deadline: TimeInterval) -> Int32? {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = StreamSender.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return fd }
        close(fd)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return nil
}

/// Returns exactly `n` bytes, or nil on timeout/close.
func readExact(_ fd: Int32, _ n: Int, timeout: TimeInterval) -> Data? {
    var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var out = Data()
    var buf = [UInt8](repeating: 0, count: n)
    while out.count < n {
        let got = recv(fd, &buf, n - out.count, 0)
        if got <= 0 { return nil }
        out.append(contentsOf: buf[0..<got])
    }
    return out
}

struct Packet {
    let magic: UInt32
    let frameNumber: UInt32
    let timestampUs: UInt64
    let codec: UInt8
    let payload: Data
}

func readPacket(_ fd: Int32, timeout: TimeInterval) -> Packet? {
    guard let h = readExact(fd, StreamHeader.size, timeout: timeout) else { return nil }
    func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(h[h.startIndex + o + $1]) << UInt32(8 * $1) } }
    func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(h[h.startIndex + o + $1]) << UInt64(8 * $1) } }
    let size = Int(u32(17))
    guard size <= 1_000_000, let payload = readExact(fd, size, timeout: timeout) else { return nil }
    return Packet(magic: u32(0), frameNumber: u32(4), timestampUs: u64(8),
                  codec: h[h.startIndex + 16], payload: payload)
}

func payload(_ kind: Character, _ seq: UInt8) -> Data {
    Data([kind.asciiValue!, seq])
}

let sender = StreamSender()
var connectedCount = 0
sender.onClientConnected = { connectedCount += 1 }
sender.start()

// C1: a client connects and onClientConnected fires.
guard let c1 = connectClient(deadline: 3) else { check(false, "C1 client could not connect"); exit(1) }
check(waitUntil(3) { connectedCount == 1 }, "C1 onClientConnected did not fire")

// C2: delta before any keyframe is not delivered; keyframe then delta are, in order.
sender.send(frameNumber: 1, timestampUs: 1_000, codec: 0, isKeyframe: false, frame: payload("D", 1))
check(readPacket(c1, timeout: 0.3) == nil, "C2 delta was delivered before any keyframe")
sender.send(frameNumber: 2, timestampUs: 2_000_000_123, codec: 0, isKeyframe: true, frame: payload("K", 2))
guard let k = readPacket(c1, timeout: 3) else { check(false, "C2 keyframe not delivered"); exit(1) }
check(k.magic == 0x4950434D, "C2 bad magic")
check(k.payload == payload("K", 2), "C2 keyframe payload mismatch")
sender.send(frameNumber: 3, timestampUs: 3_000, codec: 0, isKeyframe: false, frame: payload("D", 3))
guard let d = readPacket(c1, timeout: 3) else { check(false, "C2 delta after keyframe not delivered"); exit(1) }
check(d.payload == payload("D", 3), "C2 delta payload mismatch")

// C3: header fields round-trip.
check(k.frameNumber == 2, "C3 frameNumber")
check(k.timestampUs == 2_000_000_123, "C3 timestampUs")
check(k.codec == 0, "C3 codec")

// C4: client closes; a new client connects and the keyframe gate is re-armed.
close(c1)
guard let c2 = connectClient(deadline: 5) else { check(false, "C4 reconnect failed"); exit(1) }
check(waitUntil(5) { connectedCount == 2 }, "C4 onClientConnected did not fire again")
sender.send(frameNumber: 4, timestampUs: 4_000, codec: 0, isKeyframe: false, frame: payload("D", 4))
check(readPacket(c2, timeout: 0.3) == nil, "C4 delta delivered before keyframe on new connection")
sender.send(frameNumber: 5, timestampUs: 5_000, codec: 0, isKeyframe: true, frame: payload("K", 5))
check(readPacket(c2, timeout: 3)?.payload == payload("K", 5), "C4 keyframe not delivered on new connection")

// C6 (T1.2): restartListening closes the client; a new client reconnects fast
// and receives a keyframe. Repeated to catch TIME_WAIT rebind failures.
var expectedConnects = connectedCount
for round in 1...5 {
    guard let fd = connectClient(deadline: 5) else { check(false, "C6 round \(round) connect failed"); exit(1) }
    expectedConnects += 1
    check(waitUntil(5) { connectedCount == expectedConnects }, "C6 round \(round) onClientConnected")
    sender.send(frameNumber: UInt32(100 + round), timestampUs: 1, codec: 0, isKeyframe: true, frame: payload("K", UInt8(round)))
    check(readPacket(fd, timeout: 3)?.payload == payload("K", UInt8(round)), "C6 round \(round) keyframe not delivered")
    sender.restartListening(reason: "test")
    check(readExact(fd, 1, timeout: 3) == nil, "C6 round \(round) expected EOF")
    close(fd)
}

// C7 (T1.3): resetForDiscontinuity keeps the connection, gates deltas, then a keyframe flows.
guard let c7 = connectClient(deadline: 5) else { check(false, "C7 connect failed"); exit(1) }
check(waitUntil(5) { connectedCount == expectedConnects + 1 }, "C7 onClientConnected")
sender.send(frameNumber: 200, timestampUs: 1, codec: 0, isKeyframe: true, frame: payload("K", 1))
check(readPacket(c7, timeout: 3)?.payload == payload("K", 1), "C7 initial keyframe")
sender.resetForDiscontinuity(reason: "test")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
sender.send(frameNumber: 201, timestampUs: 2, codec: 0, isKeyframe: false, frame: payload("D", 2))
check(readPacket(c7, timeout: 1) == nil, "C7 connection closed or delta delivered after reset")
sender.send(frameNumber: 202, timestampUs: 3, codec: 0, isKeyframe: true, frame: payload("K", 3))
check(readPacket(c7, timeout: 3)?.payload == payload("K", 3), "C7 keyframe after reset")
close(c7)

// C8 (T1.6): queue overflow must drop to the next keyframe, never to a delta.
var keyFrameRequests = 0
sender.onKeyFrameNeeded = { keyFrameRequests += 1 }
guard let c8 = connectClient(deadline: 5) else { check(false, "C8 connect failed"); exit(1) }
check(waitUntil(5) { connectedCount == expectedConnects + 2 }, "C8 onClientConnected")
let big = Data(repeating: 0, count: 256 * 1024)
for i in 0..<200 {
    var f = big
    f[0] = i == 0 ? Character("K").asciiValue! : Character("D").asciiValue!
    f[1] = UInt8(i & 0xFF)
    sender.send(frameNumber: UInt32(1000 + i), timestampUs: UInt64(i), codec: 0, isKeyframe: i == 0, frame: f)
}
check(waitUntil(5) { keyFrameRequests >= 1 }, "C8 onKeyFrameNeeded never fired")
// Drain everything delivered so far, then offer a fresh keyframe and deltas.
var seen: [Packet] = []
while let p = readPacket(c8, timeout: 0.5) { seen.append(p) }
for i in 0..<6 {
    var f = big
    f[0] = i == 0 ? Character("K").asciiValue! : Character("D").asciiValue!
    sender.send(frameNumber: UInt32(5000 + i), timestampUs: UInt64(i), codec: 0, isKeyframe: i == 0, frame: f)
}
while let p = readPacket(c8, timeout: 1) { seen.append(p); if p.frameNumber == 5005 { break } }
check(seen.last?.frameNumber == 5005, "C8 fresh keyframe + deltas not delivered")
for idx in 1..<seen.count where seen[idx].frameNumber != seen[idx - 1].frameNumber + 1 {
    check(seen[idx].payload.first == Character("K").asciiValue!, "C8 packet after a gap (frame \(seen[idx].frameNumber)) is not a keyframe")
}
close(c8)

// C9 (T2.2 review): onQueueLatency reports a finite, plausible window max
// once per 60 sent frames. Client reads every packet so the queue never overflows.
var queueLatencies: [Double] = []
sender.onQueueLatency = { queueLatencies.append($0) }
guard let c9 = connectClient(deadline: 5) else { check(false, "C9 connect failed"); exit(1) }
check(waitUntil(5) { connectedCount == expectedConnects + 3 }, "C9 onClientConnected")
for i in 0..<60 {
    sender.send(frameNumber: UInt32(9000 + i), timestampUs: UInt64(i), codec: 0, isKeyframe: true, frame: payload("K", UInt8(i)))
    check(readPacket(c9, timeout: 3) != nil, "C9 frame \(i) not delivered")
}
check(waitUntil(3) { !queueLatencies.isEmpty }, "C9 onQueueLatency never fired after 60 frames")
check(queueLatencies[0].isFinite && queueLatencies[0] >= 0 && queueLatencies[0] < 5_000,
      "C9 implausible queue latency \(queueLatencies[0]) ms")
close(c9)

// C5: stop() refuses new connections.
sender.stop()
close(c2)
check(waitUntil(3) {
    guard let fd = connectClient(deadline: 0.1) else { return true }
    close(fd)
    return false
}, "C5 connections still accepted after stop()")

print("stream_sender_test: all cases passed")
exit(0)
