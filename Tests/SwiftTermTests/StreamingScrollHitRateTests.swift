//
//  StreamingScrollHitRateTests.swift
//
//  How often the row shaping cache actually hits while a pane is streaming — the one number a
//  sampling profiler cannot produce. `sample` says where the time goes, and hits are cheap, so a
//  profile can show "nearly all the time inside `rowDrawState` is spent rebuilding" while the rows
//  being rebuilt are a small minority. Only a counter separates those two stories.
//
//  The corpus is a real tmux client stream (`Fixtures/streaming-scroll-through-tmux.raw`, 80x24,
//  captured 2026-09-09 off an isolated `fm-probe-*` server running a producer shaped like a CLI
//  agent: a transcript that scrolls line by line plus a status line that is rewritten in place).
//  It is the scrolling counterpart the other fixtures lack — btop never scrolls, and a corpus that
//  does not scroll cannot exercise the case the app spends its life in.
//
//  What it replays is the draw loop, not just the shaping: dirty band -> `visuallyChangedRowRuns` ->
//  shape every row inside each run -> `noteRowsOnScreen`. Sampling the shaping alone would answer a
//  question the app never asks.
//

#if os(macOS)
import AppKit
import CoreText
import Foundation
import XCTest

@testable import SwiftTerm

@MainActor
final class StreamingScrollHitRateTests: XCTestCase {
    /// tmux ends each update by restoring the full scroll region; that is the frame boundary here.
    /// (This capture carries no begin-synchronized-update markers — tmux only emits those to a client
    /// that answered the DA query for them, and the recording pty did not.)
    private static let frameEnd: [UInt8] = Array("\u{1b}[1;24r".utf8)

    private func frames() throws -> [[UInt8]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/streaming-scroll-through-tmux.raw")
        let bytes = [UInt8](try Data(contentsOf: url))
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        while i < bytes.count {
            current.append(bytes[i])
            if current.count >= Self.frameEnd.count,
               Array(current.suffix(Self.frameEnd.count)) == Self.frameEnd {
                out.append(current)
                current = []
            }
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private struct Result {
        var draws = 0
        var rowsShaped = 0
        var hits = 0
        var misses = 0
        var rebuiltIdentical = 0
        var hitRate: Double { rowsShaped == 0 ? 0 : Double(hits) / Double(rowsShaped) * 100 }
    }

    /// Replay the corpus the way the view draws it.
    ///
    /// `coalesce` is how many tmux updates land between two draws. The app does not draw once per
    /// update — it draws on a display cycle, so several updates accumulate first, and a draw that
    /// covers more updates sees more genuinely-changed rows. Measuring only `coalesce: 1` would
    /// flatter the cache.
    private func replay(coalesce: Int) throws -> Result {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let terminal: Terminal = view.terminal
        terminal.resize(cols: 80, rows: 24)
        view.resetRowDrawCacheStatsForTesting()

        var result = Result()
        // What each screen row's shaped text was last time we drew it, so a rebuild that produced the
        // same glyphs again can be told apart from one that produced different glyphs. The first is
        // waste; the second is the cache doing its job.
        var lastText: [Int: String] = [:]

        var pending = 0
        for frame in try frames() {
            terminal.feed(buffer: frame[...])
            pending += 1
            guard pending >= coalesce else { continue }
            pending = 0

            guard let (start, end) = terminal.getUpdateRange() else { continue }
            terminal.clearUpdateRange()
            guard let runs = view.visuallyChangedRowRuns(rowStart: start, rowEnd: end) else { continue }
            result.draws += 1

            let buffer = terminal.displayBuffer
            for run in runs {
                for y in run {
                    let absolute = buffer.yDisp + y
                    guard absolute >= 0, absolute < buffer.lines.count else { continue }
                    let line = buffer.lines[absolute]
                    let before = view.rowDrawCacheStatsForTesting
                    let state = view.rowDrawState(row: absolute, line: line, cols: terminal.cols)
                    let after = view.rowDrawCacheStatsForTesting
                    result.rowsShaped += 1
                    let text = state.info.segments.map { $0.attributedString.string }.joined()
                    if after.misses > before.misses {
                        if lastText[y] == text { result.rebuiltIdentical += 1 }
                    }
                    lastText[y] = text
                }
                let lo = buffer.yDisp + run.lowerBound
                let hi = buffer.yDisp + run.upperBound
                if lo <= hi { view.noteRowsOnScreen(rows: lo...hi, bufferOffset: buffer.yDisp) }
            }
            let visibleTop = max(0, buffer.yDisp)
            let visibleBottom = min(buffer.lines.count - 1, buffer.yDisp + terminal.rows - 1)
            view.pruneRowDrawCache(visible: visibleTop <= visibleBottom ? visibleTop...visibleBottom : nil)
        }
        let stats = view.rowDrawCacheStatsForTesting
        result.hits = stats.hits
        result.misses = stats.misses
        return result
    }

    func testHitRateWhileStreaming() throws {
        var lines: [String] = []
        var rates: [Int: Double] = [:]
        for coalesce in [1, 3, 5] {
            let r = try replay(coalesce: coalesce)
            rates[coalesce] = r.hitRate
            lines.append(String(format:
                "  %2d update(s)/draw : %5d draws, %6d rows shaped (%4.1f rows/draw), hit %5.1f%%  (miss %d, of which %d produced identical text)",
                coalesce, r.draws, r.rowsShaped,
                Double(r.rowsShaped) / Double(max(r.draws, 1)), r.hitRate, r.misses, r.rebuiltIdentical))
        }
        print("\nrow shaping cache on a streaming 80x24 pane (real tmux capture)\n" + lines.joined(separator: "\n") + "\n")

        // The regression this pins: the cache must keep working ACROSS scrolls. Keyed by row number it
        // scored 0% here (see RowDrawCacheScrollTests for the mechanism); keyed by the line, a scroll
        // only genuinely changes the row that was rewritten plus the status line.
        for (coalesce, rate) in rates.sorted(by: { $0.key < $1.key }) {
            XCTAssertGreaterThan(rate, 50.0,
                                 "hit rate collapsed to \(String(format: "%.1f", rate))% at \(coalesce) update(s)/draw")
        }
    }
}
#endif
