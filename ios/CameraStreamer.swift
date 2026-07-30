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
    private var outputFile: FileHandle?
    // Raw 4K60 HEVC recording consumes roughly 600 MB/min at the stream bitrate.
    // Leave it off for live streaming; enable only while diagnosing encoding.
    private let saveEncodedStream = false
    private let sender = StreamSender()
    private var frameNumber: UInt32 = 0
    private let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private var frameStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

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
        session.sessionPreset = .hd4K3840x2160

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

        do {
            try device.lockForConfiguration()
            guard let fmt = device.formats.first(where: { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width == 3840 && d.height == 2160 &&
                    format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 })
            }) else {
                print("ERROR: this camera does not support 3840x2160 at 60 fps")
                report("This iPhone does not support 4K at 60 fps")
                device.unlockForConfiguration()
                session.commitConfiguration()
                return
            }
            device.activeFormat = fmt
            let dur = CMTime(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            device.unlockForConfiguration()
        } catch {
            report("Camera configuration failed: \(error.localizedDescription)")
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
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "capture"))
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)

        session.commitConfiguration()

        if saveEncodedStream { openOutputFile() }
        encoder = nil
        encoderSetupFailed = false
        reportedNon4KFrame = false
        session.startRunning()
        sender.onStatus = { [weak self] message in
            self?.report(message)
        }
        sender.onClientConnected = { [weak self] in
            self?.requestKeyFrame()
        }
        sender.start()   // Step 5: begin listening for the Windows receiver
        frameStartUptime = ProcessInfo.processInfo.systemUptime
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
        encoder = enc
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
        if encoder == nil && !encoderSetupFailed {
            createEncoder(width: width, height: height)
        }
        guard let enc = encoder else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
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
            report("Frame encoder error: \(status)")
            return
        }
        frameNumber &+= 1
        let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - frameStartUptime)
        if frameNumber % 600 == 0 {
            print(String(format: "FPS: ~%.1f", Double(frameNumber) / elapsed))
        }
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
        sender.send(frameNumber: frameNumber,
                    timestampUs: monotonicUs(),
                    codec: StreamCodec.hevc.rawValue,
                    isKeyframe: isKeyframe,
                    frame: annexB)
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
        session.stopRunning()
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        }
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
}
