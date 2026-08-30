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
        return try split([UInt8](Data(contentsOf: url)))
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
    private func incremental(_ fixture: String, cols: Int, rows: Int, narrowing: Bool) throws -> Surface? {
        let view = makeView(cols: cols, rows: rows)
        view.narrowsInvalidationToChangedRows = narrowing
        guard let store = makeStore(view) else { return nil }
        paint(view, view.bounds, into: store)  // the first, full paint

        for frame in try frames(fixture) {
            view.invalidated.removeAll()
            view.terminal.feed(byteArray: frame)
            view.updateDisplay(notifyAccessibility: false)
            for rect in view.invalidated { paint(view, rect.intersection(view.bounds), into: store) }
        }
        return surface(store)
    }

    /// The same bytes into a view that has drawn nothing yet, painted once, whole.
    private func cold(_ fixture: String, cols: Int, rows: Int) throws -> Surface? {
        let view = makeView(cols: cols, rows: rows)
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
}
#endif
