import AVFoundation
import UIKit
import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation
import os

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

/// Output quality presets (gate G8 prime): the 60 fps ladder, plus Cinematic at
/// 30 fps, Apple's limit for it (gate G11). The chosen preset sets the camera,
/// the capture format and the encoder bit rate; it never changes the wire format.
enum StreamPreset: String, CaseIterable {
    case p720 = "720p60"
    case p1080 = "1080p60"
    case p2160 = "4K60"
    case cinematic1080 = "Cinematic 1080p30"
    case cinematic2160 = "Cinematic 4K30"

    /// The 60 fps presets, lowest first. The quality advisor (T5.7) steps only along these.
    static let ladder: [StreamPreset] = [.p720, .p1080, .p2160]

    static let preferenceKey = "stream.preset"
    static var stored: StreamPreset {
        guard let value = UserDefaults.standard.string(forKey: preferenceKey),
              let preset = StreamPreset(rawValue: value) else { return .p2160 }
        return preset
    }

    /// T5.9: Cinematic Video runs on the rear Dual Wide camera only.
    var isCinematic: Bool { self == .cinematic1080 || self == .cinematic2160 }
    var width: Int {
        switch self {
        case .p720: return 1280
        case .p1080, .cinematic1080: return 1920
        case .p2160, .cinematic2160: return 3840
        }
    }
    var height: Int {
        switch self {
        case .p720: return 720
        case .p1080, .cinematic1080: return 1080
        case .p2160, .cinematic2160: return 2160
        }
    }
    var frameRate: Int { isCinematic ? 30 : 60 }
    var title: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p2160: return "4K"
        case .cinematic1080: return "Cine 1080"
        case .cinematic2160: return "Cine 4K"
        }
    }

    /// Average bit rates in bits per second (gate G8 prime). Peak = average / 4 bytes per 1 s.
    /// Cinematic uses the rate of the same size (G8 prime).
    var bitRates: (usb: Int, wifi: Int) {
        switch self {
        case .p720: return (usb: 10_000_000, wifi: 8_000_000)
        case .p1080: return (usb: 20_000_000, wifi: 15_000_000)
        case .p2160: return (usb: 40_000_000, wifi: 25_000_000)
        case .cinematic1080: return StreamPreset.p1080.bitRates
        case .cinematic2160: return StreamPreset.p2160.bitRates
        }
    }
}

/// Owns the camera pipeline: capture at the chosen preset, hardware HEVC
/// (Annex-B), recovery, telemetry and health, and hands every access unit to
/// `StreamSender`. The UI talks only to this class.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    var captureSession: AVCaptureSession { session }
    var onStatus: ((String) -> Void)?
    private var encoder: VTCompressionSession?
    private var encoderSetupFailed = false
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "iPhoneCameraStream",
                                    category: "camera")
    // Protected by encoderStateLock: set on the capture queue, cleared on sessionQueue.
    private var reportedUnexpectedFrameSize = false
    private let encoderStateLock = OSAllocatedUnfairLock()
    // Protected by encoderStateLock: the chosen preset, whether the PC is
    // connected over Wi-Fi, and whether a live bit rate failure was reported.
    private var activePreset = StreamPreset.stored
    private var linkIsWiFi = false
    private var bitRateFailureReported = false
    // T5.8: the adapted target while the link is struggling; nil means the full
    // preset rate. Protected by encoderStateLock.
    private var liveBitRate: Int?
    // G4: HEVC runs only while a PC receiver is connected; the preview stays
    // live. Less heat and battery over a long session. Protected by
    // encoderStateLock; set from the sender's connection callback.
    private var receiverWantsVideo = false
    // T5.8: link-window state. Accessed only on sessionQueue. The window's drops
    // and queue wait arrive with each StreamSender.LinkStats reading.
    private var bitrateController = BitrateController()
    private var presetAdvisor = PresetAdvisor()
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
    // T5.9: the "too dark" scene status while a Cinematic preset runs. sessionQueue.
    private var cinematicSceneObservation: NSKeyValueObservation?
    private var outputFile: FileHandle?
    // Raw 4K60 HEVC recording consumes roughly 600 MB/min at the stream bitrate.
    // Leave it off for live streaming; enable only while diagnosing encoding.
    private let saveEncodedStream = false
    private let sender = StreamSender()
    // T6.1: hands the previous run's crash report to the PC once. Off the video path.
    private let crashReports = CrashReportService()
    private var frameNumber: UInt32 = 0
    private var encodedFrameNumber: UInt32 = 0
    private let protocolTimestampLock = OSAllocatedUnfairLock()
    private var lastProtocolTimestampUs: UInt64 = 0
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var encoderGeneration: UInt64 = 1
    // Protected by encoderStateLock. Prevents a 60fps stream from dispatching
    // one recovery-backoff reset for every successful output callback.
    private var recoveryBackoffResetGeneration: UInt64 = 0
    private var frameStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private let telemetryLock = OSAllocatedUnfairLock()
    private var activeFormatTelemetry = "Waiting for camera format"
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
        // A fixed format needs the POSIX locale, or user settings can change it.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private var thermalTelemetry = "THERMAL nominal"
    private var pressureTelemetry = "PRESSURE nominal"
    private var didReceiveFirstCameraFrame = false
    private let healthLock = OSAllocatedUnfairLock()
    private var healthRevision: UInt64 = 0
    private var healthUpdatesEnabled = false
    private var cameraHealth = "CAMERA starting"
    private var usbHealth = "USB waiting for Windows receiver"
    private var wifiHealth = "WI-FI off (USB only)"
    private var bitrateHealth = "BITRATE --"
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

    // Main queue only. A scene that reconnects (UIScene lifecycle) creates a new
    // view controller, which calls start() again on the running pipeline.
    private var startRequested = false

    // MARK: - Step 1: permission + session start
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !startRequested else {
            republishState()
            return
        }
        startRequested = true
        beginStreamHealth()
        updateStreamHealth(camera: "CAMERA starting • requesting access",
                           event: "Preparing \(StreamPreset.stored.rawValue) camera")
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

        // T5.9: a stored Cinematic preset starts on the Dual Wide camera; without
        // one, start at 4K60 on the Wide camera.
        if currentPreset().isCinematic, Self.captureDevice(for: currentPreset()) == nil {
            setActivePreset(.p2160)
        }
        guard var device = Self.captureDevice(for: currentPreset()) else {
            updateStreamHealth(camera: "CAMERA error • back camera unavailable",
                               event: "No back camera found")
            report("No back camera found")
            session.commitConfiguration()
            return
        }

        // Startup only: list the formats for diagnosis (debug level, not kept in release logs).
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let maxFps = format.videoSupportedFrameRateRanges
                .map { $0.maxFrameRate }.max() ?? 0
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            Self.log.debug("FORMAT: \(dims.width)x\(dims.height) maxFps=\(maxFps) subtype=\(subtype)")
        }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            updateStreamHealth(camera: "CAMERA error • input unavailable",
                               event: "Camera input unavailable")
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoDevice = device
        // The KVO callback runs on an arbitrary thread: read the level from the
        // device it hands over, never from sessionQueue state.
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            self?.handleSystemPressureChange(device.systemPressureState.level)
        }
        handleThermalStateChange()
        handleSystemPressureChange(device.systemPressureState.level)

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
        var preset = currentPreset()
        var configured = applyFormat(preset, to: device) && applyCinematic(preset)
        if !configured, preset.isCinematic, let wide = Self.captureDevice(for: .p2160) {
            // T5.9: never leave the app without a camera because Cinematic failed.
            report("\(preset.rawValue) unavailable • starting at 4K60")
            preset = .p2160
            setActivePreset(preset)
            UserDefaults.standard.set(preset.rawValue, forKey: StreamPreset.preferenceKey)
            if switchCamera(to: wide) { device = wide }
            configured = applyFormat(preset, to: device)
        }
        guard configured else {
            updateStreamHealth(camera: "CAMERA error • \(preset.rawValue) unavailable",
                               event: "\(preset.rawValue) camera configuration failed")
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()

        if saveEncodedStream { openOutputFile() }
        isConfigured = true
        stopped = false
        invalidateEncoder(reason: nil)
        encoderStateLock.lock()
        reportedUnexpectedFrameSize = false
        encoderStateLock.unlock()
        session.startRunning()
        setIdleTimerDisabled(true)
        refreshActiveFormatTelemetry(device)
        sender.onStatus = { [weak self] message in
            self?.report(message)
        }
        sender.onConnectionState = { [weak self] state in
            // Before the sessionQueue hop, so the next camera frame already sees it.
            self?.setReceiverWantsVideo(state == .connected || state == .sending)
            self?.sessionQueue.async { [weak self] in
                guard let self, self.isConfigured, !self.stopped else { return }
                self.updateUSBHealth(state)
            }
        }
        sender.onClientConnected = { [weak self] in
            self?.requestKeyFrame()
        }
        sender.onClientTransport = { [weak self] overWiFi in self?.setLinkIsWiFi(overWiFi) }
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
        sender.onLinkStats = { [weak self] stats in
            self?.sessionQueue.async { [weak self] in self?.handleLinkStats(stats) }
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
        crashReports.onStatus = { [weak self] message in
            self?.report(message)
        }
        crashReports.setWiFiEnabled(Self.isWiFiEnabledStored)
        crashReports.start()
        startLivenessWatchdog()
        frameStartUptime = ProcessInfo.processInfo.systemUptime
        publishDiagnostics()
        publishOutputOrientation(initialOrientation)
        updateStreamHealth(camera: "CAMERA running • waiting for first frame",
                           usb: "USB waiting for Windows receiver • HEVC paused",
                           event: "Camera started • screen kept awake")
        report("Camera active • screen kept awake • waiting for PC")
        publishPreset(preset)
        publishPresetAvailability()
        publishCinematicControls()
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
            let text = CapabilityReport.build(osVersion: osVersion)
            DispatchQueue.main.async { completion(text) }
        }
    }

    // MARK: - T5.4 quality presets (gate G8 prime)
    /// The preset in use changed (or a requested change was refused). Main queue.
    var onPresetChanged: ((StreamPreset) -> Void)?
    /// Presets this iPhone has a matching capture format for. Main queue.
    var onPresetAvailability: (([StreamPreset]) -> Void)?
    /// A recommended preset and a short reason (T5.7). The app only shows it;
    /// the user taps Switch. Main queue.
    var onAdvice: ((StreamPreset, String) -> Void)?

    private func currentPreset() -> StreamPreset {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        return activePreset
    }

    /// The bit rate the encoder should use now: the adapted rate while the link
    /// is struggling, otherwise the full rate of the preset and transport.
    private func currentBitRate() -> Int {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        return liveBitRate ?? presetTargetBitRateLocked()
    }

    /// The full rate for the current preset and transport. Caller holds encoderStateLock.
    private func presetTargetBitRateLocked() -> Int {
        linkIsWiFi ? activePreset.bitRates.wifi : activePreset.bitRates.usb
    }

    private func setLinkIsWiFi(_ overWiFi: Bool) {
        encoderStateLock.lock()
        let changed = linkIsWiFi != overWiFi
        let adapted = liveBitRate != nil
        linkIsWiFi = overWiFi
        liveBitRate = nil
        encoderStateLock.unlock()
        // A new PC connection starts again from the full preset rate.
        sessionQueue.async { [weak self] in self?.resetAdaptiveBitRate() }
        if changed || adapted { applyLiveBitRate() }
    }

    // MARK: - T5.8 adaptive bit rate (gate G14)
    /// Folds one 2-second link reading into the live bit rate. The resolution is
    /// never changed here, and the rate stays within 50-100% of the preset.
    private func handleLinkStats(_ stats: StreamSender.LinkStats) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard isConfigured, !stopped else { return }
        // The sender closes each window on its own timer, so a stalled link that
        // sends nothing still reports its drops and its growing queue wait.
        let window = LinkWindow(drops: stats.drops,
                                maxQueueMs: stats.maxQueueMs,
                                rttMs: stats.rttMs,
                                rttVarMs: stats.rttVarMs,
                                retransmitRatio: stats.retransmitRatio,
                                thermal: ProcessInfo.processInfo.thermalState)
        encoderStateLock.lock()
        let target = presetTargetBitRateLocked()
        let overWiFi = linkIsWiFi
        let preset = activePreset
        let current = liveBitRate ?? target
        let next = bitrateController.nextBitrate(current: current, presetTarget: target, window: window)
        if next != current { liveBitRate = next }
        encoderStateLock.unlock()
        if next != current {
            applyLiveBitRate()
            publishBitrateHealth()
        }
        recommendPreset(from: preset, overWiFi: overWiFi, bitrate: next, target: target, window: window)
    }

    /// Suggests another preset when the link or the phone cannot keep up (T5.7).
    /// It only publishes the suggestion; the resolution changes only when the
    /// user chooses it.
    private func recommendPreset(from preset: StreamPreset, overWiFi: Bool, bitrate: Int, target: Int,
                                 window: LinkWindow) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        // Cinematic is the user's explicit choice: never advise away from it.
        guard let index = StreamPreset.ladder.firstIndex(of: preset) else { return }
        guard let advice = presetAdvisor.advice(presetIndex: index,
                                                presetCount: StreamPreset.ladder.count,
                                                overWiFi: overWiFi,
                                                bitrateAtFloor: bitrate <= target / 2,
                                                bitrateAtFull: bitrate >= target,
                                                window: window,
                                                now: ProcessInfo.processInfo.systemUptime) else { return }
        let toIndex: Int
        let reason: String
        switch advice {
        case .down(let advisedIndex, let advisedReason): toIndex = advisedIndex; reason = advisedReason
        case .up(let advisedIndex, let advisedReason): toIndex = advisedIndex; reason = advisedReason
        }
        guard StreamPreset.ladder.indices.contains(toIndex) else { return }
        let suggested = StreamPreset.ladder[toIndex]
        report("Quality advice: \(suggested.rawValue) • \(reason)")
        DispatchQueue.main.async { [weak self] in self?.onAdvice?(suggested, reason) }
    }

    /// Back to the full preset rate: after a preset change, a new PC connection
    /// or a camera recovery.
    private func resetAdaptiveBitRate() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        encoderStateLock.lock()
        liveBitRate = nil
        encoderStateLock.unlock()
        bitrateController = BitrateController()
        presetAdvisor = PresetAdvisor()
        publishBitrateHealth()
    }

    private func publishBitrateHealth() {
        encoderStateLock.lock()
        let target = presetTargetBitRateLocked()
        let live = liveBitRate ?? target
        encoderStateLock.unlock()
        updateStreamHealth(bitrate: Self.bitrateHealthText(live: live, target: target))
    }

    private static func bitrateHealthText(live: Int, target: Int) -> String {
        String(format: "BITRATE %.1f/%.0f Mbps", Double(live) / 1e6, Double(target) / 1e6)
    }

    /// Applies the current target rate to the running encoder. A failure is
    /// reported once and is not fatal: the encoder keeps its previous rate.
    private func applyLiveBitRate() {
        guard let encoder = activeEncoder()?.session else { return }
        let target = currentBitRate()
        let rateLimit: CFArray = [NSNumber(value: target / 4), NSNumber(value: 1)] as CFArray
        let statuses = [
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: target)),
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_DataRateLimits, value: rateLimit),
        ]
        guard let failed = statuses.first(where: { $0 != noErr }) else { return }
        encoderStateLock.lock()
        let firstFailure = !bitRateFailureReported
        bitRateFailureReported = true
        encoderStateLock.unlock()
        if firstFailure { report("Bit rate change failed: \(failed)") }
    }

    /// Switches the capture format and encoder to `preset` without touching the
    /// PC connection: the receiver sees a new VPS/SPS/PPS + IDR and follows the
    /// size. Never call restartListening here.
    func setPreset(_ preset: StreamPreset) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isConfigured, !self.stopped, let previous = self.videoDevice,
                  let device = Self.captureDevice(for: preset) else {
                self.publishPreset(self.currentPreset())
                return
            }
            let previousPreset = self.currentPreset()
            // T5.9: entering or leaving Cinematic swaps the camera input inside the
            // same transaction. The video output, the encoder session owner and the
            // PC connection stay.
            let switched = device.uniqueID != previous.uniqueID
            self.session.beginConfiguration()
            let applied = (!switched || self.switchCamera(to: device)) &&
                self.applyFormat(preset, to: device) && self.applyCinematic(preset)
            if applied {
                // Set before the commit so the first frames of the new size are
                // not mistaken for a wrong-size camera.
                self.setActivePreset(preset)
            } else if switched || preset.isCinematic {
                // The camera or the format may have changed half way: put the
                // previous camera and format back; the stream keeps going.
                let restored = (!switched || self.switchCamera(to: previous)) &&
                    self.applyFormat(previousPreset, to: previous) && self.applyCinematic(previousPreset)
                if !restored { self.report("Could not restore \(previousPreset.rawValue)") }
            }
            self.session.commitConfiguration()
            guard applied else {
                self.report("\(preset.rawValue) unavailable • keeping \(self.currentPreset().rawValue)")
                if switched {
                    // The camera went away and came back: rejoin cleanly.
                    self.publishOutputOrientation(self.activeOutputOrientation)
                    self.invalidateEncoder(reason: nil)
                    self.sender.resetForDiscontinuity(reason: "Preset \(previousPreset.rawValue)")
                }
                self.publishPreset(self.currentPreset())
                self.publishCinematicControls()
                return
            }
            UserDefaults.standard.set(preset.rawValue, forKey: StreamPreset.preferenceKey)
            // A new input has a new preview connection: re-apply its rotation.
            if switched { self.publishOutputOrientation(self.activeOutputOrientation) }
            self.invalidateEncoder(reason: nil)
            self.sender.resetForDiscontinuity(reason: "Preset \(preset.rawValue)")
            self.refreshActiveFormatTelemetry(device)
            self.resetAdaptiveBitRate()
            self.publishPreset(preset)
            self.publishCinematicControls()
        }
    }

    private func setActivePreset(_ preset: StreamPreset) {
        encoderStateLock.lock()
        activePreset = preset
        liveBitRate = nil
        encoderStateLock.unlock()
    }

    private func publishPreset(_ preset: StreamPreset) {
        DispatchQueue.main.async { [weak self] in self?.onPresetChanged?(preset) }
    }

    private func publishPresetAvailability() {
        let available = StreamPreset.allCases.filter { preset in
            guard let device = Self.captureDevice(for: preset) else { return false }
            return device.formats.contains { Self.format($0, supports: preset) }
        }
        for preset in StreamPreset.allCases where !available.contains(preset) {
            report("\(preset.title) not supported on this iPhone")
        }
        DispatchQueue.main.async { [weak self] in self?.onPresetAvailability?(available) }
    }

    // T3.1: Wi-Fi streaming is opt-in and off by default (G7 option A).
    static let wifiPreferenceKey = "stream.wifiEnabled"

    static var isWiFiEnabledStored: Bool {
        UserDefaults.standard.bool(forKey: wifiPreferenceKey)
    }

    /// Persists the Wi-Fi choice and applies it. The sender rebuilds only its
    /// listener: a USB connection keeps streaming, and a Wi-Fi client is closed
    /// only when Wi-Fi is turned off.
    func setWiFiEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.wifiPreferenceKey)
        sender.setWiFiEnabled(enabled)
        crashReports.setWiFiEnabled(enabled)
    }

    private static func wifiHealthText(_ address: String?, enabled: Bool) -> String {
        if let address {
            return "WI-FI \(address):\(StreamSender.port) • visible to this network"
        }
        return enabled ? "WI-FI on • waiting for a Wi-Fi address" : "WI-FI off (USB only)"
    }

    /// Persists a user-selected frame orientation. The setting affects only the
    /// camera output connection; USB framing and the receiver protocol stay
    /// unchanged. Like a preset change it keeps the PC connection (P1): the
    /// rebuilt encoder starts with VPS/SPS/PPS + IDR in the new dimensions and
    /// the receiver follows the size from the SPS. Never call restartListening here.
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
            // invalidateEncoder forces the next frame to be an IDR.
            self.invalidateEncoder(reason: nil)
            self.sender.resetForDiscontinuity(reason: "Output changed to \(orientation.title)")
            self.publishOutputOrientation(orientation)
            self.report("Output \(orientation.title) selected • waiting for keyframe")
        }
    }

    // MARK: - Step 4: VideoToolbox hardware HEVC encoder
    private func createEncoder(width: Int, height: Int) {
        let target = currentBitRate()
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
        let rateLimit: CFArray = [NSNumber(value: target / 4), NSNumber(value: 1)] as CFArray
        let propertyStatuses: [(String, OSStatus)] = [
            ("real-time", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)),
            ("frame reordering", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)),
            ("HEVC profile", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)),
            ("bitrate", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: target))),
            ("rate limit", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_DataRateLimits, value: rateLimit)),
            ("frame rate", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: currentPreset().frameRate))),
            // G3: a keyframe every second halves the worst-case recovery and
            // OBS join time. The duration cap keeps it at 1 s at any frame rate.
            ("keyframe interval", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))),
            ("keyframe duration", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1))),
        ]
        if let failed = propertyStatuses.first(where: { $0.1 != noErr }) {
            VTCompressionSessionInvalidate(enc)
            setEncoderSetupFailed(true)
            report("HEVC encoder setting failed (\(failed.0)): \(failed.1)")
            scheduleRecovery(reason: "HEVC encoder setup recovery")
            return
        }
        // Optional hint: lower encode latency at a small quality cost. Some
        // encoders don't support it, so a failure must not fail setup.
        let speedStatus = VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                                               value: kCFBooleanTrue)
        if speedStatus != noErr {
            Self.log.notice("HEVC encoder ignored PrioritizeEncodingSpeedOverQuality: \(speedStatus)")
        }
        // Optional hint: the encoder may hold at most one frame before it must
        // emit it (the default is unlimited). Caps encoder delay at ~16 ms at 60 fps.
        let delayStatus = VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                                               value: NSNumber(value: 1))
        if delayStatus != noErr {
            Self.log.notice("HEVC encoder ignored MaxFrameDelayCount: \(delayStatus)")
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
        guard isPresetFrame(width: width, height: height) else {
            encoderStateLock.lock()
            let firstMismatch = !reportedUnexpectedFrameSize
            reportedUnexpectedFrameSize = true
            encoderStateLock.unlock()
            if firstMismatch {
                report("Camera delivered \(width)x\(height), expected \(currentPreset().rawValue)")
            }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        recordSensorFrame(pts)
        // G4: no PC, no encoding. Capture liveness above still counts frames.
        guard receiverWantsVideoNow() else { return }
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
            let fps = Double(frameNumber) / elapsed
            Self.log.debug("FPS: ~\(fps, format: .fixed(precision: 1))")
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

    private func isPresetFrame(width: Int, height: Int) -> Bool {
        let preset = currentPreset()
        return (width == preset.width && height == preset.height) ||
            (width == preset.height && height == preset.width)
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
        let preset = currentPreset()
        let requestedFps = Double(preset.frameRate)
        let verified = Int(dimensions.width) == preset.width && Int(dimensions.height) == preset.height &&
            abs(minimumFps - requestedFps) < 0.1 && abs(maximumFps - requestedFps) < 0.1
        let state = verified ? "VERIFIED \(preset.rawValue)" : "MISMATCH"
        resetTelemetry(format: String(format: "%@ %dx%d • device %.1f-%.1f fps • request %.1f",
                                       state, dimensions.width, dimensions.height,
                                       minimumFps, maximumFps, requestedFps))
    }

    /// True when `format` has the preset size and can run at its frame rate.
    private static func format(_ format: AVCaptureDevice.Format, supports preset: StreamPreset) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let frameRate = Double(preset.frameRate)
        let matches = Int(dimensions.width) == preset.width && Int(dimensions.height) == preset.height &&
            format.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= frameRate && $0.maxFrameRate >= frameRate
            })
        guard matches, preset.isCinematic else { return matches }
        if #available(iOS 26, *) { return format.isCinematicVideoCaptureSupported }
        return false
    }

    // MARK: - T5.9 Cinematic mode (gate G11)
    /// The rear camera each preset runs on: Cinematic needs the Dual Wide camera.
    private static func captureDevice(for preset: StreamPreset) -> AVCaptureDevice? {
        AVCaptureDevice.default(preset.isCinematic ? .builtInDualWideCamera : .builtInWideAngleCamera,
                                for: .video, position: .back)
    }

    private func cameraInput() -> AVCaptureDeviceInput? {
        session.inputs.lazy.compactMap { $0 as? AVCaptureDeviceInput }.first
    }

    /// R5: replaces the session's camera input. Runs on sessionQueue inside
    /// begin/commitConfiguration. Keeps the PC connection (P1): the caller
    /// invalidates the encoder and calls resetForDiscontinuity.
    private func switchCamera(to device: AVCaptureDevice) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let newInput = try? AVCaptureDeviceInput(device: device) else {
            report("Camera input unavailable for \(device.localizedName)")
            return false
        }
        let oldInputs = session.inputs
        oldInputs.forEach { session.removeInput($0) }
        guard session.canAddInput(newInput) else {
            oldInputs.forEach { if session.canAddInput($0) { session.addInput($0) } }
            report("Camera input refused for \(device.localizedName)")
            return false
        }
        session.addInput(newInput)
        videoDevice = device
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            self?.handleSystemPressureChange(device.systemPressureState.level)
        }
        handleSystemPressureChange(device.systemPressureState.level)
        // The output gets a new connection to the new input: put the rotation back.
        if let output = videoOutput, !applyOutputOrientation(activeOutputOrientation, to: output) {
            report("\(activeOutputOrientation.title) output lost after the camera switch")
        }
        return true
    }

    /// Turns Cinematic Video on the camera input on for a Cinematic preset and
    /// off otherwise. Runs inside begin/commitConfiguration, after applyFormat:
    /// a format change can turn it off again.
    private func applyCinematic(_ preset: StreamPreset) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard #available(iOS 26, *) else { return !preset.isCinematic }
        guard let input = cameraInput() else { return !preset.isCinematic }
        guard preset.isCinematic else {
            if input.isCinematicVideoCaptureEnabled { input.isCinematicVideoCaptureEnabled = false }
            return true
        }
        guard input.isCinematicVideoCaptureSupported else {
            report("Cinematic is not supported by this camera format")
            return false
        }
        input.isCinematicVideoCaptureEnabled = true
        return true
    }

    /// Cinematic only: the simulated aperture range and value. nil hides the control. Main queue.
    var onCinematicAperture: (((range: ClosedRange<Float>, value: Float)?) -> Void)?
    /// Cinematic only: a short note when the scene is too dark; nil clears it. Main queue.
    var onCinematicNote: ((String?) -> Void)?

    /// Shows or hides the Cinematic controls for the preset in use.
    private func publishCinematicControls() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        cinematicSceneObservation = nil
        var aperture: (range: ClosedRange<Float>, value: Float)?
        if #available(iOS 26, *), currentPreset().isCinematic, let device = videoDevice,
           let input = cameraInput(), input.isCinematicVideoCaptureEnabled {
            let format = device.activeFormat
            if format.minSimulatedAperture > 0, format.maxSimulatedAperture >= format.minSimulatedAperture {
                aperture = (format.minSimulatedAperture...format.maxSimulatedAperture, input.simulatedAperture)
            }
            cinematicSceneObservation = device.observe(\.cinematicVideoCaptureSceneMonitoringStatuses,
                                                       options: [.initial, .new]) { [weak self] device, _ in
                let dark = device.cinematicVideoCaptureSceneMonitoringStatuses.contains(.notEnoughLight)
                DispatchQueue.main.async { self?.onCinematicNote?(dark ? "Not enough light for Cinematic" : nil) }
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onCinematicNote?(nil) }
        }
        DispatchQueue.main.async { [weak self] in self?.onCinematicAperture?(aperture) }
    }

    /// Sets the simulated aperture (f-number) of the running Cinematic preset,
    /// clamped to the format's range.
    func setCinematicAperture(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.stopped, self.currentPreset().isCinematic,
                  let device = self.videoDevice, let input = self.cameraInput() else { return }
            if #available(iOS 26, *), input.isCinematicVideoCaptureEnabled {
                let format = device.activeFormat
                guard format.minSimulatedAperture > 0 else { return }
                input.simulatedAperture = min(max(value, format.minSimulatedAperture), format.maxSimulatedAperture)
            }
        }
    }

    /// A tap on the preview while Cinematic runs: track the subject at `point`,
    /// or hold focus there when `fixed` is true. `point` is in the camera's
    /// 0...1 coordinates (AVCaptureVideoPreviewLayer.captureDevicePointConverted).
    func focusCinematic(at point: CGPoint, fixed: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.stopped, self.currentPreset().isCinematic,
                  let device = self.videoDevice, let input = self.cameraInput() else { return }
            guard #available(iOS 26, *), input.isCinematicVideoCaptureEnabled else { return }
            let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if fixed {
                    device.setCinematicVideoFixedFocus(at: clamped, focusMode: .strong)
                } else {
                    device.setCinematicVideoTrackingFocus(at: clamped, focusMode: .strong)
                }
            } catch {
                self.report("Cinematic focus failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyFormat(_ preset: StreamPreset, to device: AVCaptureDevice) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let matchingFormats = device.formats.filter { Self.format($0, supports: preset) }
            guard let format = matchingFormats.first(where: {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) ==
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }) ?? matchingFormats.first else {
                report("This iPhone has no \(preset.rawValue) format")
                return false
            }

            // Disable automatic HDR before choosing the capture format, then
            // explicitly keep HDR off on that chosen format. Prefer the native
            // 8-bit 420v variant to avoid an HDR/10-bit conversion at 4K60.
            device.automaticallyAdjustsVideoHDREnabled = false
            device.activeFormat = format
            device.isVideoHDREnabled = false
            let duration = CMTime(value: 1, timescale: CMTimeScale(preset.frameRate))
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
            updateStreamHealth(camera: "CAMERA active • first frame received",
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
        let storedRate = StreamPreset.stored.bitRates.usb
        bitrateHealth = Self.bitrateHealthText(live: storedRate, target: storedRate)
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
            updateStreamHealth(usb: "USB waiting for Windows receiver • HEVC paused")
        case .connected:
            updateStreamHealth(usb: "PC receiver connected • waiting for first video frame")
        case .sending:
            updateStreamHealth(usb: "USB connected • PC receiver receiving video")
        case .disconnected:
            updateStreamHealth(usb: "PC receiver disconnected • waiting for receiver • HEVC paused")
        case .failed:
            updateStreamHealth(usb: "USB connection error • reconnecting • HEVC paused")
        }
    }

    private func updateStreamHealth(camera: String? = nil,
                                    usb: String? = nil,
                                    wifi: String? = nil,
                                    bitrate: String? = nil,
                                    event: String? = nil) {
        healthLock.lock()
        guard healthUpdatesEnabled else {
            healthLock.unlock()
            return
        }
        if let camera { cameraHealth = camera }
        if let usb { usbHealth = usb }
        if let wifi { wifiHealth = wifi }
        if let bitrate { bitrateHealth = bitrate }
        if let event { healthEvent = event }
        healthRevision &+= 1
        let revision = healthRevision
        let text = healthSnapshotLocked()
        healthLock.unlock()
        deliverStreamHealth(text, revision: revision)
    }

    private func healthSnapshotLocked() -> String {
        "\(cameraHealth)\n\(usbHealth)\n\(wifiHealth)\n\(bitrateHealth)\nSTATUS: \(healthEvent)"
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
            updateStreamHealth(camera: "CAMERA active • capture resumed",
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
            updateStreamHealth(camera: "CAMERA stalled • no frame for 3s",
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
        Self.log.notice("OUTPUT: \(url.path, privacy: .public)")
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
            self.crashReports.stop()
            try? self.outputFile?.close()
            self.outputFile = nil
        }
    }

    private func report(_ message: String) {
        // os.Logger reaches Console.app and `log stream` on release builds; print does not.
        Self.log.notice("STATUS: \(message, privacy: .public)")
        updateStreamHealth(event: message)
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }

    /// Sends the current health, orientation and preset to a newly attached view
    /// controller without touching the camera, the encoder or the PC connection.
    private func republishState() {
        healthLock.lock()
        let revision = healthRevision
        let text = healthSnapshotLocked()
        healthLock.unlock()
        deliverStreamHealth(text, revision: revision)
        publishDiagnostics()
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.stopped else { return }
            self.publishOutputOrientation(self.activeOutputOrientation)
            self.publishPreset(self.currentPreset())
            self.publishPresetAvailability()
            self.publishCinematicControls()
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

    private func setReceiverWantsVideo(_ wanted: Bool) {
        encoderStateLock.lock()
        let changed = receiverWantsVideo != wanted
        receiverWantsVideo = wanted
        // The encoder may have idled for minutes: resume on an IDR.
        if changed && wanted { forceNextKeyFrame = true }
        encoderStateLock.unlock()
        guard changed else { return }
        // HEVC fps is an average since the first encoded frame; restart it so
        // a pause does not show up as a low rate after resuming.
        telemetryLock.lock()
        encoderFirstPTS = .invalid
        encoderFrameCount = 0
        encoderFPS = 0
        telemetryLock.unlock()
        publishDiagnostics()
    }

    private func receiverWantsVideoNow() -> Bool {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }
        return receiverWantsVideo
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
            case .serious: label = "THERMAL serious • stream at risk"
            case .critical: label = "THERMAL critical • camera may stop"
            @unknown default: label = "THERMAL unknown"
            }
            self.setThermalTelemetry(label, atRisk: thermalState == .serious || thermalState == .critical)
        }
    }

    private func handleSystemPressureChange(_ pressure: AVCaptureDevice.SystemPressureState.Level) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let label: String
            switch pressure {
            case .nominal: label = "PRESSURE nominal"
            case .fair: label = "PRESSURE fair"
            case .serious: label = "PRESSURE serious • stream at risk"
            case .critical: label = "PRESSURE critical • camera may stop"
            case .shutdown: label = "PRESSURE shutdown • camera interrupted"
            default: label = "PRESSURE unknown"
            }
            self.setPressureTelemetry(label,
                                      atRisk: pressure == .serious || pressure == .critical || pressure == .shutdown)
        }
    }

    private func setThermalTelemetry(_ value: String, atRisk: Bool) {
        telemetryLock.lock()
        thermalTelemetry = value
        telemetryLock.unlock()
        publishDiagnostics()
        if atRisk { report(value) }
    }

    private func setPressureTelemetry(_ value: String, atRisk: Bool) {
        telemetryLock.lock()
        pressureTelemetry = value
        telemetryLock.unlock()
        publishDiagnostics()
        if atRisk { report(value) }
    }

    private func recoverSession(reason: String) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard appIsActive, isConfigured, !stopped, let device = videoDevice else { return }
        updateStreamHealth(camera: "CAMERA recovering • waiting for first frame",
                           event: reason)
        session.beginConfiguration()
        let configured = applyFormat(currentPreset(), to: device) && applyCinematic(currentPreset())
        session.commitConfiguration()
        guard configured else {
            scheduleRecoveryOnSessionQueue(reason: "Camera configuration recovery")
            return
        }
        resetAdaptiveBitRate()
        invalidateEncoder(reason: nil)
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else {
            scheduleRecoveryOnSessionQueue(reason: "Camera start recovery")
            return
        }
        refreshActiveFormatTelemetry(device)
        sender.resetForDiscontinuity(reason: "Camera recovered • waiting for keyframe")
        publishCinematicControls()
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
