//
//  DirtyBandProbe.swift
//
//  How much of the dirty band actually changed.
//
//  `getUpdateRange()` returns ONE contiguous range, and moving the cursor marks every row between its old
//  and new position (`SyncDirtyRangeTests` documents that). A tmux frame that changes one spinner glyph
//  therefore hands the view a band covering everything the cursor flew over. The view then clears and
//  repaints that whole band — and the AppKit/CoreAnimation cost of a repaint scales with its AREA, not
//  with how many cells differ.
//
//  This probe measures the gap between the two, per frame, on real captures:
//    • band rows    — what the view repaints today
//    • changed rows — rows whose `BufferLine` (identity + generation) is not what it was last frame
//
//  Off by default (a measurement, not an assertion about a machine):
//      SWIFTTERM_DIRTYBAND_PROBE=1 swift test --filter DirtyBandProbe
//
#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class DirtyBandProbe: XCTestCase {
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

    /// Identity + generation, the same pair the row draw cache keys on (ADR 0043 D1) — the reference has to
    /// be part of it because scrolling rotates a `CircularList`, so one screen row can get a different
    /// `BufferLine` whose generation happens to match.
    private struct RowKey: Equatable {
        let line: ObjectIdentifier
        let generation: UInt64
    }

    func testHowMuchOfTheBandActuallyChanged() throws {
        guard ProcessInfo.processInfo.environment["SWIFTTERM_DIRTYBAND_PROBE"] == "1" else { return }

        for (label, fixture, cols, rows) in [
            (ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_CORPUS"] != nil ? "實機錄音" : "spinner (claude 等待中)", "synthetic:66",
             Int(ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_COLS"] ?? "") ?? 177,
             Int(ProcessInfo.processInfo.environment["SWIFTTERM_NARROW_ROWS"] ?? "") ?? 66),
            ("btop", "btop-through-tmux-sync.raw", 200, 50),
        ] {
            let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: rows)
            var keys = [RowKey?](repeating: nil, count: rows)
            var bandTotal = 0, changedTotal = 0, counted = 0, unionTotal = 0, outsideTotal = 0
            var bandMax = 0

            for frame in try frames(fixture) {
                terminal.feed(byteArray: frame)
                guard let (start, end) = terminal.getUpdateRange() else { continue }
                terminal.clearUpdateRange()
                let buffer = terminal.displayBuffer
                let lo = max(0, start), hi = min(rows - 1, end)
                guard lo <= hi else { continue }

                var changed = 0
                var outside = 0
                var loChanged = Int.max, hiChanged = -1
                for y in 0..<rows {
                    let absolute = buffer.yDisp + y
                    guard absolute < buffer.lines.count else { continue }
                    let line = buffer.lines[absolute]
                    let key = RowKey(line: ObjectIdentifier(line), generation: line.generation)
                    if keys[y] != key {
                        if y >= lo, y <= hi {
                            changed += 1
                            loChanged = min(loChanged, y)
                            hiChanged = max(hiChanged, y)
                        } else {
                            // 變了、卻不在 terminal 標髒的範圍裡 —— 這種列沒有人會去重畫它
                            outside += 1
                        }
                    }
                    keys[y] = key
                }
                unionTotal += hiChanged >= loChanged ? hiChanged - loChanged + 1 : 0
                bandTotal += hi - lo + 1
                bandMax = max(bandMax, hi - lo + 1)
                changedTotal += changed
                outsideTotal += outside
                counted += 1
            }

            guard counted > 0 else { continue }
            let band = Double(bandTotal) / Double(counted)
            let changed = Double(changedTotal) / Double(counted)
            let union = Double(unionTotal) / Double(counted)
            print(String(format:
                "%@: %d 幀 — 現況 band %.1f 列/幀（最大 %d）｜真的變 %.1f 列｜變動列的聯集 %.1f 列 → 面積可降 %.1f×",
                label, counted, band, bandMax, changed, union, union > 0 ? band / union : Double(rows)))
            if outsideTotal > 0 {
                print(String(format: "    ⚠ 另有 %.2f 列/幀 變了卻不在 dirty range 內（terminal 漏標，共 %d 列）",
                             Double(outsideTotal) / Double(counted), outsideTotal))
            }
        }
    }
}
#endif
