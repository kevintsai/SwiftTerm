//
//  SurfacePixelFormatTests.swift
//
//  Which pixel format the owned surface uses is not a detail: CoreGraphics has fast paths only for the
//  host-native layout, and falls back to software for anything else. The first cut of the surface asked
//  for `premultipliedFirst` with no byte-order flag — big-endian ARGB — and the app got SLOWER despite
//  painting 83% fewer rows, with `CGBlt_fillBytes` the hottest thing in the profile.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class SurfacePixelFormatTests: XCTestCase {
    private func store(_ view: NSView, _ info: UInt32) -> CGContext? {
        guard let ctx = CGContext(data: nil,
                                  width: Int(view.bounds.width) * 2,
                                  height: Int(view.bounds.height) * 2,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        return ctx
    }

    private func time(_ view: TerminalView, _ ctx: CGContext, rounds: Int) -> Double {
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<rounds {
            let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gctx
            view.drawTerminalContents(dirtyRect: view.bounds, context: ctx,
                                      bufferOffset: view.terminal.displayBuffer.yDisp)
            NSGraphicsContext.restoreGraphicsState()
        }
        return ProcessInfo.processInfo.systemUptime - started
    }

    func testHostNativeFormatIsWorthMeasuring() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_FORMAT_BENCH"] == "1",
                          "measurement only; set SWIFTTERM_FORMAT_BENCH=1 to run")
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 384))
        let t: Terminal = view.terminal
        t.resize(cols: 80, rows: 24)
        for i in 0..<24 { t.feed(text: "row \(i) lorem ipsum dolor sit amet consectetur adipiscing\r\n") }

        let nonNative = CGImageAlphaInfo.premultipliedFirst.rawValue
        let native = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let a = store(view, nonNative), let b = store(view, native) else { throw XCTSkip("no context") }

        let rounds = 200
        _ = time(view, a, rounds: 10); _ = time(view, b, rounds: 10)   // warm
        var aTimes: [Double] = [], bTimes: [Double] = []
        for _ in 0..<5 {
            aTimes.append(time(view, a, rounds: rounds) * 1000)
            bTimes.append(time(view, b, rounds: rounds) * 1000)
        }
        aTimes.sort(); bTimes.sort()
        let am = aTimes[2], bm = bTimes[2]
        print(String(format: """

        ── painting %d full frames into the surface ──────────────────
          ARGB big-endian (what shipped) : %8.1f ms
          BGRA host-native               : %8.1f ms
          native is %.2fx the speed
        ──────────────────────────────────────────────────────────────

        """, rounds, am, bm, am / bm))
    }
}
#endif
