import AVFoundation
import UIKit
import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

/// Steps 1-4 only: 4K60 capture -> hardware HEVC (Annex-B) -> file.
/// No UI, no network, no segmentation. Run on device with Developer Mode on.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    var captureSession: AVCaptureSession { session }
    var onStatus: ((String) -> Void)?
    private var encoder: VTCompressionSession?
    private var encoderSetupFailed = false
    private var reportedNon4KFrame = false
    private let encoderStateLock = NSLock()
    private var forceNextKeyFrame = false
    private var isConfigured = false
    private var stopped = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var outputFile: FileHandle?
    // Raw 4K60 HEVC recording consumes roughly 600 MB/min at the stream bitrate.
    // Leave it off for live streaming; enable only while diagnosing encoding.
    private let saveEncodedStream = false
    private let sender = StreamSender()
    private var frameNumber: UInt32 = 0
    private var encodedFrameNumber: UInt32 = 0
    private let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private var frameStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private let telemetryLock = NSLock()
    private var activeFormatTelemetry = "Waiting for 4K60 format"
    private var sensorFirstPTS = CMTime.invalid
    private var encoderFirstPTS = CMTime.invalid
    private var sensorFrameCount: UInt64 = 0
    private var encoderFrameCount: UInt64 = 0
    private var sensorFPS = 0.0
    private var encoderFPS = 0.0
    private var usbFPS = 0.0
    private var captureDropCount: UInt64 = 0
    private var transportDropCount: UInt64 = 0
    var onDiagnostics: ((String) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                self?.resumeAfterForeground()
            },
            center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                               object: session,
                               queue: .main) { [weak self] _ in
                self?.invalidateEncoder(reason: "Camera interrupted")
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                               object: session,
                               queue: .main) { [weak self] _ in
                self?.resumeAfterForeground()
            },
            center.addObserver(forName: .AVCaptureSessionRuntimeError,
                               object: session,
                               queue: .main) { [weak self] notification in
                self?.handleSessionRuntimeError(notification)
            }
        ]
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Step 1: permission + session start
    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            report("Camera permission denied")
            return
        }

        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        guard !cameras.devices.isEmpty else {
            report("No back camera found")
            return
        }

        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            configureSession()
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    self?.report("Camera permission denied")
                    return
                }
                self?.configureSession()
            }
        }
    }

    // MARK: - Step 2/3: enumerate + configure 3840x2160@60 HEVC
    private func configureSession() {
        session.beginConfiguration()
        // An explicit device format owns resolution/framerate. A regular
        // session preset is allowed to replace that format with its default.
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            report("No back camera found")
            session.commitConfiguration()
            return
        }

        // Step 2: print supported 4K60 formats
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let maxFps = format.videoSupportedFrameRateRanges
                .map { $0.maxFrameRate }.max() ?? 0
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            print("FORMAT: \(dims.width)x\(dims.height) maxFps=\(maxFps) subtype=\(subtype)")
        }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // Keep live latency bounded, and account for every dropped source frame.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "capture"))
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)

        // Adding an AVCaptureDeviceInput resets its active format and its
        // min/max frame durations. Configure the final, attached input within
        // the same begin/commit transaction so 4K60 survives session startup.
        do {
            try device.lockForConfiguration()
            guard let fmt = device.formats.first(where: { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width == 3840 && d.height == 2160 &&
                    format.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= 60 && $0.maxFrameRate >= 60
                    })
            }) else {
                print("ERROR: this camera does not support 3840x2160 at 60 fps")
                report("This iPhone does not support 4K at 60 fps")
                device.unlockForConfiguration()
                session.commitConfiguration()
                return
            }
            device.activeFormat = fmt
            let duration = CMTime(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            report("Camera configuration failed: \(error.localizedDescription)")
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()

        if saveEncodedStream { openOutputFile() }
        isConfigured = true
        stopped = false
        invalidateEncoder(reason: nil)
        reportedNon4KFrame = false
        session.startRunning()
        refreshActiveFormatTelemetry(device)
        sender.onStatus = { [weak self] message in
            self?.report(message)
        }
        sender.onClientConnected = { [weak self] in
            self?.requestKeyFrame()
        }
        sender.onFrameRate = { [weak self] sentFps, droppedFrames in
            self?.recordTransport(fps: sentFps, droppedFrames: droppedFrames)
        }
        sender.start()   // Step 5: begin listening for the Windows receiver
        frameStartUptime = ProcessInfo.processInfo.systemUptime
        publishDiagnostics()
        report("Camera active • waiting for PC")
    }

    // MARK: - Step 4: VideoToolbox hardware HEVC encoder
    private func createEncoder(width: Int, height: Int) {
        let imageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var sessionOut: VTCompressionSession?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { (refcon, _, status, _, sampleBuffer) in
                guard let sb = sampleBuffer, status == noErr else { return }
                let streamer = Unmanaged<CameraStreamer>.fromOpaque(refcon!).takeUnretainedValue()
                streamer.recordEncodedFrame(CMSampleBufferGetPresentationTimeStamp(sb))
                streamer.writeAnnexB(sampleBuffer: sb)
            },
            refcon: refcon,
            compressionSessionOut: &sessionOut)

        guard status == noErr, let enc = sessionOut else {
            report("HEVC encoder failed: \(status)")
            return
        }
        let propertyStatuses: [(String, OSStatus)] = [
            ("real-time", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)),
            ("frame reordering", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)),
            ("HEVC profile", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)),
            ("bitrate", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 80_000_000))),
            ("frame rate", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))),
            ("keyframe interval", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))),
        ]
        if let failed = propertyStatuses.first(where: { $0.1 != noErr }) {
            VTCompressionSessionInvalidate(enc)
            encoderSetupFailed = true
            report("HEVC encoder setting failed (\(failed.0)): \(failed.1)")
            return
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(enc)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(enc)
            encoderSetupFailed = true
            report("HEVC encoder prepare failed: \(prepareStatus)")
            return
        }
        encoderStateLock.lock()
        encoder = enc
        encoderSetupFailed = false
        encoderStateLock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(px)
        let height = CVPixelBufferGetHeight(px)
        guard width == 3840, height == 2160 else {
            if !reportedNon4KFrame {
                reportedNon4KFrame = true
                report("Camera delivered \(width)x\(height), not 4K")
            }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        recordSensorFrame(pts)
        if activeEncoder() == nil && !encoderSetupFailed {
            createEncoder(width: width, height: height)
        }
        guard let enc = activeEncoder() else { return }
        let frameProperties: CFDictionary? = consumeForcedKeyFrame()
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(enc,
                                                     imageBuffer: px,
                                                     presentationTimeStamp: pts,
                                                     duration: .invalid,
                                                     frameProperties: frameProperties,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: &flags)
        if status != noErr {
            if status == kVTInvalidSessionErr {
                invalidateEncoder(reason: "Encoder reset after interruption")
                return
            }
            report("Frame encoder error: \(status)")
            return
        }
        frameNumber &+= 1
        let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - frameStartUptime)
        if frameNumber % 600 == 0 {
            print(String(format: "FPS: ~%.1f", Double(frameNumber) / elapsed))
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        telemetryLock.lock()
        captureDropCount &+= 1
        let shouldPublish = captureDropCount == 1 || captureDropCount % 30 == 0
        telemetryLock.unlock()
        if shouldPublish { publishDiagnostics() }
    }

    // MARK: - Annex-B conversion (length-prefixed -> start codes)
    func writeAnnexB(sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var annexB = Data()

        // A new Windows receiver can attach at any time. Include VPS/SPS/PPS
        // with every IDR so it can decode without waiting for an app restart.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                    createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if isKeyframe {
            var parameterSetCount = 0
            var nalUnitHeaderLength: Int32 = 0
            var parameterSetPointer: UnsafePointer<UInt8>?
            var parameterSetSize = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                desc,
                parameterSetIndex: 0,
                parameterSetPointerOut: &parameterSetPointer,
                parameterSetSizeOut: &parameterSetSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength)
            guard status == noErr else {
                report("HEVC parameter-set read failed: \(status)")
                return
            }
            for index in 0..<parameterSetCount {
                if index > 0 {
                    let nextStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        desc,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &parameterSetPointer,
                        parameterSetSizeOut: &parameterSetSize,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil)
                    guard nextStatus == noErr else {
                        report("HEVC parameter-set read failed: \(nextStatus)")
                        return
                    }
                }
                if let parameterSetPointer, parameterSetSize > 0 {
                    annexB.append(contentsOf: startCode)
                    annexB.append(Data(bytes: parameterSetPointer, count: parameterSetSize))
                }
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length: Int = 0
        var total: Int = 0
        var ptr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer,
                                                atOffset: 0,
                                                lengthAtOffsetOut: &length,
                                                totalLengthOut: &total,
                                                dataPointerOut: &ptr)
        guard status == kCMBlockBufferNoErr,
              let base = ptr,
              total > 0 else { return }

        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)

        // NAL units are 4-byte length prefixed.
        var offset = 0
        while offset + 4 <= total {
            let nalLen = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16
                       | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
            offset += 4
            guard nalLen > 0, offset + nalLen <= total else { break }
            annexB.append(contentsOf: startCode)
            annexB.append(Data(bytes: bytes.advanced(by: offset), count: nalLen))
            offset += nalLen
        }

        if saveEncodedStream { outputFile?.write(annexB) }
        sender.send(frameNumber: nextEncodedFrameNumber(),
                    timestampUs: presentationTimestampUs(sampleBuffer),
                    codec: StreamCodec.hevc.rawValue,
                    isKeyframe: isKeyframe,
                    frame: annexB)
    }

    private func monotonicUs() -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return UInt64(mach_absolute_time()) * UInt64(info.numer) / UInt64(info.denom) / 1000
    }

    private func presentationTimestampUs(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard seconds.isFinite, seconds >= 0 else { return monotonicUs() }
        return UInt64(seconds * 1_000_000.0)
    }

    private func refreshActiveFormatTelemetry(_ device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let minimumFps = 1.0 / CMTimeGetSeconds(device.activeVideoMaxFrameDuration)
        let maximumFps = 1.0 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        let verified = dimensions.width == 3840 && dimensions.height == 2160 &&
            abs(minimumFps - 60.0) < 0.1 && abs(maximumFps - 60.0) < 0.1
        let state = verified ? "VERIFIED 4K60" : "MISMATCH"
        resetTelemetry(format: String(format: "%@ %dx%d • device %.1f-%.1f fps • request 60.0",
                                       state, dimensions.width, dimensions.height,
                                       minimumFps, maximumFps))
    }

    private func resetTelemetry(format: String) {
        telemetryLock.lock()
        activeFormatTelemetry = format
        sensorFirstPTS = .invalid
        encoderFirstPTS = .invalid
        sensorFrameCount = 0
        encoderFrameCount = 0
        encodedFrameNumber = 0
        sensorFPS = 0
        encoderFPS = 0
        usbFPS = 0
        captureDropCount = 0
        transportDropCount = 0
        telemetryLock.unlock()
    }

    private func recordSensorFrame(_ pts: CMTime) {
        telemetryLock.lock()
        if !sensorFirstPTS.isValid { sensorFirstPTS = pts }
        sensorFrameCount &+= 1
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, sensorFirstPTS))
        if elapsed > 0 { sensorFPS = Double(sensorFrameCount - 1) / elapsed }
        let shouldPublish = sensorFrameCount % 30 == 0
        telemetryLock.unlock()
        if shouldPublish { publishDiagnostics() }
    }

    private func recordEncodedFrame(_ pts: CMTime) {
        telemetryLock.lock()
        if !encoderFirstPTS.isValid { encoderFirstPTS = pts }
        encoderFrameCount &+= 1
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, encoderFirstPTS))
        if elapsed > 0 { encoderFPS = Double(encoderFrameCount - 1) / elapsed }
        let shouldPublish = encoderFrameCount % 30 == 0
        telemetryLock.unlock()
        if shouldPublish { publishDiagnostics() }
    }

    private func recordTransport(fps: Double, droppedFrames: UInt64) {
        telemetryLock.lock()
        usbFPS = fps
        transportDropCount = droppedFrames
        telemetryLock.unlock()
        publishDiagnostics()
    }

    private func nextEncodedFrameNumber() -> UInt32 {
        telemetryLock.lock()
        encodedFrameNumber &+= 1
        let number = encodedFrameNumber
        telemetryLock.unlock()
        return number
    }

    private func publishDiagnostics() {
        telemetryLock.lock()
        let text = String(format: "%@\nSENSOR %.1f • HEVC %.1f • USB %.1f fps\nDROPS capture %llu • transport %llu",
                          activeFormatTelemetry, sensorFPS, encoderFPS, usbFPS,
                          captureDropCount, transportDropCount)
        telemetryLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onDiagnostics?(text) }
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
        stopped = true
        session.stopRunning()
        invalidateEncoder(reason: nil)
        sender.stop()
        try? outputFile?.close()
    }

    private func report(_ message: String) {
        print("STATUS: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }

    private func requestKeyFrame() {
        encoderStateLock.lock()
        forceNextKeyFrame = true
        encoderStateLock.unlock()
    }

    private func consumeForcedKeyFrame() -> Bool {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        let shouldForce = forceNextKeyFrame
        forceNextKeyFrame = false
        return shouldForce
    }

    private func activeEncoder() -> VTCompressionSession? {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        return encoder
    }

    private func invalidateEncoder(reason: String?) {
        encoderStateLock.lock()
        let oldEncoder = encoder
        encoder = nil
        encoderSetupFailed = false
        forceNextKeyFrame = true
        encoderStateLock.unlock()
        if let oldEncoder {
            VTCompressionSessionInvalidate(oldEncoder)
        }
        if let reason { report(reason) }
    }

    private func resumeAfterForeground() {
        guard isConfigured, !stopped else { return }
        invalidateEncoder(reason: nil)
        if !session.isRunning { session.startRunning() }
        sender.start()
        report("Camera resumed • waiting for encoder")
    }

    private func handleSessionRuntimeError(_ notification: Notification) {
        guard isConfigured, !stopped else { return }
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        invalidateEncoder(reason: "Camera runtime reset")
        // A media-services reset invalidates the capture pipeline without a
        // foreground notification. Restarting the configured session here
        // makes camera focus switches and interruption recovery self-healing.
        if error?.code == .mediaServicesWereReset || !session.isRunning {
            session.startRunning()
        }
        sender.start()
        requestKeyFrame()
    }
}
