import AVFoundation
import UIKit
import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

enum OutputOrientation: String {
    case landscape
    case portrait

    static let preferenceKey = "camera.outputOrientation"

    static var stored: OutputOrientation {
        guard let value = UserDefaults.standard.string(forKey: preferenceKey),
              let orientation = OutputOrientation(rawValue: value) else {
            return .landscape
        }
        return orientation
    }

    var title: String { rawValue.capitalized }
    var rotationAngle: CGFloat { self == .portrait ? 90 : 0 }
}

/// Steps 1-4 only: 4K60 capture -> hardware HEVC (Annex-B) -> file.
/// No UI, no network, no segmentation. Run on device with Developer Mode on.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    var captureSession: AVCaptureSession { session }
    var onStatus: ((String) -> Void)?
    private var encoder: VTCompressionSession?
    private var encoderSetupFailed = false
    private var reportedNon4KFrame = false
    private let encoderStateLock = NSLock()
    private var forceNextKeyFrame = false
    private var isConfigured = false
    private var stopped = false
    // iOS forbids camera capture while the app is backgrounded. Recovery is
    // resumed only after the app returns to the active foreground state.
    // Accessed only on sessionQueue.
    private var appIsActive = true
    // Accessed only on sessionQueue. Camera/VideoToolbox recovery is
    // deliberately serialized so a foreground notification, an interruption,
    // and an encode failure cannot rebuild the session concurrently.
    private var recoveryScheduled = false
    private var recoveryAttempt = 0
    private var videoDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var activeOutputOrientation: OutputOrientation = .landscape
    private var notificationTokens: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?
    private var outputFile: FileHandle?
    // Raw 4K60 HEVC recording consumes roughly 600 MB/min at the stream bitrate.
    // Leave it off for live streaming; enable only while diagnosing encoding.
    private let saveEncodedStream = false
    private let sender = StreamSender()
    private var frameNumber: UInt32 = 0
    private var encodedFrameNumber: UInt32 = 0
    private let protocolTimestampLock = NSLock()
    private var lastProtocolTimestampUs: UInt64 = 0
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var encoderGeneration: UInt64 = 1
    // Protected by encoderStateLock. Prevents a 60fps stream from dispatching
    // one recovery-backoff reset for every successful output callback.
    private var recoveryBackoffResetGeneration: UInt64 = 0
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
    private var encoderDropCount: UInt64 = 0
    private var malformedAccessUnitDropCount: UInt64 = 0
    private var transportDropCount: UInt64 = 0
    // T2.2: encode latency = now - capture PTS (host clock); queue latency comes from StreamSender.
    private var windowMaxEncodeLatencyMs = 0.0
    private var shownEncodeLatencyMs = 0.0
    private var shownQueueLatencyMs = 0.0
    private var linkDropCount: UInt64 = 0
    private var lastLinkDropReason = "none"
    private static let linkTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private var thermalTelemetry = "THERMAL nominal"
    private var pressureTelemetry = "PRESSURE nominal"
    private var didReceiveFirstCameraFrame = false
    private let healthLock = NSLock()
    private var healthRevision: UInt64 = 0
    private var healthUpdatesEnabled = false
    private var cameraHealth = "CAMERA starting"
    private var usbHealth = "USB waiting for Windows receiver"
    private var wifiHealth = "WI-FI off (USB only)"
    private var healthEvent = "Preparing camera"
    private var lastCaptureUptime: TimeInterval = 0
    private var lastSuccessfulSendUptime: TimeInterval = 0
    private var receiverState: StreamSenderConnectionState = .waiting
    private var captureStalledReported = false
    private var receiverStalledReported = false
    private var livenessStartedUptime: TimeInterval = 0
    private var livenessWatchdog: DispatchSourceTimer?
    private var diagnosticsRevision: UInt64 = 0
    var onDiagnostics: ((String) -> Void)?
    var onStreamHealth: ((String) -> Void)?
    var onOutputOrientation: ((OutputOrientation) -> Void)?

    override init() {
        super.init()
        _ = ProcessInfo.processInfo.thermalState
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                self?.resumeAfterForeground()
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                self?.pauseRecoveryForBackground()
            },
            center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                               object: session,
                               queue: .main) { [weak self] _ in
                self?.handleSessionInterruption()
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
            },
            center.addObserver(forName: .AVCaptureSessionDidStopRunning,
                               object: session,
                               queue: .main) { [weak self] _ in
                self?.handleSessionStopped()
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                               object: ProcessInfo.processInfo,
                               queue: .main) { [weak self] _ in
                self?.handleThermalStateChange()
            }
        ]
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Step 1: permission + session start
    func start() {
        beginStreamHealth()
        updateStreamHealth(camera: "CAMERA starting • requesting access",
                           event: "Preparing 4K60 camera")
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            updateStreamHealth(camera: "CAMERA error • permission denied",
                               event: "Camera permission denied")
            report("Camera permission denied")
            return
        }

        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            sessionQueue.async { [weak self] in self?.configureSession() }
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    self?.updateStreamHealth(camera: "CAMERA error • permission denied",
                                             event: "Camera permission denied")
                    self?.report("Camera permission denied")
                    return
                }
                self?.sessionQueue.async { self?.configureSession() }
            }
        }
    }

    // MARK: - Step 2/3: enumerate + configure 3840x2160@60 HEVC
    private func configureSession() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !isConfigured else { return }
        session.beginConfiguration()
        // An explicit device format owns resolution/framerate. A regular
        // session preset is allowed to replace that format with its default.
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            updateStreamHealth(camera: "CAMERA error • back camera unavailable",
                               event: "No back camera found")
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
            updateStreamHealth(camera: "CAMERA error • input unavailable",
                               event: "Camera input unavailable")
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoDevice = device
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] _, _ in
            self?.handleSystemPressureChange()
        }
        handleThermalStateChange()
        handleSystemPressureChange()

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // Keep live latency bounded, and account for every dropped source frame.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "capture"))
        guard session.canAddOutput(output) else {
            updateStreamHealth(camera: "CAMERA error • output unavailable",
                               event: "Camera output unavailable")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        videoOutput = output
        guard let initialOrientation = applyInitialOutputOrientation(to: output) else {
            updateStreamHealth(camera: "CAMERA error • orientation unavailable",
                               event: "Camera output orientation unavailable")
            session.commitConfiguration()
            return
        }
        activeOutputOrientation = initialOrientation
        UserDefaults.standard.set(initialOrientation.rawValue, forKey: OutputOrientation.preferenceKey)

        // Input attachment resets the format and duration. Apply them after
        // attachment, within this configuration transaction.
        guard apply4K60Format(to: device) else {
            updateStreamHealth(camera: "CAMERA error • 4K60 unavailable",
                               event: "4K60 camera configuration failed")
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
        setIdleTimerDisabled(true)
        refreshActiveFormatTelemetry(device)
        sender.onStatus = { [weak self] message in
            self?.report(message)
        }
        sender.onConnectionState = { [weak self] state in
            self?.sessionQueue.async { [weak self] in
                guard let self, self.isConfigured, !self.stopped else { return }
                self.updateUSBHealth(state)
            }
        }
        sender.onClientConnected = { [weak self] in
            self?.requestKeyFrame()
        }
        sender.onKeyFrameNeeded = { [weak self] in self?.requestKeyFrame() }
        sender.onDisconnect = { [weak self] reason in
            self?.recordLinkDrop(reason: reason)
        }
        sender.onQueueLatency = { [weak self] maxMs in
            self?.recordQueueLatency(maxMs)
        }
        sender.onFrameRate = { [weak self] sentFps, droppedFrames in
            self?.recordTransport(fps: sentFps, droppedFrames: droppedFrames)
        }
        sender.onFrameSent = { [weak self] sentAt in
            self?.sessionQueue.async { [weak self] in
                guard let self, self.isConfigured, !self.stopped else { return }
                self.recordSuccessfulSend(at: sentAt)
            }
        }
        sender.onWiFiAddress = { [weak self] address in
            self?.sessionQueue.async { [weak self] in
                guard let self, self.isConfigured, !self.stopped else { return }
                self.updateStreamHealth(wifi: Self.wifiHealthText(address, enabled: Self.isWiFiEnabledStored))
            }
        }
        // The allowed interfaces are fixed when the listener is created, so the
        // stored choice must reach the sender before it starts listening.
        sender.setWiFiEnabled(Self.isWiFiEnabledStored)
        sender.start()   // Step 5: begin listening for the Windows receiver
        startLivenessWatchdog()
        frameStartUptime = ProcessInfo.processInfo.systemUptime
        publishDiagnostics()
        publishOutputOrientation(initialOrientation)
        updateStreamHealth(camera: "CAMERA running • waiting for first 4K frame",
                           usb: "USB waiting for Windows receiver",
                           event: "Camera started • screen kept awake")
        report("Camera active • screen kept awake • waiting for PC")
    }

    /// Read-only device probe for the owner's capability report. It runs only
    /// when the user taps the button, never per frame, and does not touch the
    /// capture session or the stream. Call it from the main queue; the text is
    /// delivered on the main queue.
    // T5.2
    func capabilityReport(completion: @escaping (String) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        // UIDevice is main-actor state, so read it before hopping queues.
        let osVersion = UIDevice.current.systemVersion
        sessionQueue.async {
            let text = Self.buildCapabilityReport(osVersion: osVersion)
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func buildCapabilityReport(osVersion: String) -> String {
        var lines = [
            "device \(machineIdentifier())",
            "iOS \(osVersion)",
            "thermal \(thermalStateName(ProcessInfo.processInfo.thermalState))",
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera,
                          .builtInTripleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .unspecified)
        let wanted: [(width: Int32, height: Int32)] = [(1280, 720), (1920, 1080), (1920, 1440), (3840, 2160)]
        for device in discovery.devices {
            let side = device.position == .front ? "front" : "back"
            let type = device.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: "")
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard wanted.contains(where: { $0.width == dims.width && $0.height == dims.height }) else { continue }
                let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                        subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else { continue }
                let maxFps = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
                let portraitFps = format.videoFrameRateRangeForPortraitEffect?.maxFrameRate ?? 0
                var background = "n/a"
                if #available(iOS 18, *) {
                    background = yesNo(format.isBackgroundReplacementSupported)
                }
                var cinematic = "n/a"
                if #available(iOS 26, *) {
                    cinematic = yesNo(format.isCinematicVideoCaptureSupported)
                }
                lines.append("\(side) \(type) \(dims.width)x\(dims.height) \(fourCC(subtype)) " +
                             "maxFps=\(Int(maxFps.rounded())) 60fps=\(yesNo(maxFps >= 60)) " +
                             "portrait=\(yesNo(format.isPortraitEffectSupported))@\(Int(portraitFps.rounded())) " +
                             "studio=\(yesNo(format.isStudioLightSupported)) " +
                             "centerStage=\(yesNo(format.isCenterStageSupported)) " +
                             "bg=\(background) cinematic=\(cinematic)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func yesNo(_ value: Bool) -> String { value ? "y" : "n" }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    // T3.1: Wi-Fi streaming is opt-in and off by default (G7 option A).
    static let wifiPreferenceKey = "stream.wifiEnabled"

    static var isWiFiEnabledStored: Bool {
        UserDefaults.standard.bool(forKey: wifiPreferenceKey)
    }

    /// Persists the Wi-Fi choice and applies it. The sender rebinds its listener,
    /// which closes the current PC connection; the receiver reconnects.
    func setWiFiEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.wifiPreferenceKey)
        sender.setWiFiEnabled(enabled)
    }

    private static func wifiHealthText(_ address: String?, enabled: Bool) -> String {
        if let address {
            return "WI-FI \(address):\(StreamSender.port) • visible to this network"
        }
        return enabled ? "WI-FI on • waiting for a Wi-Fi address" : "WI-FI off (USB only)"
    }

    /// Persists a user-selected frame orientation. The setting affects only the
    /// camera output connection; USB framing and the receiver protocol stay
    /// unchanged. The receiver reconnect makes OBS see a clean HEVC sequence
    /// after the encoder begins producing frames in the new dimensions.
    func setOutputOrientation(_ orientation: OutputOrientation) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured, !self.stopped, let output = self.videoOutput else {
                self.publishOutputOrientation(self.activeOutputOrientation)
                return
            }
            self.session.beginConfiguration()
            let applied = self.applyOutputOrientation(orientation, to: output)
            self.session.commitConfiguration()
            guard applied else {
                self.publishOutputOrientation(self.activeOutputOrientation)
                return
            }
            self.activeOutputOrientation = orientation
            UserDefaults.standard.set(orientation.rawValue, forKey: OutputOrientation.preferenceKey)
            self.invalidateEncoder(reason: nil)
            self.sender.restartListening(reason: "Output changed to \(orientation.title)")
            self.requestKeyFrame()
            self.publishOutputOrientation(orientation)
            self.report("Output \(orientation.title) selected • reconnecting PC")
        }
    }

    // MARK: - Step 4: VideoToolbox hardware HEVC encoder
    private func createEncoder(width: Int, height: Int) {
        let generation = reserveEncoderGeneration()
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
            outputCallback: { (refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer) in
                guard let refcon else { return }
                let streamer = Unmanaged<CameraStreamer>.fromOpaque(refcon).takeUnretainedValue()
                let generation = UInt64(UInt(bitPattern: sourceFrameRefcon))
                guard streamer.isCurrentEncoderGeneration(generation) else { return }
                if status == noErr,
                   sampleBuffer == nil,
                   infoFlags.contains(.frameDropped) {
                    streamer.recordEncoderDrop()
                    return
                }
                guard status == noErr, let sb = sampleBuffer else {
                    streamer.handleEncoderOutputFailure(status: status,
                                                        sampleBufferMissing: sampleBuffer == nil,
                                                        generation: generation)
                    return
                }
                streamer.markEncoderOutputSuccessful(generation: generation)
                streamer.recordEncodedFrame(CMSampleBufferGetPresentationTimeStamp(sb))
                streamer.writeAnnexB(sampleBuffer: sb, generation: generation)
            },
            refcon: refcon,
            compressionSessionOut: &sessionOut)

        guard status == noErr, let enc = sessionOut else {
            setEncoderSetupFailed(true)
            report("HEVC encoder failed: \(status)")
            scheduleRecovery(reason: "HEVC encoder setup recovery")
            return
        }
        let rateLimit: CFArray = [NSNumber(value: 10_000_000), NSNumber(value: 1)] as CFArray
        let propertyStatuses: [(String, OSStatus)] = [
            ("real-time", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)),
            ("frame reordering", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)),
            ("HEVC profile", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)),
            ("bitrate", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 40_000_000))),
            ("rate limit", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_DataRateLimits, value: rateLimit)),
            ("frame rate", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))),
            ("keyframe interval", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 120))),
        ]
        if let failed = propertyStatuses.first(where: { $0.1 != noErr }) {
            VTCompressionSessionInvalidate(enc)
            setEncoderSetupFailed(true)
            report("HEVC encoder setting failed (\(failed.0)): \(failed.1)")
            scheduleRecovery(reason: "HEVC encoder setup recovery")
            return
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(enc)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(enc)
            setEncoderSetupFailed(true)
            report("HEVC encoder prepare failed: \(prepareStatus)")
            scheduleRecovery(reason: "HEVC encoder setup recovery")
            return
        }
        guard installEncoder(enc, width: width, height: height, generation: generation) else {
            VTCompressionSessionInvalidate(enc)
            return
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(px)
        let height = CVPixelBufferGetHeight(px)
        guard is4KFrame(width: width, height: height) else {
            if !reportedNon4KFrame {
                reportedNon4KFrame = true
                report("Camera delivered \(width)x\(height), not 4K")
            }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        recordSensorFrame(pts)
        if encoderNeedsRebuild(width: width, height: height) {
            invalidateEncoder(reason: nil)
        }
        if activeEncoder() == nil && !isEncoderSetupFailed() {
            createEncoder(width: width, height: height)
        }
        guard let activeEncoder = activeEncoder() else { return }
        let frameProperties: CFDictionary? = consumeForcedKeyFrame()
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(activeEncoder.session,
                                                     imageBuffer: px,
                                                     presentationTimeStamp: pts,
                                                     duration: .invalid,
                                                     frameProperties: frameProperties,
                                                     sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(activeEncoder.generation)),
                                                     infoFlagsOut: &flags)
        if status != noErr {
            invalidateEncoder(reason: status == kVTInvalidSessionErr
                              ? "Encoder reset after interruption"
                              : "Frame encoder error: \(status)")
            // Any VideoToolbox failure can leave the session alive while its
            // hardware encoder is no longer usable. Rebuild it asynchronously
            // with bounded backoff instead of requiring an app restart.
            scheduleRecovery(reason: "Encoder recovery")
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
    func writeAnnexB(sampleBuffer: CMSampleBuffer, generation: UInt64) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // VideoToolbox attachment metadata can be stale after recovery. It is
        // diagnostic only; parsed HEVC NAL types decide decoder admission.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                    createIfNecessary: false) as? [[CFString: Any]]
        let metadataMarksKeyframe =
            (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool).map { !$0 }
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize = 0
        let parameterStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            desc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength)
        guard parameterStatus == noErr, (1...4).contains(Int(nalUnitHeaderLength)) else {
            report("HEVC parameter-set read failed: \(parameterStatus)")
            return
        }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            recordMalformedAccessUnitDrop(reason: "encoded sample has no data buffer")
            return
        }

        let lengthFieldBytes = Int(nalUnitHeaderLength)
        let encodedAccessUnit: Data
        do {
            encodedAccessUnit = try LengthPrefixedHEVC.convert(
                dataBuffer,
                lengthFieldBytes: lengthFieldBytes)
        } catch let error as LengthPrefixedHEVCConversionError {
            recordMalformedAccessUnitDrop(reason: error.description)
            return
        } catch {
            recordMalformedAccessUnitDrop(reason: String(describing: error))
            return
        }

        let containsRandomAccessPicture = LengthPrefixedHEVC.containsIDR(encodedAccessUnit)
        if let metadataMarksKeyframe,
           metadataMarksKeyframe != containsRandomAccessPicture {
            report(containsRandomAccessPicture
                   ? "HEVC IDR marked NotSync; using parsed IDR"
                   : "Metadata keyframe lacks HEVC IDR; treating as delta")
        }

        var annexB = encodedAccessUnit
        // A new Windows receiver can attach at any time. Include VPS/SPS/PPS
        // with every parsed IDR even if its attachment incorrectly says NotSync.
        if containsRandomAccessPicture {
            var parameterSets = Data()
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
                    parameterSets.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    parameterSets.append(Data(bytes: parameterSetPointer, count: parameterSetSize))
                }
            }
            parameterSets.append(encodedAccessUnit)
            annexB = parameterSets
        }

        // The callback can outlive a VideoToolbox session invalidation. Check
        // again after Annex-B conversion, immediately before a packet enters
        // the sender queue, so an old orientation cannot cross the reconnect.
        guard isCurrentEncoderGeneration(generation) else { return }
        if saveEncodedStream { outputFile?.write(annexB) }
        sender.send(frameNumber: nextEncodedFrameNumber(),
                    timestampUs: nextProtocolTimestampUs(),
                    codec: StreamCodec.hevc.rawValue,
                    isKeyframe: containsRandomAccessPicture,
                    frame: annexB)
    }

    // The timebase is fixed for the life of the process; query it once.
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    private func monotonicUs() -> UInt64 {
        let info = Self.machTimebase
        return UInt64(mach_absolute_time()) * UInt64(info.numer) / UInt64(info.denom) / 1000
    }

    private func nextProtocolTimestampUs() -> UInt64 {
        protocolTimestampLock.lock()
        defer { protocolTimestampLock.unlock() }
        lastProtocolTimestampUs = max(monotonicUs(), lastProtocolTimestampUs + 1)
        return lastProtocolTimestampUs
    }

    private func is4KFrame(width: Int, height: Int) -> Bool {
        (width == 3840 && height == 2160) || (width == 2160 && height == 3840)
    }

    private func encoderNeedsRebuild(width: Int, height: Int) -> Bool {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        return encoder != nil && (encoderWidth != width || encoderHeight != height)
    }

    private func applyOutputOrientation(_ orientation: OutputOrientation,
                                        to output: AVCaptureVideoDataOutput) -> Bool {
        guard let connection = output.connection(with: .video) else {
            report("Camera output connection unavailable")
            return false
        }
        guard connection.isVideoRotationAngleSupported(orientation.rotationAngle) else {
            report("\(orientation.title) output is not supported by this iPhone")
            return false
        }
        connection.videoRotationAngle = orientation.rotationAngle
        return true
    }

    private func applyInitialOutputOrientation(to output: AVCaptureVideoDataOutput) -> OutputOrientation? {
        let preferred = OutputOrientation.stored
        if applyOutputOrientation(preferred, to: output) { return preferred }
        guard preferred != .landscape,
              applyOutputOrientation(.landscape, to: output) else { return nil }
        report("Portrait output unavailable • falling back to Landscape")
        return .landscape
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

    private func apply4K60Format(to device: AVCaptureDevice) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let matching4K60Formats = device.formats.filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dimensions.width == 3840 && dimensions.height == 2160 &&
                    format.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= 60 && $0.maxFrameRate >= 60
                    })
            }
            guard let format = matching4K60Formats.first(where: {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) ==
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }) ?? matching4K60Formats.first else {
                report("This iPhone does not support 4K at 60 fps")
                return false
            }

            // Disable automatic HDR before choosing the capture format, then
            // explicitly keep HDR off on that chosen format. Prefer the native
            // 8-bit 420v variant to avoid an HDR/10-bit conversion at 4K60.
            device.automaticallyAdjustsVideoHDREnabled = false
            device.activeFormat = format
            device.isVideoHDREnabled = false
            let duration = CMTime(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            return true
        } catch {
            report("Camera configuration failed: \(error.localizedDescription)")
            return false
        }
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
        windowMaxEncodeLatencyMs = 0
        shownEncodeLatencyMs = 0
        shownQueueLatencyMs = 0
        didReceiveFirstCameraFrame = false
        telemetryLock.unlock()
    }

    private func recordSensorFrame(_ pts: CMTime) {
        telemetryLock.lock()
        if !sensorFirstPTS.isValid { sensorFirstPTS = pts }
        let isFirstCameraFrame = !didReceiveFirstCameraFrame
        didReceiveFirstCameraFrame = true
        sensorFrameCount &+= 1
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, sensorFirstPTS))
        if elapsed > 0 { sensorFPS = Double(sensorFrameCount - 1) / elapsed }
        let shouldPublish = sensorFrameCount % 30 == 0
        telemetryLock.unlock()
        recordCaptureLiveness(at: ProcessInfo.processInfo.systemUptime)
        if isFirstCameraFrame {
            updateStreamHealth(camera: "CAMERA active • first 4K frame received",
                               event: "Camera capture is live")
        }
        if shouldPublish { publishDiagnostics() }
    }

    private func recordEncodedFrame(_ pts: CMTime) {
        // Capture PTS and the session clock are on the same host timebase.
        let now = CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())
        let latencyMs = CMTimeGetSeconds(CMTimeSubtract(now, pts)) * 1000.0
        telemetryLock.lock()
        if latencyMs.isFinite { windowMaxEncodeLatencyMs = max(windowMaxEncodeLatencyMs, max(0, latencyMs)) }
        if !encoderFirstPTS.isValid { encoderFirstPTS = pts }
        encoderFrameCount &+= 1
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, encoderFirstPTS))
        if elapsed > 0 { encoderFPS = Double(encoderFrameCount - 1) / elapsed }
        let shouldPublish = encoderFrameCount % 30 == 0
        if shouldPublish {
            shownEncodeLatencyMs = windowMaxEncodeLatencyMs
            windowMaxEncodeLatencyMs = 0
        }
        telemetryLock.unlock()
        if shouldPublish { publishDiagnostics() }
    }

    private func recordEncoderDrop() {
        telemetryLock.lock()
        encoderDropCount &+= 1
        let shouldPublish = encoderDropCount == 1 || encoderDropCount % 30 == 0
        telemetryLock.unlock()
        if shouldPublish { publishDiagnostics() }
    }

    private func recordMalformedAccessUnitDrop(reason: String) {
        telemetryLock.lock()
        malformedAccessUnitDropCount &+= 1
        let count = malformedAccessUnitDropCount
        let shouldPublish = count == 1 || count % 30 == 0
        telemetryLock.unlock()
        guard shouldPublish else { return }
        publishDiagnostics()
        report("Dropped malformed HEVC access unit #\(count): \(reason)")
    }

    private func recordTransport(fps: Double, droppedFrames: UInt64) {
        telemetryLock.lock()
        usbFPS = fps
        transportDropCount = droppedFrames
        telemetryLock.unlock()
        publishDiagnostics()
    }

    private func recordQueueLatency(_ maxMs: Double) {
        telemetryLock.lock()
        shownQueueLatencyMs = maxMs
        telemetryLock.unlock()
        publishDiagnostics()
    }

    private func recordLinkDrop(reason: String) {
        let time = Self.linkTimeFormatter.string(from: Date())
        telemetryLock.lock()
        linkDropCount &+= 1
        lastLinkDropReason = "\(reason) \(time)"
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
        diagnosticsRevision &+= 1
        let revision = diagnosticsRevision
        let text = String(format: "%@ • %@ • %@\nSENSOR %.1f • HEVC %.1f • USB %.1f fps\nDROPS capture %llu • HEVC %llu • malformed %llu • transport %llu\nLATENCY encode %.0f ms • queue %.0f ms (max per 1 s)\nLINK reconnects %llu • last: %@",
                          activeFormatTelemetry, thermalTelemetry, pressureTelemetry,
                          sensorFPS, encoderFPS, usbFPS,
                          captureDropCount, encoderDropCount,
                          malformedAccessUnitDropCount, transportDropCount,
                          shownEncodeLatencyMs, shownQueueLatencyMs,
                          linkDropCount, lastLinkDropReason)
        telemetryLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentDiagnosticsRevision(revision) else { return }
            self.onDiagnostics?(text)
        }
    }

    // The capture callback, VideoToolbox callback, Network.framework queue,
    // and AVCapture notifications all arrive independently. Keep one bounded
    // health snapshot and reject any queued UIKit update from an old session.
    private func beginStreamHealth() {
        healthLock.lock()
        healthRevision &+= 1
        healthUpdatesEnabled = true
        cameraHealth = "CAMERA starting"
        usbHealth = "USB waiting for Windows receiver"
        wifiHealth = Self.wifiHealthText(nil, enabled: Self.isWiFiEnabledStored)
        healthEvent = "Preparing camera"
        let revision = healthRevision
        let text = healthSnapshotLocked()
        healthLock.unlock()
        telemetryLock.lock()
        diagnosticsRevision &+= 1
        telemetryLock.unlock()
        deliverStreamHealth(text, revision: revision)
    }

    private func endStreamHealth() {
        healthLock.lock()
        healthUpdatesEnabled = false
        healthRevision &+= 1
        healthLock.unlock()
        telemetryLock.lock()
        diagnosticsRevision &+= 1
        telemetryLock.unlock()
    }

    private func updateUSBHealth(_ state: StreamSenderConnectionState) {
        healthLock.lock()
        receiverState = state
        if state != .sending {
            lastSuccessfulSendUptime = 0
            receiverStalledReported = false
        }
        healthLock.unlock()
        switch state {
        case .waiting:
            updateStreamHealth(usb: "USB waiting for Windows receiver")
        case .connected:
            updateStreamHealth(usb: "PC receiver connected • waiting for first video frame")
        case .sending:
            updateStreamHealth(usb: "USB connected • PC receiver receiving video")
        case .disconnected:
            updateStreamHealth(usb: "PC receiver disconnected • waiting for receiver")
        case .failed:
            updateStreamHealth(usb: "USB connection error • reconnecting")
        }
    }

    private func updateStreamHealth(camera: String? = nil,
                                    usb: String? = nil,
                                    wifi: String? = nil,
                                    event: String? = nil) {
        healthLock.lock()
        guard healthUpdatesEnabled else {
            healthLock.unlock()
            return
        }
        if let camera { cameraHealth = camera }
        if let usb { usbHealth = usb }
        if let wifi { wifiHealth = wifi }
        if let event { healthEvent = event }
        healthRevision &+= 1
        let revision = healthRevision
        let text = healthSnapshotLocked()
        healthLock.unlock()
        deliverStreamHealth(text, revision: revision)
    }

    private func healthSnapshotLocked() -> String {
        "\(cameraHealth)\n\(usbHealth)\n\(wifiHealth)\nSTATUS: \(healthEvent)"
    }

    private func deliverStreamHealth(_ text: String, revision: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentHealthRevision(revision) else { return }
            self.onStreamHealth?(text)
        }
    }

    private func isCurrentHealthRevision(_ revision: UInt64) -> Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        return healthUpdatesEnabled && healthRevision == revision
    }

    private func isCurrentDiagnosticsRevision(_ revision: UInt64) -> Bool {
        telemetryLock.lock()
        let isCurrent = diagnosticsRevision == revision
        telemetryLock.unlock()
        healthLock.lock()
        let isEnabled = healthUpdatesEnabled
        healthLock.unlock()
        return isCurrent && isEnabled
    }

    // Observability only: this timer never restarts capture, VideoToolbox, or
    // the sender. It gives the person holding the phone an honest stalled or
    // recovered state while existing recovery paths keep their ownership.
    private func startLivenessWatchdog() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard livenessWatchdog == nil else { return }
        healthLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        livenessStartedUptime = now
        lastCaptureUptime = 0
        lastSuccessfulSendUptime = 0
        receiverState = .waiting
        captureStalledReported = false
        receiverStalledReported = false
        healthLock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.evaluateLiveness() }
        livenessWatchdog = timer
        timer.resume()
    }

    private func stopLivenessWatchdog() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        livenessWatchdog?.setEventHandler {}
        livenessWatchdog?.cancel()
        livenessWatchdog = nil
    }

    private func recordCaptureLiveness(at uptime: TimeInterval) {
        healthLock.lock()
        lastCaptureUptime = uptime
        let resumed = captureStalledReported
        captureStalledReported = false
        healthLock.unlock()
        if resumed {
            updateStreamHealth(camera: "CAMERA active • 4K capture resumed",
                               event: "Camera frames resumed")
        }
    }

    private func recordSuccessfulSend(at uptime: TimeInterval) {
        healthLock.lock()
        lastSuccessfulSendUptime = uptime
        let resumed = receiverStalledReported
        receiverStalledReported = false
        healthLock.unlock()
        if resumed {
            updateStreamHealth(usb: "USB connected • PC receiver receiving video",
                               event: "Video packets resumed")
        }
    }

    private func evaluateLiveness() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard isConfigured, !stopped, appIsActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        healthLock.lock()
        let captureAge = lastCaptureUptime == 0 ? now - livenessStartedUptime : now - lastCaptureUptime
        let shouldReportCaptureStall = captureAge >= 3 && !captureStalledReported
        if shouldReportCaptureStall { captureStalledReported = true }

        let receiverActive = receiverState == .connected || receiverState == .sending
        let sendAge = lastSuccessfulSendUptime == 0 ? now - livenessStartedUptime : now - lastSuccessfulSendUptime
        let shouldReportReceiverStall = receiverActive && sendAge >= 3 && !receiverStalledReported
        if shouldReportReceiverStall { receiverStalledReported = true }
        healthLock.unlock()

        if shouldReportCaptureStall {
            updateStreamHealth(camera: "CAMERA stalled • no 4K frame for 3s",
                               event: "Camera feedback watchdog detected a stall")
        }
        if shouldReportReceiverStall {
            updateStreamHealth(usb: "USB stalled • PC receiver not receiving video",
                               event: "Receiver feedback watchdog detected no successful packet for 3s")
        }
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
        endStreamHealth()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.stopLivenessWatchdog()
            self.session.stopRunning()
            self.setIdleTimerDisabled(false)
            self.invalidateEncoder(reason: nil)
            self.sender.stop()
            try? self.outputFile?.close()
            self.outputFile = nil
        }
    }

    private func report(_ message: String) {
        print("STATUS: \(message)")
        updateStreamHealth(event: message)
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }

    private func publishOutputOrientation(_ orientation: OutputOrientation) {
        DispatchQueue.main.async { [weak self] in
            self?.onOutputOrientation?(orientation)
        }
    }

    /// iOS prohibits camera capture in the background. Keep the device awake
    /// for the live foreground stream; restore normal auto-lock when stopped.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = disabled
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

    private func activeEncoder() -> (session: VTCompressionSession, generation: UInt64)? {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        guard let encoder else { return nil }
        return (encoder, encoderGeneration)
    }

    private func reserveEncoderGeneration() -> UInt64 {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        encoderGeneration &+= 1
        return encoderGeneration
    }

    private func installEncoder(_ newEncoder: VTCompressionSession,
                                width: Int,
                                height: Int,
                                generation: UInt64) -> Bool {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        guard encoderGeneration == generation else { return false }
        encoder = newEncoder
        encoderWidth = width
        encoderHeight = height
        encoderSetupFailed = false
        return true
    }

    private func isCurrentEncoderGeneration(_ generation: UInt64) -> Bool {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        return encoder != nil && encoderGeneration == generation
    }

    private func markEncoderOutputSuccessful(generation: UInt64) {
        var shouldResetBackoff = false
        encoderStateLock.lock()
        if encoder != nil,
           encoderGeneration == generation,
           recoveryBackoffResetGeneration != generation {
            recoveryBackoffResetGeneration = generation
            shouldResetBackoff = true
        }
        encoderStateLock.unlock()
        guard shouldResetBackoff else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.isCurrentEncoderGeneration(generation) else { return }
            self.recoveryAttempt = 0
        }
    }

    private func claimEncoderOutputFailure(generation: UInt64) -> VTCompressionSession? {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        guard let failedEncoder = encoder,
              encoderGeneration == generation else { return nil }
        // Quarantine synchronously while still inside the callback: all later
        // output from this generation becomes stale before recovery is queued.
        encoder = nil
        encoderWidth = 0
        encoderHeight = 0
        encoderGeneration &+= 1
        encoderSetupFailed = true
        forceNextKeyFrame = true
        return failedEncoder
    }

    private func handleEncoderOutputFailure(status: OSStatus,
                                            sampleBufferMissing: Bool,
                                            generation: UInt64) {
        guard let failedEncoder = claimEncoderOutputFailure(generation: generation) else { return }
        let reason = status != noErr
            ? "HEVC encoder callback failed: \(status)"
            : (sampleBufferMissing
               ? "HEVC encoder callback returned no frame"
               : "HEVC encoder callback failed")
        // Returning from VideoToolbox's callback before invalidating its
        // session avoids re-entrancy/deadlock risk. Only the callback which
        // claimed the generation owns this queued recovery.
        sessionQueue.async { [weak self] in
            VTCompressionSessionInvalidate(failedEncoder)
            guard let self, self.appIsActive, self.isConfigured, !self.stopped else { return }
            self.updateStreamHealth(camera: "CAMERA encoder error • recovering",
                                    event: reason)
            self.report(reason)
            self.scheduleRecoveryOnSessionQueue(reason: "Encoder callback recovery")
        }
    }

    private func isEncoderSetupFailed() -> Bool {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        return encoderSetupFailed
    }

    private func setEncoderSetupFailed(_ failed: Bool) {
        encoderStateLock.lock()
        encoderSetupFailed = failed
        encoderStateLock.unlock()
    }

    private func invalidateEncoder(reason: String?) {
        encoderStateLock.lock()
        let oldEncoder = encoder
        encoder = nil
        encoderWidth = 0
        encoderHeight = 0
        encoderGeneration &+= 1
        encoderSetupFailed = false
        forceNextKeyFrame = true
        encoderStateLock.unlock()
        if let oldEncoder {
            VTCompressionSessionInvalidate(oldEncoder)
        }
        if let reason { report(reason) }
    }

    private func resumeAfterForeground() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.appIsActive = true
            self.recoveryAttempt = 0
            // Control Center, notifications, Siri and the USB "Trust" alert make the
            // app inactive without stopping capture. Keep a healthy pipeline as is.
            if self.isConfigured, !self.stopped,
               self.session.isRunning, !self.session.isInterrupted,
               !self.isEncoderSetupFailed() {
                self.startLivenessWatchdog()
                if self.activeEncoder() == nil {
                    // Rebuilt lazily on the next frame with a forced IDR.
                    self.sender.resetForDiscontinuity(reason: "Camera resumed • waiting for keyframe")
                    self.requestKeyFrame()
                }
                return
            }
            self.recoverSession(reason: "Camera resumed • waiting for encoder")
        }
    }

    private func pauseRecoveryForBackground() {
        sessionQueue.async { [weak self] in
            self?.appIsActive = false
            self?.stopLivenessWatchdog()
        }
    }

    private func handleSessionInterruption() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.stopped else { return }
            self.updateStreamHealth(camera: "CAMERA interrupted • recovering",
                                    event: "Camera interrupted")
            self.invalidateEncoder(reason: "Camera interrupted")
        }
    }

    private func handleSessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.stopped else { return }
            self.updateStreamHealth(camera: "CAMERA error • recovering",
                                    event: "Camera runtime reset")
            self.invalidateEncoder(reason: "Camera runtime reset")
            if error?.code == .mediaServicesWereReset || !self.session.isRunning {
                self.scheduleRecoveryOnSessionQueue(reason: "Camera runtime reset")
            }
        }
    }

    private func handleSessionStopped() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.stopped else { return }
            self.updateStreamHealth(camera: "CAMERA stopped • recovering",
                                    event: "Camera stopped unexpectedly")
            self.invalidateEncoder(reason: "Camera stopped unexpectedly")
            self.scheduleRecoveryOnSessionQueue(reason: "Camera stop recovery")
        }
    }

    private func handleThermalStateChange() {
        let thermalState = ProcessInfo.processInfo.thermalState
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let label: String
            switch thermalState {
            case .nominal: label = "THERMAL nominal"
            case .fair: label = "THERMAL fair"
            case .serious: label = "THERMAL serious • 4K60 at risk"
            case .critical: label = "THERMAL critical • camera may stop"
            @unknown default: label = "THERMAL unknown"
            }
            self.setThermalTelemetry(label)
        }
    }

    private func handleSystemPressureChange() {
        guard let device = videoDevice else { return }
        let pressure = device.systemPressureState.level
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let label: String
            switch pressure {
            case .nominal: label = "PRESSURE nominal"
            case .fair: label = "PRESSURE fair"
            case .serious: label = "PRESSURE serious • 4K60 at risk"
            case .critical: label = "PRESSURE critical • camera may stop"
            case .shutdown: label = "PRESSURE shutdown • camera interrupted"
            default: label = "PRESSURE unknown"
            }
            self.setPressureTelemetry(label)
        }
    }

    private func setThermalTelemetry(_ value: String) {
        telemetryLock.lock()
        thermalTelemetry = value
        telemetryLock.unlock()
        publishDiagnostics()
        if value.contains("risk") || value.contains("critical") || value.contains("shutdown") {
            report(value)
        }
    }

    private func setPressureTelemetry(_ value: String) {
        telemetryLock.lock()
        pressureTelemetry = value
        telemetryLock.unlock()
        publishDiagnostics()
        if value.contains("risk") || value.contains("critical") || value.contains("shutdown") {
            report(value)
        }
    }

    private func recoverSession(reason: String) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard appIsActive, isConfigured, !stopped, let device = videoDevice else { return }
        updateStreamHealth(camera: "CAMERA recovering • waiting for first 4K frame",
                           event: reason)
        session.beginConfiguration()
        let configured = apply4K60Format(to: device)
        session.commitConfiguration()
        guard configured else {
            scheduleRecoveryOnSessionQueue(reason: "4K60 configuration recovery")
            return
        }
        invalidateEncoder(reason: nil)
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else {
            scheduleRecoveryOnSessionQueue(reason: "Camera start recovery")
            return
        }
        refreshActiveFormatTelemetry(device)
        sender.resetForDiscontinuity(reason: "Camera recovered • waiting for keyframe")
        startLivenessWatchdog()
        requestKeyFrame()
        report(reason)
    }

    private func scheduleRecovery(reason: String) {
        sessionQueue.async { [weak self] in
            self?.scheduleRecoveryOnSessionQueue(reason: reason)
        }
    }

    private func scheduleRecoveryOnSessionQueue(reason: String) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard appIsActive, isConfigured, !stopped, !recoveryScheduled else { return }
        recoveryScheduled = true
        let delay = min(8.0, 0.25 * pow(2.0, Double(recoveryAttempt)))
        recoveryAttempt = min(recoveryAttempt + 1, 5)
        report(String(format: "%@ • retrying in %.2fs", reason, delay))
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.recoveryScheduled = false
            guard self.appIsActive, self.isConfigured, !self.stopped else { return }
            self.recoverSession(reason: "\(reason) recovered")
        }
    }
}
