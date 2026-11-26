import AVFoundation
import CoreMedia
import Foundation

/// Builds the owner's read-only device capability report (T5.2). It only reads
/// AVCaptureDevice formats; it never touches the capture session or the stream.
/// `CameraStreamer.capabilityReport(completion:)` runs it off the main queue.
enum CapabilityReport {

    static func build(osVersion: String) -> String {
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
}
