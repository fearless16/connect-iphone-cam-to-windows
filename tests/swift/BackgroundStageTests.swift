import CoreImage
import CoreVideo
import XCTest

@testable import ProtocolCore

final class BackgroundStageTests: XCTestCase {
    private func makeBuffer(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buf) == kCVReturnSuccess,
              let b = buf else { return nil }
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        guard let base = CVPixelBufferGetBaseAddress(b) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, bl, a) = fill(x, y)
                let p = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
                p[0] = bl; p[1] = g; p[2] = r; p[3] = a
            }
        }
        return b
    }

    // Subject = white left half; background = horizontal blue->red gradient.
    private var frame: CVPixelBuffer? {
        makeBuffer(width: 64, height: 64) { x, _ in
            if x < 32 { return (255, 255, 255, 255) }
            let t = Float(x - 32) / 31.0
            return (UInt8(t * 255), 0, UInt8((1 - t) * 255), 255)
        }
    }

    private var mask: CVPixelBuffer? {
        makeBuffer(width: 64, height: 64) { x, _ in
            let v: UInt8 = x < 32 ? 255 : 0
            return (v, v, v, 255)
        }
    }

    private func pixel(_ buf: CVPixelBuffer, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
        let row = CVPixelBufferGetBytesPerRow(buf)
        let p = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
        return (p[2], p[1], p[0], p[3])
    }

    func testCompositeReturnsBGRABuffer() {
        guard let f = frame, let m = mask else { XCTFail("buffer alloc"); return }
        let stage = BackgroundStage()
        guard let out = stage.composite(frame: f, mask: m, params: CompositorParams()) else {
            XCTFail("composite returned nil"); return
        }
        XCTAssertEqual(CVPixelBufferGetWidth(out), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 64)
    }

    func testSubjectStaysSharpAndBackgroundIsBlurred() {
        guard let f = frame, let m = mask else { XCTFail("buffer alloc"); return }
        let stage = BackgroundStage()
        // Full-res bokeh so the assertion is unambiguous.
        let params = CompositorParams(bokehRadius: 16, shadowStrength: 0, backgroundScale: 1)
        guard let out = stage.composite(frame: f, mask: m, params: params) else { XCTFail("composite"); return }

        // Subject pixel (left, mask=255) must remain bright white.
        let subj = pixel(out, x: 16, y: 16)
        XCTAssertGreaterThan(Int(subj.0), 200, "subject should stay sharp/white, got \(subj)")

        // Background pixel (right, mask=0): bokeh mixes the gradient neighbours,
        // so the composited value must differ from the original frame pixel.
        let original = pixel(f, x: 48, y: 48)
        let composited = pixel(out, x: 48, y: 48)
        XCTAssertNotEqual(composited.0, original.0, "background should be blurred, not original")
        XCTAssertNotEqual(composited.2, original.2, "background should be blurred, not original")
    }

    func testSoftEdgeFeathering() {
        // At the mask boundary, feathering yields an intermediate (not hard) alpha,
        // so a pixel just inside the boundary is neither pure subject nor pure bg.
        guard let f = frame, let m = mask else { XCTFail("buffer alloc"); return }
        let stage = BackgroundStage()
        let params = CompositorParams(feather: 0.4, bokehRadius: 8, shadowStrength: 0, backgroundScale: 1)
        guard let out = stage.composite(frame: f, mask: m, params: params) else { XCTFail("composite"); return }
        // x=33 is just inside the background side of the boundary; with feather=0.4 the
        // alpha is partial, so the pixel is a blend, not pure gradient colour.
        let px = pixel(out, x: 33, y: 32)
        XCTAssertLessThan(Int(px.0), 250, "boundary pixel should be feathered, not hard-cut: \(px)")
    }

    func testMaskScalingHandlesMismatch() {
        let smallMask = makeBuffer(width: 32, height: 32) { x, _ in
            let v: UInt8 = x < 16 ? 255 : 0
            return (v, v, v, 255)
        }
        guard let f = frame, let m = smallMask else { XCTFail("alloc"); return }
        let stage = BackgroundStage()
        XCTAssertNotNil(stage.composite(frame: f, mask: m, params: CompositorParams()))
    }
}
