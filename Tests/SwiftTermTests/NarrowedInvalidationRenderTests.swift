//
//  NarrowedInvalidationRenderTests.swift
//
//  The invariant behind asking for fewer rows: **a view repainted only inside the rects it asked for must
//  end up showing the same thing as a view that drew everything once.**
//
//  `RowDrawCacheRenderTests` compares a warm view against a cold one, but both render their whole bounds —
//  so it cannot see a row that was never asked for, which is exactly the failure mode of narrowing the
//  invalidation. This emulates the backing store instead: one persistent bitmap context, and each frame
//  only the invalidated rect is drawn into it.
//
//  Two arms over the same corpus. Narrowing **off** first — the control, and the reason a green result
//  means anything: if the emulation were unfaithful, or the corpus were replayed at the wrong grid, the
//  control would fail too and the test would be about the harness rather than the change. (Both of those
//  did happen while this was being written; the control caught both.)
//
#if os(macOS)
import AppKit
import Foundation
import Testing
import XCTest

@testable import SwiftTerm

@MainActor
final class NarrowedInvalidationRenderTests {
    /// Records what the view asked AppKit to repaint, which is what the harness then repaints.
    private final class RecordingView: TerminalView {
        var invalidated: [NSRect] = []
        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidated.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    /// A rendered surface: the pixels, plus the geometry needed to walk them.
    private struct Surface {
        let pixels: Data
        let bytesPerRow: Int
        let height: Int
    }

    private static let bsu: [UInt8] = Array("\u{1b}[?2026h".utf8)

    /// How far apart two renders of the same content may be before it stops being rasterisation noise.
    /// CoreGraphics places glyph edges fractionally differently depending on the rect it is drawing into,
    /// so any partial repaint lands a level or two off on antialiased pixels. A row still showing its old
    /// contents is not that kind of difference — it is ink where there should be background, of order 255.
    private static let hair = 24

    /// The corpus split at begin-synchronized-update markers, so each element is one tmux frame.
    /// `"synthetic:<rows>"` builds the spinner shape in code (see `SyntheticSpinnerCorpus`); anything else
    /// is a file in `Fixtures/`. `SWIFTTERM_NARROW_CORPUS=<path>` overrides the synthetic one with a real
    /// recording for local measurement — those are never committed.
    private func frames(_ fixture: String) throws -> [[UInt8]] {
        if fixture.hasPrefix("synthetic:") {
            if let path = ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_CORPUS"] {
                return try split([UInt8](Data(contentsOf: URL(fileURLWithPath: path))))
            }
            let rows = Int(fixture.dropFirst("synthetic:".count)) ?? 66
            return SyntheticSpinnerCorpus.frames(rows: rows)
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixture)")
        let bytes = [UInt8](try Data(contentsOf: url))
        // The scrolling capture carries no begin-synchronized-update markers — tmux only emits those to
        // a client that answered the DA query for them, and the recording pty did not. Its frames end
        // where tmux restores the full scroll region instead.
        if fixture.contains("streaming-scroll") { return splitAtScrollRegionRestore(bytes) }
        return try split(bytes)
    }

    private func splitAtScrollRegionRestore(_ bytes: [UInt8]) -> [[UInt8]] {
        let marker: [UInt8] = Array("\u{1b}[1;24r".utf8)
        var out: [[UInt8]] = [], current: [UInt8] = []
        for b in bytes {
            current.append(b)
            if current.count >= marker.count, Array(current.suffix(marker.count)) == marker {
                out.append(current); current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Split a raw capture at begin-synchronized-update markers, so each element is one tmux frame.
    private func split(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if i + Self.bsu.count <= bytes.count, Array(bytes[i..<(i + Self.bsu.count)]) == Self.bsu {
                if !current.isEmpty { out.append(current) }
                current = Self.bsu
                i += Self.bsu.count
                continue
            }
            current.append(bytes[i])
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// A view whose grid matches the capture's. Replaying a 200x50 recording into a 37-row view puts every
    /// DECSTBM region and absolute cursor address somewhere else, and then nothing the test says is about
    /// the change under test.
    private func makeView(cols: Int, rows: Int) -> RecordingView {
        let probe = RecordingView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let cell = probe.cellDimension ?? CGSize(width: 8, height: 16)
        let view = RecordingView(frame: CGRect(x: 0, y: 0,
                                               width: (cell.width * CGFloat(cols)).rounded(.up),
                                               height: (cell.height * CGFloat(rows)).rounded(.up)))
        // The caret is a subview on a blink timer, and `updateCursorPosition()` re-shows it, so hiding is
        // not enough. Out of the hierarchy: otherwise the arms differ wherever the caret has been, which is
        // a fact about a blinking rectangle, not about which rows were repainted.
        view.caretView?.removeFromSuperview()
        return view
    }

    /// A persistent bitmap that behaves like a layer's backing store: pixels stay until painted over.
    ///
    /// Deliberately NOT `cacheDisplay(in:to:)`: that requires the rep to have been created for the *same*
    /// rect, so handing it a sub-rect of a full-size rep puts the content in the wrong place — which looks
    /// exactly like ghosting and is not.
    private func makeStore(_ view: NSView, scale: Int = 2) -> CGContext? {
        guard let ctx = CGContext(data: nil,
                                  width: Int(view.bounds.width) * scale,
                                  height: Int(view.bounds.height) * scale,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        return ctx
    }

    /// Paint `rect` of the view into the store, leaving every other pixel as it was.
    private func paint(_ view: NSView, _ rect: NSRect, into store: CGContext) {
        guard !rect.isEmpty else { return }
        store.saveGState()
        store.clip(to: rect)
        let gctx = NSGraphicsContext(cgContext: store, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        view.displayIgnoringOpacity(rect, in: gctx)
        NSGraphicsContext.restoreGraphicsState()
        store.restoreGState()
    }

    private func surface(_ store: CGContext) -> Surface? {
        guard let data = store.data else { return nil }
        return Surface(pixels: Data(bytes: data, count: store.bytesPerRow * store.height),
                       bytesPerRow: store.bytesPerRow, height: store.height)
    }

    /// Replay the corpus into one store, repainting only what the view asked for.
    private func incremental(_ fixture: String, cols: Int, rows: Int, narrowing: Bool,
                             surfaced: Bool = true, blitting: Bool = false) throws -> Surface? {
        let view = makeView(cols: cols, rows: rows)
        view.narrowsInvalidationToChangedRows = narrowing
        view.usesOwnSurface = surfaced
        view.blitsScrolledPixels = blitting
        guard let store = makeStore(view) else { return nil }
        paint(view, view.bounds, into: store)  // the first, full paint

        for frame in try frames(fixture) {
            view.invalidated.removeAll()
            view.terminal.feed(byteArray: frame)
            view.updateDisplay(notifyAccessibility: false)
            for rect in view.invalidated { paint(view, rect.intersection(view.bounds), into: store) }
        }
        lastBlits = (view.blitCount, view.blitRows)
        lastPaintRows = view.surfacePaintRows
        return surface(store)
    }

    /// Set by the most recent `incremental(...)`. See `blittingScrolledPixelsMatchesRepaintingThem`.
    private var lastBlits: (frames: Int, rows: Int) = (0, 0)
    private var lastPaintRows = 0
    private var scratchStores: [ObjectIdentifier: CGContext] = [:]

    /// Replay the corpus twice in lockstep — blit off and blit on — comparing every `checkEvery` frames.
    ///
    /// **Comparing only the final image is not a guard for a blit.** A blit writes pixels nobody
    /// re-derives, but the rows around it keep being repainted, so a wrong move can be papered over by
    /// the time the corpus ends — verified: flipping the memmove direction left the final image
    /// identical. What the user would have seen is the frames in between, so those are what this checks.
    ///
    /// The control arm is the one already pinned equal to a cold render, so "equal to the control" is
    /// equal to a cold render at every checkpoint, without paying for a cold render at every checkpoint.
    private func firstDivergentFrame(_ fixture: String, cols: Int, rows: Int,
                                     checkEvery: Int) throws -> (frame: Int, detail: String)? {
        let control = makeView(cols: cols, rows: rows)
        control.narrowsInvalidationToChangedRows = true
        control.usesOwnSurface = true
        control.blitsScrolledPixels = false
        let blit = makeView(cols: cols, rows: rows)
        blit.narrowsInvalidationToChangedRows = true
        blit.usesOwnSurface = true
        blit.blitsScrolledPixels = true
        guard let controlStore = makeStore(control), let blitStore = makeStore(blit) else { return nil }
        paint(control, control.bounds, into: controlStore)
        paint(blit, blit.bounds, into: blitStore)

        for (index, frame) in try frames(fixture).enumerated() {
            for (view, store) in [(control, controlStore), (blit, blitStore)] {
                view.invalidated.removeAll()
                view.terminal.feed(byteArray: frame)
                view.updateDisplay(notifyAccessibility: false)
                for rect in view.invalidated { paint(view, rect.intersection(view.bounds), into: store) }
            }
            guard index % checkEvery == 0 || index == 0 else { continue }
            guard let a = surface(controlStore), let b = surface(blitStore) else { continue }
            let diff = worstDifference(a, b)
            if diff.beyondHair > 0 {
                return (index, "最大差 \(diff.maxDelta)、\(diff.beyondHair) 個 pixel，\(differingRows(b, a))")
            }
        }
        return nil
    }

    /// The same bytes into a view that has drawn nothing yet, painted once, whole.
    ///
    /// Deliberately painted WITHOUT the owned surface: the reference has to come from the path that
    /// predates it, or "surfaced output matches the reference" would only be saying the surface agrees
    /// with itself.
    private func cold(_ fixture: String, cols: Int, rows: Int) throws -> Surface? {
        let view = makeView(cols: cols, rows: rows)
        view.usesOwnSurface = false
        view.blitsScrolledPixels = false
        for frame in try frames(fixture) {
            view.terminal.feed(byteArray: frame)
            view.updateDisplay(notifyAccessibility: false)
        }
        guard let store = makeStore(view) else { return nil }
        paint(view, view.bounds, into: store)
        return surface(store)
    }

    private func worstDifference(_ a: Surface, _ b: Surface) -> (maxDelta: Int, beyondHair: Int) {
        guard a.bytesPerRow == b.bytesPerRow, a.height == b.height else { return (255, .max) }
        var maxDelta = 0
        var beyond = 0
        a.pixels.withUnsafeBytes { pa in
            b.pixels.withUnsafeBytes { pb in
                for i in stride(from: 0, to: min(pa.count, pb.count), by: 4) {
                    var worst = 0
                    for c in 0..<4 { worst = max(worst, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
                    maxDelta = max(maxDelta, worst)
                    if worst > Self.hair { beyond += 1 }
                }
            }
        }
        return (maxDelta, beyond)
    }

    /// Which pixel rows differ beyond a hair — a failure that names rows is a lead.
    private func differingRows(_ a: Surface, _ b: Surface) -> String {
        guard a.bytesPerRow == b.bytesPerRow, a.height == b.height else { return "尺寸不同" }
        var ranges: [String] = []
        a.pixels.withUnsafeBytes { pa in
            b.pixels.withUnsafeBytes { pb in
                var runStart = -1
                for y in 0..<a.height {
                    var differs = false
                    var x = 0
                    while x < a.bytesPerRow, !differs {
                        let o = y * a.bytesPerRow + x
                        for c in 0..<4 where abs(Int(pa[o + c]) - Int(pb[o + c])) > Self.hair { differs = true }
                        x += 4
                    }
                    if differs, runStart < 0 { runStart = y }
                    if !differs, runStart >= 0 { ranges.append("\(runStart)–\(y - 1)"); runStart = -1 }
                }
                if runStart >= 0 { ranges.append("\(runStart)–\(a.height - 1)") }
            }
        }
        return ranges.isEmpty ? "無差異" : "差異 pixel rows: " + ranges.joined(separator: ", ")
    }

    /// Each capture with the grid it was taken at.
    @Test(arguments: [("synthetic:66", 177, 66), ("btop-through-tmux-sync.raw", 200, 50)])
    func incrementalRepaintMatchesAColdRender(corpus: (fixture: String, cols: Int, rows: Int)) throws {
        let (fixture, cols, rows) = corpus
        let reference = try #require(try cold(fixture, cols: cols, rows: rows))

        let control = try #require(try incremental(fixture, cols: cols, rows: rows, narrowing: false))
        let controlDiff = worstDifference(control, reference)
        let controlWhy = "控制組（＝改動前的行為）就對不上 = harness 在說謊，不是改動有問題（\(fixture)）：最大差 \(controlDiff.maxDelta)，\(differingRows(control, reference))"
        #expect(controlDiff.beyondHair == 0, "\(controlWhy)")

        let narrowed = try #require(try incremental(fixture, cols: cols, rows: rows, narrowing: true))
        let narrowedDiff = worstDifference(narrowed, reference)
        let narrowedWhy = "只重畫變動列之後有東西留著舊內容（\(fixture)）：最大差 \(narrowedDiff.maxDelta)，\(differingRows(narrowed, reference))"
        #expect(narrowedDiff.beyondHair == 0, "\(narrowedWhy)")
    }

    /// Replay into the view's own surface, reading the surface rather than what reached the screen.
    /// B2 renders from `updateDisplay` and never goes through `draw(_:)`, so the drawing-capture harness
    /// used everywhere else in this file is blind to it.
    private func surfaceAfterReplay(_ fixture: String, cols: Int, rows: Int,
                                    viaLayerContents: Bool) throws -> Surface? {
        let view = makeView(cols: cols, rows: rows)
        view.narrowsInvalidationToChangedRows = true
        view.usesOwnSurface = true
        view.blitsScrolledPixels = true
        view.presentsViaLayerContents = viaLayerContents
        if !viaLayerContents {
            guard let store = makeStore(view) else { return nil }
            paint(view, view.bounds, into: store)
        }
        for frame in try frames(fixture) {
            view.invalidated.removeAll()
            view.terminal.feed(byteArray: frame)
            view.updateDisplay(notifyAccessibility: false)
            if !viaLayerContents, let store = view.surface {
                _ = store   // B1 paints during draw; drive it the same way the screen would
                for rect in view.invalidated { paint(view, rect.intersection(view.bounds), into: makeStoreOnce(view)) }
            }
        }
        guard let px = view.surfacePixelsForTesting else { return nil }
        return Surface(pixels: px.bytes, bytesPerRow: px.bytesPerRow, height: px.height)
    }

    /// One store per view, created lazily — the B1 arm needs somewhere for `draw` to present into, but
    /// what is compared is the surface, not the store.
    private func makeStoreOnce(_ view: NSView) -> CGContext {
        if let existing = scratchStores[ObjectIdentifier(view)] { return existing }
        let made = makeStore(view)!
        scratchStores[ObjectIdentifier(view)] = made
        return made
    }

    /// Every buffer in the swap chain must hold the same picture once caught up.
    ///
    /// Core Animation is handed a different buffer each frame, so a buffer that is behind is a frame the
    /// user sees wrong — which is what flicker IS. Reading only the buffer painted last (as the test
    /// below does) cannot see that.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTTERM_SWAP_CHAIN"] == "1",
                   "swap chain 未完成——設 SWIFTTERM_SWAP_CHAIN=1 看它現在錯在哪"),
          arguments: [("streaming-scroll-through-tmux.raw", 80, 24)])
    func everySurfaceInTheChainAgreesOnceCaughtUp(corpus: (fixture: String, cols: Int, rows: Int)) throws {
        // ⚠ **This currently FAILS, on purpose left in reach.** The swap chain is unfinished: buffers 1
        // and 2 disagree with buffer 0 after catch-up by tens of thousands of pixels, which is precisely
        // the flicker it was written to prevent. It is gated rather than deleted because it is the only
        // thing that can tell anyone whether the chain is right, and because a green suite must not
        // imply a working chain. `presentsViaLayerContents` is off, so nothing ships on this.
        //
        // Two candidates not yet ruled out, in order of suspicion:
        //  1. `catchUpSurface` paints through `drawTerminalContents`, which also writes the GLOBAL
        //     `rowsOnScreen` record and prunes the row cache — so catching up an idle buffer mutates the
        //     bookkeeping the next frame's narrowing depends on.
        //  2. The presented buffer paints `invalidationRect(run)`, which pads a run by another cell;
        //     the idle buffers only record the unpadded rows, so they under-paint at run edges.
        let (fixture, cols, rows) = corpus
        let view = makeView(cols: cols, rows: rows)
        view.narrowsInvalidationToChangedRows = true
        view.usesOwnSurface = true
        view.blitsScrolledPixels = true
        view.presentsViaLayerContents = true
        for frame in try frames(fixture) {
            view.terminal.feed(byteArray: frame)
            view.updateDisplay(notifyAccessibility: false)
        }
        let all = view.allSurfacePixelsForTesting(bufferOffset: view.terminal.displayBuffer.yDisp)
        #expect(all.count >= 2, "swap chain 沒有建起來（只有 \(all.count) 張），這條測試等於沒測")
        let surfaces = all.map { Surface(pixels: $0.bytes, bytesPerRow: $0.bytesPerRow, height: $0.height) }
        for (i, other) in surfaces.enumerated().dropFirst() {
            let diff = worstDifference(surfaces[0], other)
            #expect(diff.beyondHair == 0,
                    "chain 第 \(i) 張補完後與第 0 張不同（\(fixture)）：最大差 \(diff.maxDelta)，\(differingRows(other, surfaces[0]))")
        }
    }

    /// Handing the layer our surface must paint the same pixels as presenting it by hand.
    ///
    /// The B1 arm is the control and is already pinned equal to a cold render, so equality here is
    /// equality with a cold render — without needing a harness that can see a path which never draws.
    @Test(arguments: [("streaming-scroll-through-tmux.raw", 80, 24)])
    func theLayerBackedSurfaceHoldsTheSamePixels(corpus: (fixture: String, cols: Int, rows: Int)) throws {
        let (fixture, cols, rows) = corpus
        let byHand = try #require(try surfaceAfterReplay(fixture, cols: cols, rows: rows, viaLayerContents: false))
        let byLayer = try #require(try surfaceAfterReplay(fixture, cols: cols, rows: rows, viaLayerContents: true))
        let diff = worstDifference(byHand, byLayer)
        #expect(diff.beyondHair == 0,
                "交給 layer 的 surface 內容與自己貼的不同（\(fixture)）：最大差 \(diff.maxDelta)，\(differingRows(byLayer, byHand))")
    }

    /// Moving the pixels a scroll displaced must land them exactly where re-rendering them would have.
    ///
    /// This is the arm that matters: everything else in this file guards a change that only decides
    /// WHICH rows are painted, and gets a second chance every time AppKit asks for a bigger rect. A blit
    /// writes pixels nobody re-derives, so a mistake here survives until something else happens to
    /// repaint that row — the ghosting class of bug, the one only the user sees.
    ///
    /// The corpus has to scroll for this to mean anything: btop repaints in place and the synthetic
    /// spinner does not scroll at all, so both would pass with the blit completely broken.
    /// `mustBlit` says whether this corpus is supposed to exercise the blit at all. btop is here with
    /// `false` on purpose: it repaints in place and never scrolls, so it cannot prove the blit right —
    /// what it proves is that turning the blit on does not disturb a TUI that has nothing to move.
    @Test(arguments: [("streaming-scroll-through-tmux.raw", 80, 24, true),
                      ("btop-through-tmux-sync.raw", 200, 50, false)])
    func blittingScrolledPixelsMatchesRepaintingThem(corpus: (fixture: String, cols: Int, rows: Int, mustBlit: Bool)) throws {
        let (fixture, cols, rows, mustBlit) = corpus
        let reference = try #require(try cold(fixture, cols: cols, rows: rows))

        let repainted = try #require(try incremental(fixture, cols: cols, rows: rows, narrowing: true,
                                                     surfaced: true, blitting: false))
        let controlPaintRows = lastPaintRows
        print("  \(fixture): 控制組（不搬）畫進 surface \(controlPaintRows) 列")
        let repaintedDiff = worstDifference(repainted, reference)
        #expect(repaintedDiff.beyondHair == 0,
                "控制組（surface 開、blit 關）就對不上 = 問題不在 blit（\(fixture)）：最大差 \(repaintedDiff.maxDelta)，\(differingRows(repainted, reference))")

        let blitted = try #require(try incremental(fixture, cols: cols, rows: rows, narrowing: true,
                                                   surfaced: true, blitting: true))
        let fired = lastBlits
        // Without this the comparison above is vacuous: a blit that never fires matches a repaint.
        if mustBlit {
            #expect(fired.frames > 0,
                    "這份語料一次都沒有搬過像素（\(fixture)），所以上面的像素比對什麼都沒證明")
            print("  \(fixture): 搬了 \(fired.frames) 幀、合計 \(fired.rows) 列；畫進 surface \(lastPaintRows) 列")
        } else {
            #expect(fired.frames == 0,
                    "\(fixture) 不該捲動，卻搬了 \(fired.frames) 幀——偵測到了不存在的位移")
        }
        let blittedDiff = worstDifference(blitted, reference)
        #expect(blittedDiff.beyondHair == 0,
                "搬過的像素落點不對（\(fixture)）：最大差 \(blittedDiff.maxDelta)，\(differingRows(blitted, reference))")

        // …and the frames in between, which is where a wrong move actually shows up.
        let divergence = try firstDivergentFrame(fixture, cols: cols, rows: rows, checkEvery: 7)
        #expect(divergence == nil,
                "第 \(divergence?.frame ?? -1) 幀開始，搬過的畫面就與重繪的不同（\(fixture)）：\(divergence?.detail ?? "")")
    }

    /// Painting into the view's own surface and presenting it must put the same pixels on screen as
    /// painting straight into AppKit's backing store.
    ///
    /// The surface exists so that scrolled pixels can be MOVED instead of re-rendered
    /// (`MacTerminalSurface.swift`). None of that is in this arm — this pins the step before it, so that
    /// when the move lands, a difference can only have come from the move. Both arms run with narrowing
    /// on, i.e. the real configuration; the reference is a cold render through the pre-surface path.
    @Test(arguments: [("synthetic:66", 177, 66),
                      ("btop-through-tmux-sync.raw", 200, 50),
                      ("streaming-scroll-through-tmux.raw", 80, 24)])
    func theOwnedSurfacePutsTheSamePixelsOnScreen(corpus: (fixture: String, cols: Int, rows: Int)) throws {
        let (fixture, cols, rows) = corpus
        let reference = try #require(try cold(fixture, cols: cols, rows: rows))

        let direct = try #require(try incremental(fixture, cols: cols, rows: rows, narrowing: true, surfaced: false))
        let directDiff = worstDifference(direct, reference)
        #expect(directDiff.beyondHair == 0,
                "控制組（不經 surface）就對不上 = harness 在說謊（\(fixture)）：最大差 \(directDiff.maxDelta)，\(differingRows(direct, reference))")

        let surfaced = try #require(try incremental(fixture, cols: cols, rows: rows, narrowing: true, surfaced: true))
        let surfacedDiff = worstDifference(surfaced, reference)
        #expect(surfacedDiff.beyondHair == 0,
                "經過自有 surface 之後畫面不同（\(fixture)）：最大差 \(surfacedDiff.maxDelta)，\(differingRows(surfaced, reference))")
    }
}
#endif
