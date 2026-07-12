import AVFoundation
import VideoToolbox
import Darwin

/// Steps 1-4: 4K60 capture -> hardware HEVC (Annex-B) -> file + USB send.
/// No UI, no segmentation. Prints a 1 Hz performance dashboard.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private var encoder: VTCompressionSession?
    private var outputFile: FileHandle?
    private let sender = StreamSender()
    private var frameNumber: UInt32 = 0
    private var wroteParameterSets = false
    private let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    private let stats = Stats()
    private var dashboardTimer: DispatchSourceTimer?
    private var lastCaptureUs: UInt64 = 0

    // MARK: - Step 1: permission + session start
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                print("ERROR: camera permission denied")
                return
            }
            self.configureSession()
        }
    }

    // MARK: - Step 2/3: enumerate + configure 3840x2160@60 HEVC
    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd4K3840x2160

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            print("ERROR: no back camera")
            return
        }

        print("CAMERA: \(device.localizedName)")
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let maxFps = format.videoSupportedFrameRateRanges
                .map { $0.maxFrameRate }.max() ?? 0
            print("FORMAT: \(dims.width)x\(dims.height) maxFps=\(maxFps)")
        }

        do {
            try device.lockForConfiguration()
            if let fmt = device.formats.first(where: { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return d.width == 3840 && d.height == 2160 &&
                    f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 })
            }) {
                device.activeFormat = fmt
                let dur = CMTime(value: 1, timescale: 60)
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
                print("CONFIG: active 3840x2160@60")
            } else {
                print("WARN: no 4K60 format, using preset fallback")
            }
            device.unlockForConfiguration()
        } catch {
            print("ERROR: lockForConfiguration \(error)")
        }

        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "capture"))
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        session.commitConfiguration()

        openOutputFile()
        createEncoder(width: 3840, height: 2160)
        session.startRunning()
        sender.start()
        startDashboard()
        print("STATUS: Camera Active")
    }

    // MARK: - Step 4: VideoToolbox hardware HEVC encoder
    private func createEncoder(width: Int, height: Int) {
        var session: VTCompressionSession?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { (refcon, _, status, _, sampleBuffer) in
                guard let sb = sampleBuffer, status == noErr else { return }
                let streamer = Unmanaged<CameraStreamer>.fromOpaque(refcon!).takeUnretainedValue()
                streamer.writeAnnexB(sampleBuffer: sb)
            },
            refcon: refcon,
            compressionSessionOut: &session)

        guard status == noErr, let enc = session else {
            print("ERROR: VTCompressionSessionCreate \(status)")
            return
        }
        encoder = enc
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(enc)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastCaptureUs = monotonicUs()
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(encoder!,
                                        imageBuffer: px,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: &flags)
        frameNumber &+= 1
        stats.recordFrame()
    }

    // MARK: - Annex-B conversion (length-prefixed -> start codes)
    func writeAnnexB(sampleBuffer: CMSampleBuffer) {
        let encodeLatencyUs = monotonicUs() &- lastCaptureUs
        stats.recordLatencyUs(encodeLatencyUs)

        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var annexB = Data()

        if !wroteParameterSets {
            var count: Int = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                desc,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    desc,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &len,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                if let ptr, len > 0 {
                    annexB.append(contentsOf: startCode)
                    annexB.append(Data(bytes: ptr, count: len))
                }
            }
            wroteParameterSets = true
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var total: Int = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &total, dataPointerOut: &ptr)
        guard let base = ptr, total > 0 else { return }

        var offset = 0
        while offset + 4 <= total {
            let nalLen = Int(base[offset]) << 24 | Int(base[offset+1]) << 16
                       | Int(base[offset+2]) << 8 | Int(base[offset+3])
            offset += 4
            annexB.append(contentsOf: startCode)
            annexB.append(Data(bytes: base + offset, count: nalLen))
            offset += nalLen
        }

        outputFile?.write(annexB)
        sender.send(frameNumber: frameNumber,
                    timestampUs: lastCaptureUs,
                    codec: StreamCodec.hevc.rawValue,
                    frame: annexB)
    }

    // MARK: - Dashboard (1 Hz)
    private func startDashboard() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dashboard"))
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let s = self else { return }
            let (fps, dropped, latencyMs, cpu) = s.stats.tick(intervalSec: 1.0)
            print(String(format: "[DASH] fps=%.1f dropped=%d latency=%.1fms cpu=%.1f%% gpu=n/a",
                         fps, dropped, latencyMs, cpu))
        }
        timer.resume()
        dashboardTimer = timer
    }

    private func monotonicUs() -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return UInt64(mach_absolute_time()) * UInt64(info.numer) / UInt64(info.denom) / 1000
    }

    private func openOutputFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream.h265")
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        outputFile = try? FileHandle(forWritingTo: url)
        print("OUTPUT: \(url.path)")
    }

    func stop() {
        dashboardTimer?.cancel()
        session.stopRunning()
        VTCompressionSessionCompleteFrames(encoder!, untilPresentationTimeStamp: .invalid)
        try? outputFile?.close()
    }
}

/// Rolling 1-second stats. CPU measured via getrusage deltas (real, process-wide).
private final class Stats {
    private var frames: UInt64 = 0
    private var latencySumUs: UInt64 = 0
    private var latencyCount: UInt64 = 0
    private var ruPrev: (user: Double, sys: Double) = (0, 0)

    func recordFrame() { frames &+= 1 }
    func recordLatencyUs(_ us: UInt64) { latencySumUs &+= us; latencyCount &+= 1 }

    func tick(intervalSec: Double) -> (fps: Double, dropped: Int, latencyMs: Double, cpu: Double) {
        let fps = Double(frames) / intervalSec
        let dropped = max(0, Int(60 * intervalSec) - Int(frames))
        let latencyMs = latencyCount > 0 ? Double(latencySumUs) / Double(latencyCount) / 1000.0 : 0
        let cpu = cpuPercent(intervalSec: intervalSec)
        frames = 0
        latencySumUs = 0
        latencyCount = 0
        return (fps, dropped, latencyMs, cpu)
    }

    private func cpuPercent(intervalSec: Double) -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let user = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
        let sys = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        let total = user + sys
        let delta = total - (ruPrev.user + ruPrev.sys)
        ruPrev = (user, sys)
        return min(100.0, max(0.0, delta / intervalSec * 100.0))
    }
}
