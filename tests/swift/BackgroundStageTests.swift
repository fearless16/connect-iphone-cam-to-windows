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

    private var frame: CVPixelBuffer? {
        makeBuffer(width: 64, height: 64) { x, _ in
            // subject on the left half (white), background right half (blue)
            if x < 32 { return (255, 255, 255, 255) } else { return (0, 0, 255, 255) }
        }
    }

    private var mask: CVPixelBuffer? {
        makeBuffer(width: 64, height: 64) { x, _ in
            // mask 255 on subject side, 0 elsewhere
            let v: UInt8 = x < 32 ? 255 : 0
            return (v, v, v, 255)
        }
    }

    func testCompositeReturnsBGRABuffer() {
        guard let f = frame, let m = mask else { XCTFail("buffer alloc"); return }
        let stage = BackgroundStage()
        let out = stage.composite(frame: f, mask: m, params: CompositorParams())
        XCTAssertNotNil(out)
        var w = 0, h = 0
        if let out {
            CVPixelBufferGetWidth(out); w = CVPixelBufferGetWidth(out); h = CVPixelBufferGetHeight(out)
        }
        XCTAssertEqual(w, 64)
        XCTAssertEqual(h, 64)
    }

    func testCompositeBlursBackgroundRegion() {
        // Without a replacement image, the right (background) half must change
        // after bokeh, while the left (subject) half stays white.
        guard let f = frame, let m = mask else { XCTFail("buffer alloc"); return }
        let stage = BackgroundStage()
        let params = CompositorParams(bokehRadius: 16, shadowStrength: 0)
        guard let out = stage.composite(frame: f, mask: m, params: params) else { XCTFail("composite"); return }

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let base = CVPixelBufferGetBaseAddress(out)!
        let row = CVPixelBufferGetBytesPerRow(out)
        let bgPixel = base.advanced(by: 48 * row + 48 * 4).assumingMemoryBound(to: UInt8.self)
        let subjPixel = base.advanced(by: 16 * row + 16 * 4).assumingMemoryBound(to: UInt8.self)
        // subject pixel must remain bright white
        XCTAssertGreaterThan(Int(subjPixel[2]), 200, "subject should stay sharp/white")
        // background pixel should no longer be pure blue (bokeh mixed it)
        XCTAssertNotEqual(Int(bgPixel[2]), 255, "background should be blurred, not pure blue")
    }

    func testMaskScalingHandlesMismatch() {
        // mask smaller than frame must still composite without crashing
        let smallMask = makeBuffer(width: 32, height: 32) { x, _ in
            let v: UInt8 = x < 16 ? 255 : 0
            return (v, v, v, 255)
        }
        guard let f = frame, let m = smallMask else { XCTFail("alloc"); return }
        let stage = BackgroundStage()
        let out = stage.composite(frame: f, mask: m, params: CompositorParams())
        XCTAssertNotNil(out)
    }
}
