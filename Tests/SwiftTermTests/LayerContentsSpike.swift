//
//  LayerContentsSpike.swift
//
//  B2's premise, checked before anything is built on it: can a `CALayer` take an `IOSurface` as its
//  contents, and does drawing into that surface through a `CGContext` show up?
//
//  Why it matters: B1 lost in the app because AppKit's backing store does not scroll with us, so the
//  whole surface had to be drawn to the screen every frame — 6.5% of one core, more than the blit saved.
//  If the layer's contents ARE the surface, that present disappears; if they cannot be, B2 does not
//  exist and the surface work should be abandoned rather than iterated on.
//
#if os(macOS)
import AppKit
import IOSurface
import XCTest

final class LayerContentsSpike: XCTestCase {
    func testALayerCanTakeAnIOSurfaceWeDrawInto() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_B2_SPIKE"] == "1", "spike")

        let w = 64, h = 32
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: w, .height: h, .bytesPerElement: 4,
            .pixelFormat: UInt32(0x42475241),   // 'BGRA'
        ]), "IOSurface 建不出來")

        surface.lock(options: [], seed: nil)
        let ctx = CGContext(data: surface.baseAddress,
                            width: w, height: h,
                            bitsPerComponent: 8,
                            bytesPerRow: surface.bytesPerRow,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        XCTAssertNotNil(ctx, "CGContext 蓋不到 IOSurface 的 baseAddress")
        ctx?.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
        surface.unlock(options: [], seed: nil)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        let layer = try XCTUnwrap(view.layer)
        layer.contents = surface
        XCTAssertNotNil(layer.contents, "layer 沒有收下 IOSurface")

        // Read the pixels back out of the surface itself: what the compositor samples is this memory.
        surface.lock(options: .readOnly, seed: nil)
        let px = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let b = px[0], g = px[1], r = px[2]
        surface.unlock(options: .readOnly, seed: nil)

        print("""

        ── B2 premise ────────────────────────────────────────────
          IOSurface \(w)x\(h) bytesPerRow=\(surface.bytesPerRow)
          CGContext over baseAddress : \(ctx != nil ? "OK" : "FAILED")
          layer.contents accepted    : \(layer.contents != nil ? "OK" : "FAILED")
          pixel after green fill     : B=\(b) G=\(g) R=\(r)  (expect B=0 G=255 R=0)
        ──────────────────────────────────────────────────────────

        """)
        // Not 255: a DeviceRGB fill lands in the surface's own colour space, so the exact value moves.
        // What is being asserted is that our drawing reached this memory at all, and that it is green.
        XCTAssertGreaterThan(g, 200, "畫進 IOSurface 的內容沒有落在它的記憶體裡")
        XCTAssertLessThan(max(r, b), 40, "落進去的顏色不是我們畫的那個")
    }
}
#endif
