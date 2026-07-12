import CoreImage
import CoreVideo
import Foundation
import Vision

/// Tunable parameters for the background compositing stage.
/// Mirrors the knobs Apple exposes privately (feather sigma, bokeh aperture,
/// contact shadow, opacity) so we can approximate the system effect.
public struct CompositorParams {
    public var feather: Float        // soft-edge band width, fraction of mask range
    public var bokehRadius: Float    // disc bokeh radius in source pixels
    public var shadowStrength: Float // 0 = off; else contact-shadow darkness
    public var shadowRadius: Float   // contact-shadow blur radius
    public var opacity: Float        // replacement-image blend opacity
    public var backgroundScale: Float // downscale factor for bg blur (perf)

    public init(
        feather: Float = 0.18,
        bokehRadius: Float = 22,
        shadowStrength: Float = 0.35,
        shadowRadius: Float = 28,
        opacity: Float = 1.0,
        backgroundScale: Float = 0.5
    ) {
        self.feather = feather
        self.bokehRadius = bokehRadius
        self.shadowStrength = shadowStrength
        self.shadowRadius = shadowRadius
        self.opacity = opacity
        self.backgroundScale = backgroundScale
    }
}

/// GPU compositing stage: segmentation mask -> trimap-feather -> (bokeh blur OR
/// replacement image) -> soft contact shadow -> blend. Pure Core Image; no
/// Vision dependency in `composite`, so it is unit-testable without a device.
public final class BackgroundStage {
    private let ctx: CIContext
    private let featherK: CIKernel
    private let bokehK: CIKernel
    private let shadowK: CIKernel
    private var bgImage: CIImage?

    public init(context: CIContext = CIContext(), backgroundURL: URL? = nil) {
        self.ctx = context
        self.featherK = CIKernel(source: Self.featherSrc)!
        self.bokehK = CIKernel(source: Self.bokehSrc)!
        self.shadowK = CIKernel(source: Self.shadowSrc)!
        self.bgImage = backgroundURL.flatMap { try? CIImage(contentsOf: $0) }
    }

    public func setBackground(url: URL?) {
        bgImage = url.flatMap { try? CIImage(contentsOf: $0) }
    }

    /// `frame` and `mask` may differ in size; the mask is scaled to the frame.
    /// `mask` is a one-component 8-bit alpha buffer (as produced by Vision).
    /// Returns a BGRA pixel buffer (caller must convert to YUV before encode).
    public func composite(frame: CVPixelBuffer, mask: CVPixelBuffer, params: CompositorParams) -> CVPixelBuffer? {
        let fImg = CIImage(cvPixelBuffer: frame)
        let mImg = CIImage(cvPixelBuffer: mask)
        let scale = CGAffineTransform(
            scaleX: fImg.extent.width / mImg.extent.width,
            y: fImg.extent.height / mImg.extent.height
        )
        let mScaled = mImg.transformed(by: scale)
        guard let alpha = featherK.apply(extent: fImg.extent, arguments: [mScaled, params.feather]) else {
            return nil
        }

        let bg: CIImage
        if let repl = bgImage {
            bg = aspectFill(repl, into: fImg.extent)
        } else {
            bg = bokehBackground(fImg, radius: params.bokehRadius, scale: params.backgroundScale)
        }

        let bgWithShadow: CIImage
        if params.shadowStrength > 0,
           let sh = shadowK.apply(extent: fImg.extent, arguments: [alpha, params.shadowRadius, params.shadowStrength]) {
            let black = CIImage(color: .black).cropped(to: fImg.extent)
            bgWithShadow = black.applyingFilter("CIBlendWithMask",
                parameters: ["inputBackgroundImage": bg, "inputMaskImage": sh])
        } else {
            bgWithShadow = bg
        }

        let blended = bgWithShadow.applyingFilter("CIBlendWithMask",
            parameters: ["inputImage": fImg, "inputMaskImage": alpha])

        var dst: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(fImg.extent.width), Int(fImg.extent.height),
            kCVPixelFormatType_32BGRA, nil, &dst
        )
        guard status == kCVReturnSuccess, let out = dst else { return nil }
        ctx.render(blended, to: out)
        return out
    }

    /// Device-only segmentation via the Neural Engine. Skipped in tests.
    public func segment(frame: CVPixelBuffer, quality: VNPersonSegmentationRequest.QualityLevel = .balanced) -> CVPixelBuffer? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = quality
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
        try? handler.perform([req])
        return (req.results?.first as? VNPixelBufferObservation)?.pixelBuffer
    }

    // MARK: - internals

    private func bokehBackground(_ img: CIImage, radius: Float, scale: Float) -> CIImage {
        guard scale < 1 else {
            return bokehK.apply(extent: img.extent, arguments: [img, radius]) ?? img
        }
        let small = img.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let blurred = bokehK.apply(extent: small.extent, arguments: [small, radius * scale]) else { return img }
        return blurred.transformed(by: CGAffineTransform(scaleX: 1 / CGFloat(scale), y: 1 / CGFloat(scale)))
    }

    private func aspectFill(_ img: CIImage, into extent: CGRect) -> CIImage {
        let s = max(extent.width / img.extent.width, extent.height / img.extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = (scaled.extent.width - extent.width) / 2
        let dy = (scaled.extent.height - extent.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: extent)
    }

    // Trimap feather: soft alpha = smoothstep over the mask band.
    private static let featherSrc = """
    kernel vec4 feather(__sample m, float feather) {
        float v = m.r;
        float lo = max(feather * 0.5, 0.001);
        float a = smoothstep(lo, 1.0 - lo, v);
        return vec4(a, a, a, a);
    }
    """

    // Disc (bokeh) blur: uniform sampling inside a circle (optical defocus, not gaussian).
    private static let bokehSrc = """
    kernel vec4 bokeh(__sample s, float radius) {
        vec2 c = destCoord();
        vec4 acc = vec4(0.0);
        float n = 0.0;
        int r = int(radius);
        for (int y = -r; y <= r; y = y + 1) {
            for (int x = -r; x <= r; x = x + 1) {
                float d2 = float(x * x + y * y);
                if (d2 <= radius * radius) {
                    acc += sample(s, c + vec2(float(x), float(y)));
                    n += 1.0;
                }
            }
        }
        return acc / n;
    }
    """

    // Contact shadow: blurred (1 - alpha) halo, dark.
    private static let shadowSrc = """
    kernel vec4 shadow(__sample a, float radius, float strength) {
        vec2 c = destCoord();
        vec4 acc = vec4(0.0);
        float n = 0.0;
        int r = int(radius);
        for (int y = -r; y <= r; y = y + 1) {
            for (int x = -r; x <= r; x = x + 1) {
                float d2 = float(x * x + y * y);
                if (d2 <= radius * radius) {
                    acc += sample(a, c + vec2(float(x), float(y)));
                    n += 1.0;
                }
            }
        }
        float inv = 1.0 - (acc.r / n);
        return vec4(0.0, 0.0, 0.0, inv * strength);
    }
    """
}
