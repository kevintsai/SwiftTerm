//
//  NarrowedInvalidationBenchmark.swift
//
//  What narrowing the invalidation is worth, in painting time, on real captures.
//
//  Same backing-store emulation as `NarrowedInvalidationRenderTests` — one persistent bitmap context, each
//  frame only the invalidated rect painted into it — but timed instead of compared. Both arms replay the
//  same bytes and are run ALTERNATELY, because two batches run back to back measure the machine's mood as
//  much as the change.
//
//  Off by default (a measurement, not an assertion about the machine it runs on):
//      SWIFTTERM_NARROW_BENCH=1 swift test --filter NarrowedInvalidationBenchmark
//
#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import SwiftTerm

@MainActor
final class NarrowedInvalidationBenchmark: XCTestCase {
    private static let bsu: [UInt8] = Array("\u{1b}[?2026h".utf8)

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

    /// Same recorder as the render test: what the view asked for is what we paint and time.
    private final class BenchView: TerminalView {
        var invalidated: [NSRect] = []
        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidated.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    private func makeView(cols: Int, rows: Int) -> BenchView {
        let probe = BenchView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let cell = probe.cellDimension ?? CGSize(width: 8, height: 16)
        let view = BenchView(frame: CGRect(x: 0, y: 0,
                                           width: (cell.width * CGFloat(cols)).rounded(.up),
                                           height: (cell.height * CGFloat(rows)).rounded(.up)))
        view.caretView?.removeFromSuperview()
        return view
    }

    /// One arm: replay the corpus, painting only what the view asks for. Returns the painting time and the
    /// area painted, both totalled over the corpus.
    private func run(_ fixture: String, cols: Int, rows: Int, narrowing: Bool) throws -> (ms: Double, cells: Double, frames: Int) {
        let view = makeView(cols: cols, rows: rows)
        view.narrowsInvalidationToChangedRows = narrowing
        let scale = 2
        guard let store = CGContext(data: nil,
                                    width: Int(view.bounds.width) * scale,
                                    height: Int(view.bounds.height) * scale,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return (0, 0, 0) }
        store.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        func paint(_ rect: NSRect) {
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
        paint(view.bounds)

        let cellHeight = (view.cellDimension ?? CGSize(width: 8, height: 16)).height
        var nanos: UInt64 = 0
        var rowsPainted = 0.0
        let all = try frames(fixture)
        for frame in all {
            view.terminal.feed(byteArray: frame)
            view.invalidated.removeAll()
            view.updateDisplay(notifyAccessibility: false)
            let asked = view.invalidated
            let t0 = DispatchTime.now().uptimeNanoseconds
            for rect in asked {
                let clipped = rect.intersection(view.bounds)
                paint(clipped)
                rowsPainted += Double(clipped.height) / Double(cellHeight)
            }
            nanos += DispatchTime.now().uptimeNanoseconds - t0
        }
        return (Double(nanos) / 1_000_000, rowsPainted, all.count)
    }

    func testWhatNarrowingIsWorth() throws {
        guard ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_BENCH"] == "1" else { return }
        for (label, fixture, cols, rows) in [
            (ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_CORPUS"] != nil ? "實機錄音" : "spinner（等待中的 agent）", "synthetic:66",
             Int(ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_COLS"] ?? "") ?? 177,
             Int(ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_ROWS"] ?? "") ?? 66),
            ("btop（密集 TUI，最壞情況）", "btop-through-tmux-sync.raw", 200, 50),
        ] {
            var before: [Double] = []
            var after: [Double] = []
            var beforeRows = 0.0
            var afterRows = 0.0
            var frameCount = 0
            for _ in 0..<5 {
                let off = try run(fixture, cols: cols, rows: rows, narrowing: false)
                let on = try run(fixture, cols: cols, rows: rows, narrowing: true)
                before.append(off.ms); after.append(on.ms)
                beforeRows = off.cells; afterRows = on.cells; frameCount = off.frames
            }
            func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
            print(String(format: "%@：%d 幀 — 繪製 %.1f → %.1f ms（%+.0f%%）｜重畫列數 %.0f → %.0f（%.1f×）",
                         label, frameCount, median(before), median(after),
                         (median(after) / median(before) - 1) * 100,
                         beforeRows, afterRows, afterRows > 0 ? beforeRows / afterRows : 0))
        }
    }
}
#endif
