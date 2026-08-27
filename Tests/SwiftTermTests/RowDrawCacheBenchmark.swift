//
//  RowDrawCacheBenchmark.swift
//
//  What the per-row cache is worth, on real bytes, without opening a window.
//
//  Replays `Fixtures/btop-through-tmux-sync.raw` — `tmux -T sync attach` to a pane running btop at
//  200x50 — one synchronized frame at a time, and for each frame shapes exactly the rows the terminal
//  marked dirty. Two arms over identical input:
//
//    • `before` — what `drawTerminalContents` did until now: `buildAttributedString` plus
//      `CTLineCreateWithAttributedString` for every row in the dirty band, every frame.
//    • `after`  — the same rows through `rowDrawState`, which reuses a row whose key still matches.
//
//  This measures the SHAPING half only, not the CoreGraphics drawing that follows it. That is the
//  honest scope: shaping is what the cache removes, and it is where the live `sample` put the cost.
//
//  Off by default (it is a measurement, not an assertion about the machine it runs on):
//      SWIFTTERM_ROWCACHE_BENCH=1 swift test --filter RowDrawCacheBenchmark
//
//  btop is close to the worst case — a dense full-screen TUI where a large share of rows really do
//  change every frame. A mostly-static pane (a shell prompt, a paged file, an agent printing at the
//  bottom of a tall screen) does considerably better, and that is the common case in fleetmux.
//

#if os(macOS)
import AppKit
import CoreText
import Foundation
import XCTest

@testable import SwiftTerm

final class RowDrawCacheBenchmark: XCTestCase {
    private static let bsu: [UInt8] = Array("\u{1b}[?2026h".utf8)

    /// The corpus split at begin-synchronized-update markers, so each element is one tmux frame.
    ///
    /// Defaults to the committed btop capture. `SWIFTTERM_ROWCACHE_CORPUS=<path>` points it at another
    /// recording — which is how the fleetmux-shaped numbers in ADR 0043 were taken, off real panes that
    /// are not committed anywhere because they are somebody's actual terminal contents.
    private func frames() throws -> [[UInt8]] {
        let env = ProcessInfo.processInfo.environment
        let url = env["SWIFTTERM_ROWCACHE_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/btop-through-tmux-sync.raw")
        let bytes = [UInt8](try Data(contentsOf: url))
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

    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        // The capture was taken at 200x50; replay it at that size so the dirty ranges are the ones
        // tmux actually produced. Cell geometry does not enter shaping, so the view's own font
        // metrics staying where they are is fine.
        let env = ProcessInfo.processInfo.environment
        view.terminal.resize(cols: Int(env["SWIFTTERM_ROWCACHE_COLS"] ?? "") ?? 200,
                             rows: Int(env["SWIFTTERM_ROWCACHE_ROWS"] ?? "") ?? 50)
        return view
    }

    /// Replay every frame, shaping the dirty rows the way `shape` says.
    ///
    /// ⚠ **Only the shaping is timed.** `terminal.feed` — the escape parser — runs identically in both
    /// arms and is several times the cost of one row, so leaving it inside the clock would dilute the
    /// very difference being measured. (It did, in the first run of this: 21% against a corpus where
    /// the shaping arm alone is far better than that.)
    private func replay(_ view: TerminalView,
                        _ frames: [[UInt8]],
                        rounds: Int,
                        shape: (Int, BufferLine, Int) -> Void) -> (seconds: Double, rows: Int, frames: Int) {
        let terminal = view.terminal!
        var rows = 0
        var painted = 0
        var elapsed: Double = 0
        for _ in 0..<rounds {
            for frame in frames {
                terminal.feed(buffer: frame[...])
                guard let (start, end) = terminal.getUpdateRange() else { continue }
                terminal.clearUpdateRange()
                let buffer = terminal.displayBuffer
                painted += 1
                let started = ProcessInfo.processInfo.systemUptime
                for r in start...end {
                    let absolute = buffer.yDisp + r
                    guard absolute >= 0, absolute < buffer.lines.count else { continue }
                    shape(absolute, buffer.lines[absolute], buffer.cols)
                    rows += 1
                }
                elapsed += ProcessInfo.processInfo.systemUptime - started
            }
        }
        return (elapsed, rows, painted)
    }

    func testShapingCostBeforeAndAfter() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_ROWCACHE_BENCH"] == "1",
                          "measurement only; set SWIFTTERM_ROWCACHE_BENCH=1 to run")
        let corpus = try frames()
        XCTAssertGreaterThan(corpus.count, 1, "the capture must actually contain synchronized frames")
        // The capture is short, and its first frame is a cold cache in any scheme. Replaying it a few
        // times puts the steady state — which is what a pane spends its life in — in the majority.
        let rounds = Int(ProcessInfo.processInfo.environment["SWIFTTERM_ROWCACHE_ROUNDS"] ?? "") ?? 20

        // before: shape unconditionally, exactly as the old draw loop did.
        let old = makeView()
        let before = replay(old, corpus, rounds: rounds) { row, line, cols in
            let info = old.buildAttributedString(row: row, line: line, cols: cols)
            for segment in info.segments where segment.attributedString.length > 0 {
                _ = CTLineCreateWithAttributedString(segment.attributedString)
            }
        }

        // after: the same rows, through the cache. Count how many came back reused — the machine-
        // independent half of the result, and the one that says whether the key is doing its job.
        let new = makeView()
        var lastShaped: [Int: NSAttributedString] = [:]
        var hits = 0
        let after = replay(new, corpus, rounds: rounds) { row, line, cols in
            let state = new.rowDrawState(row: row, line: line, cols: cols)
            guard let head = state.info.segments.first?.attributedString else { return }
            if lastShaped[row] === head { hits += 1 }
            lastShaped[row] = head
        }

        XCTAssertEqual(before.rows, after.rows, "both arms must shape the same rows")
        let saved = (before.seconds - after.seconds) / before.seconds * 100
        print(String(format: """

            row-draw cache — %dx%d, %d frames x %d rounds, %d dirty rows shaped
              before: %8.1f ms   %.3f ms/row
              after:  %8.1f ms   %.3f ms/row
              saved:  %7.1f%%   (reused %d/%d rows = %.1f%%)

            """,
            new.terminal.cols, new.terminal.rows, corpus.count, rounds, before.rows,
            before.seconds * 1000, before.seconds * 1000 / Double(before.rows),
            after.seconds * 1000, after.seconds * 1000 / Double(after.rows),
            saved, hits, after.rows, Double(hits) / Double(after.rows) * 100))
    }
}
#endif
