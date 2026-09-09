//
//  RowDrawCacheScrollTests.swift
//
//  The row shaping cache (`AppleRowDrawCache.swift`) is keyed by the row's position in the buffer.
//  A scrolling terminal moves content BETWEEN positions, so the two disagree exactly when it matters
//  most — a pane whose program is streaming output scrolls on almost every frame.
//
//  While the buffer is still growing the disagreement is invisible: `lines.push` appends, so a line
//  keeps its absolute index for life. Once the scrollback is full `Terminal.scroll` switches to
//  `lines.recycle()`, which advances the CircularList's start index — every retained line's absolute
//  index drops by one, every cache entry is looked up under the previous tenant's number, and the
//  `lineRef === line` guard turns all of them into misses. Nothing is wrong on screen; the whole
//  screen is simply shaped again, every frame, forever.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class RowDrawCacheScrollTests {
    private struct Shaped {
        let generation: UInt64
        let attributed: NSAttributedString?
    }

    /// Shape every visible row, keyed by the LINE (not the row number) so the check survives a scroll.
    private func shapeVisible(_ view: TerminalView) -> [ObjectIdentifier: Shaped] {
        let terminal: Terminal = view.terminal
        let buffer = terminal.displayBuffer
        var out: [ObjectIdentifier: Shaped] = [:]
        for y in 0..<terminal.rows {
            let absolute = buffer.yDisp + y
            let line = buffer.lines[absolute]
            let state = view.rowDrawState(row: absolute, line: line, cols: terminal.cols)
            out[ObjectIdentifier(line)] = Shaped(generation: line.generation,
                                                 attributed: state.info.segments.first?.attributedString)
        }
        return out
    }

    /// Feed until the line list is full, i.e. until the next scroll must recycle instead of push.
    private func fillScrollback(_ view: TerminalView, scrollback: Int) {
        let terminal: Terminal = view.terminal
        terminal.changeScrollback(scrollback)
        var written = 0
        while !terminal.displayBuffer.lines.isFull && written < scrollback * 4 {
            terminal.feed(text: "row \(written) content\r\n")
            written += 1
        }
        #expect(terminal.displayBuffer.lines.isFull,
                "the premise of this test is a full scrollback — that is when `scroll` starts recycling")
    }

    /// While the buffer is still growing, a scroll leaves every other row's shaped state usable.
    /// This is the case every benchmark corpus and every earlier test has exercised.
    @Test func whileTheBufferGrowsAScrollKeepsTheShapedRows() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let terminal: Terminal = view.terminal
        terminal.changeScrollback(4000)
        for i in 0..<10 { terminal.feed(text: "row \(i) content\r\n") }

        let before = shapeVisible(view)
        terminal.feed(text: "one more line\r\n")
        let after = shapeVisible(view)

        var reusable = 0, reused = 0
        for (line, now) in after {
            guard let prev = before[line], prev.generation == now.generation, prev.attributed != nil else { continue }
            reusable += 1
            if prev.attributed === now.attributed { reused += 1 }
        }
        #expect(reusable > 0)
        #expect(reused == reusable, "\(reused)/\(reusable) unchanged rows came back from the cache")
    }

    /// The same scroll, after the scrollback filled up. Same content on screen, same everything the
    /// key claims to cover — and every single row is shaped again.
    @Test func afterTheScrollbackFillsAScrollThrowsAwayEveryShapedRow() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let terminal: Terminal = view.terminal
        fillScrollback(view, scrollback: 40)

        let before = shapeVisible(view)
        terminal.feed(text: "one more line\r\n")
        let after = shapeVisible(view)

        var reusable = 0, reused = 0
        for (line, now) in after {
            guard let prev = before[line], prev.generation == now.generation, prev.attributed != nil else { continue }
            reusable += 1
            if prev.attributed === now.attributed { reused += 1 }
        }
        #expect(reusable > 0, "the scroll moved rows, it did not rewrite them")
        #expect(reused == reusable,
                "\(reused)/\(reusable) unchanged rows came back from the cache — a recycling scroll must not re-shape rows whose content did not move with it")
    }
}
#endif
