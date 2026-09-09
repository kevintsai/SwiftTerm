//
//  ScrollBlitCeilingTests.swift
//
//  What is scroll blitting worth, BEFORE anyone builds it.
//
//  Every remaining route to it (fleetmux spec 27 §5.3a) means restructuring the Mac renderer to own a
//  surface — `NSView.scroll(_:by:)` was measured and does not help a layer-backed view. That is a big
//  bet, so it deserves a ceiling first: how much of the paint cost is actually proportional to the rows
//  being repainted, and how much is fixed per frame?
//
//  Two arms over the same real tmux capture, painting into the same kind of persistent bitmap the
//  render tests use:
//
//    TODAY  — paint the rects the view asks for now (a scroll invalidates every screen row, because
//             every screen row really does hold different pixels afterwards).
//    ORACLE — cheat: paint only the rows whose CONTENT is new, keyed by line identity. Physically
//             wrong (the moved pixels never get moved), but it is exactly the work blitting would be
//             left with, so the gap is blitting's ceiling — before subtracting the per-frame cost of
//             moving the surface, which this does not model and which is not free.
//

#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import SwiftTerm

@MainActor
final class ScrollBlitCeilingTests: XCTestCase {
    private static let frameEnd: [UInt8] = Array("\u{1b}[1;24r".utf8)

    private func frames() throws -> [[UInt8]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/streaming-scroll-through-tmux.raw")
        let bytes = [UInt8](try Data(contentsOf: url))
        var out: [[UInt8]] = [], current: [UInt8] = []
        for b in bytes {
            current.append(b)
            if current.count >= Self.frameEnd.count,
               Array(current.suffix(Self.frameEnd.count)) == Self.frameEnd {
                out.append(current); current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

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

    private struct Arm {
        var seconds = 0.0
        var rowsPainted = 0
        var draws = 0
    }

    private enum Mode {
        /// Paint every row the view asks for — what happens today.
        case today
        /// Paint only rows whose content is new, and move nothing. Physically wrong; the ceiling.
        case oracle
        /// What B1 would really do: shift the surface, paint only the new rows, then present the
        /// whole surface (AppKit's own backing store did not scroll, so the screen still needs all
        /// of it). Both of those costs are real and neither is in `oracle`.
        case b1
    }

    /// `mode` decides which of the three cost models is being timed. See ``Mode``.
    private func replay(mode: Mode, coalesce: Int = 1) throws -> Arm {
        let oracle = mode != .today
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 384))
        let terminal: Terminal = view.terminal
        terminal.resize(cols: 80, rows: 24)
        guard let store = makeStore(view) else { throw XCTSkip("no bitmap context") }
        // Stands in for the window's backing store, so "present the surface" is a real copy.
        guard let screen = makeStore(view) else { throw XCTSkip("no bitmap context") }
        let rowBytes = store.bytesPerRow
        let rowPixels = Int((view.bounds.height / CGFloat(terminal.rows)).rounded()) * 2  // scale 2
        // What the surface currently shows at each screen row, so a uniform shift is detectable.
        var onSurface: [Int: ObjectIdentifier] = [:]

        var arm = Arm()
        // Content already on screen, keyed by LINE — the record blitting would keep.
        var painted: [ObjectIdentifier: UInt64] = [:]
        let rowHeight = view.bounds.height / CGFloat(terminal.rows)

        var pending = 0
        for frame in try frames() {
            terminal.feed(buffer: frame[...])
            pending += 1
            guard pending >= coalesce else { continue }
            pending = 0
            guard let (start, end) = terminal.getUpdateRange() else { continue }
            terminal.clearUpdateRange()
            guard let runs = view.visuallyChangedRowRuns(rowStart: start, rowEnd: end) else { continue }
            arm.draws += 1
            let buffer = terminal.displayBuffer

            // How far the visible content moved, by line identity — the signal B1 would blit on.
            var shift = 0
            if mode == .b1 {
                var votes: [Int: Int] = [:]
                for y in 0..<terminal.rows {
                    let absolute = buffer.yDisp + y
                    guard absolute >= 0, absolute < buffer.lines.count else { continue }
                    let id = ObjectIdentifier(buffer.lines[absolute])
                    for (prevY, prevId) in onSurface where prevId == id {
                        votes[y - prevY, default: 0] += 1
                    }
                }
                shift = votes.filter { $0.key != 0 }.max(by: { $0.value < $1.value })?.key ?? 0
            }
            var screenRows: [Int] = []
            for run in runs {
                for y in run {
                    let absolute = buffer.yDisp + y
                    guard absolute >= 0, absolute < buffer.lines.count else { continue }
                    if oracle {
                        let line = buffer.lines[absolute]
                        let id = ObjectIdentifier(line)
                        if painted[id] == line.generation { continue }   // moved, not changed
                        painted[id] = line.generation
                    }
                    screenRows.append(y)
                }
            }
            if mode == .b1 {
                onSurface.removeAll(keepingCapacity: true)
                for y in 0..<terminal.rows {
                    let absolute = buffer.yDisp + y
                    guard absolute >= 0, absolute < buffer.lines.count else { continue }
                    onSurface[y] = ObjectIdentifier(buffer.lines[absolute])
                }
            }
            guard !screenRows.isEmpty else { continue }
            arm.rowsPainted += screenRows.count

            let started = ProcessInfo.processInfo.systemUptime
            if mode == .b1 {
                // 1) move the pixels that only scrolled. A real implementation memmoves inside its own
                //    bitmap; the cost is the same whichever direction it goes.
                if let data = store.data, shift != 0 {
                    let moved = max(0, (terminal.rows - abs(shift))) * rowPixels * rowBytes
                    let offset = abs(shift) * rowPixels * rowBytes
                    if moved > 0, offset + moved <= rowBytes * store.height {
                        memmove(data.advanced(by: offset), data, moved)
                    }
                }
            }
            for y in screenRows {
                let rect = NSRect(x: 0,
                                  y: view.bounds.height - CGFloat(y + 1) * rowHeight,
                                  width: view.bounds.width,
                                  height: rowHeight)
                paint(view, rect, into: store)
            }
            if mode == .b1, let image = store.makeImage() {
                // 2) present: the view's backing store never scrolled, so the whole surface goes up.
                screen.draw(image, in: view.bounds)
            }
            arm.seconds += ProcessInfo.processInfo.systemUptime - started
        }
        _ = onSurface
        return arm
    }

    func testWhatBlittingCouldSave() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_BLIT_CEILING"] == "1",
                          "measurement only; set SWIFTTERM_BLIT_CEILING=1 to run")
        let runs = Int(ProcessInfo.processInfo.environment["SWIFTTERM_BLIT_RUNS"] ?? "") ?? 3
        for coalesce in [1, 3, 5] {
        var today: [Double] = [], oracle: [Double] = [], b1: [Double] = []
        var t = Arm(), o = Arm(), b = Arm()
        for _ in 0..<runs {
            t = try replay(mode: .today, coalesce: coalesce); today.append(t.seconds * 1000)
            o = try replay(mode: .oracle, coalesce: coalesce); oracle.append(o.seconds * 1000)
            b = try replay(mode: .b1, coalesce: coalesce);     b1.append(b.seconds * 1000)
        }
        today.sort(); oracle.sort(); b1.sort()
        let tm = today[today.count / 2], om = oracle[oracle.count / 2], bm = b1[b1.count / 2]
        print("  ── \(coalesce) tmux update(s) per draw ──")
        print(String(format: """

        ── what scroll blitting could save on the paint side (80x24, real tmux capture) ──
          TODAY  : %8.1f ms  %6d rows over %4d draws (%.1f rows/draw)
          ORACLE : %8.1f ms  %6d rows over %4d draws (%.1f rows/draw)
          B1     : %8.1f ms  %6d rows  (shift + paint new + present whole surface)
          ceiling (ORACLE, ignores the surface move) : %.0f%%   (rows: %.1fx fewer)
          REALISTIC (B1, includes it)               : %.0f%%
          ⚠ excludes the per-frame cost of actually moving the surface, which blitting must add.
        ──────────────────────────────────────────────────────────────────────────────────

        """, tm, t.rowsPainted, t.draws, Double(t.rowsPainted) / Double(max(t.draws, 1)),
             om, o.rowsPainted, o.draws, Double(o.rowsPainted) / Double(max(o.draws, 1)),
             bm, b.rowsPainted,
             (tm - om) / tm * 100, Double(t.rowsPainted) / Double(max(o.rowsPainted, 1)),
             (tm - bm) / tm * 100))
        }
    }
}
#endif
