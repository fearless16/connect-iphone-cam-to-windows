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
    private var encoder: VTCompressionSession?
    private var outputFile: FileHandle?
    private let sender = StreamSender()
    private var frameNumber: UInt32 = 0
    private var wroteParameterSets = false
    private let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private var frameStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    // MARK: - Step 1: permission + session start
    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else {
            print("ERROR: camera permission denied")
            return
        }

        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        guard !cameras.devices.isEmpty else {
            print("ERROR: no camera found")
            return
        }

        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            configureSession()
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    print("ERROR: camera permission denied")
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
            print("ERROR: no back camera")
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
            if let fmt = device.formats.first(where: { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width == 3840 && d.height == 2160 &&
                    format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 60 })
            }) {
                device.activeFormat = fmt
                let dur = CMTime(value: 1, timescale: 60)
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            device.unlockForConfiguration()
        } catch {
            print("ERROR: lockForConfiguration \(error)")
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

        openOutputFile()
        createEncoder(width: 3840, height: 2160)
        session.startRunning()
        sender.start()   // Step 5: begin listening for the Windows receiver
        frameStartUptime = ProcessInfo.processInfo.systemUptime
        print("STATUS: Camera Active")
    }

    // MARK: - Step 4: VideoToolbox hardware HEVC encoder
    private func createEncoder(width: Int, height: Int) {
        var sessionOut: VTCompressionSession?
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
            compressionSessionOut: &sessionOut)

        guard status == noErr, let enc = sessionOut else {
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
        guard let enc = encoder, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(enc,
                                        imageBuffer: px,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: nil,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: &flags)
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

        // Emit VPS/SPS/PPS once (HEVC parameter sets).
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

        outputFile?.write(annexB)
        sender.send(frameNumber: frameNumber,
                    timestampUs: monotonicUs(),
                    codec: StreamCodec.hevc.rawValue,
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
        try? outputFile?.close()
    }
}