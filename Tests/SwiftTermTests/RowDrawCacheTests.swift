//
//  RowDrawCacheTests.swift
//
//  The CoreText draw path caches each row's shaped state and reuses it while nothing that row depends
//  on has changed (`AppleRowDrawCache.swift`).
//
//  **These tests are almost all about the negative direction**, because that is the direction that
//  fails silently. A cache that rebuilds too often is slow; a cache that rebuilds too rarely paints
//  last frame's glyphs and says nothing. So every input `buildAttributedString` reads gets a test that
//  changes only that input and demands a rebuild.
//
//  How a hit is observed: `ViewLineSegment.attributedString` is a class, so a cache hit hands back the
//  *same instance* while a rebuild produces a new one. No production counter needed.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class RowDrawCacheTests {
    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.terminal.feed(text: "hello world\r\nsecond line\r\nthird line\r\n")
        return view
    }

    /// The shaped string for `row`, as an identity we can compare across calls.
    private func shape(_ view: TerminalView, row: Int) -> NSAttributedString? {
        let line = view.terminal.displayBuffer.lines[row]
        let state = view.rowDrawState(row: row, line: line, cols: view.terminal.cols)
        return state.info.segments.first?.attributedString
    }

    // MARK: - the win

    @Test func aRowThatDidNotChangeIsShapedOnlyOnce() {
        let view = makeView()
        let first = shape(view, row: 0)
        let second = shape(view, row: 0)
        #expect(first != nil)
        #expect(first === second, "an unchanged row must come back from the cache")
    }

    // MARK: - every input that must force a rebuild

    @Test func writingToTheRowShapesItAgain() {
        let view = makeView()
        let before = shape(view, row: 0)
        view.terminal.feed(text: "\u{1b}[1;1Hx")   // overwrite row 0, col 0
        let after = shape(view, row: 0)
        #expect(before !== after, "the line's generation moved, so the shaped row is stale")
    }

    @Test func aDifferentLineAtTheSameRowIsShapedAgain() {
        // The `===` half of the guard, and the reason it is not redundant: scrolling rotates
        // BufferLine references inside the CircularList, so one row number can point at a different
        // line whose `generation` is coincidentally equal. Two fresh lines are both at generation 0.
        let view = makeView()
        let cols = view.terminal.cols
        let a = BufferLine(cols: cols)
        let b = BufferLine(cols: cols)
        #expect(a.generation == b.generation, "the premise: equal counters, different lines")

        let firstShape = view.rowDrawState(row: 0, line: a, cols: cols).info.segments.first?.attributedString
        let secondShape = view.rowDrawState(row: 0, line: b, cols: cols).info.segments.first?.attributedString
        #expect(firstShape != nil)
        #expect(firstShape !== secondShape, "a different line must not be served from the old one's entry")
    }

    @Test func changingTheSelectionShapesTheRowAgain() {
        let view = makeView()
        let before = shape(view, row: 0)
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 4, row: 0))
        let after = shape(view, row: 0)
        #expect(before !== after, "selection is baked into the attributed string")
    }

    @Test func changingTheLinkHighlightShapesTheRowAgain() {
        let view = makeView()
        view.linkHighlightMode = .hover
        let before = shape(view, row: 0)
        view.linkHighlightRange = [Terminal.LinkMatch.RowRange(row: 0, range: 0..<4)]
        let after = shape(view, row: 0)
        #expect(before !== after, "the underline is baked into the attributed string")
    }

    @Test func liftingTheModifierShapesTheRowAgain() {
        let view = makeView()
        view.linkHighlightMode = .hoverWithModifier
        view.linkHighlightRange = [Terminal.LinkMatch.RowRange(row: 0, range: 0..<4)]
        view.commandActive = true
        let held = shape(view, row: 0)
        view.commandActive = false
        let released = shape(view, row: 0)
        #expect(held !== released, "the modifier decides whether the row is underlined")
    }

    @Test func togglingCustomBlockGlyphsShapesTheRowAgain() {
        let view = makeView()
        let before = shape(view, row: 0)
        view.customBlockGlyphs = !view.customBlockGlyphs
        let after = shape(view, row: 0)
        #expect(before !== after, "it changes which cells become box/block draw items")
    }

    @Test func changingTheColoursShapesEveryRowAgain() {
        let view = makeView()
        let row0 = shape(view, row: 0)
        let row1 = shape(view, row: 1)
        view.colorsChanged()
        #expect(shape(view, row: 0) !== row0)
        #expect(shape(view, row: 1) !== row1, "a palette change is not per row")
    }

    @Test func resettingTheAttributeCachesShapesEveryRowAgain() {
        // The font path: `resetFont` / `setupOptions` funnel through `resetCaches`.
        let view = makeView()
        let before = shape(view, row: 0)
        view.resetCaches()
        #expect(shape(view, row: 0) !== before)
    }

    @Test func changingTheSelectionColourShapesTheRowAgain() {
        // Before the cache this setter did nothing at all — it stored the colour and left the screen
        // alone until something else dirtied those rows. It now routes through `colorsChanged`.
        let view = makeView()
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 4, row: 0))
        let before = shape(view, row: 0)
        view.selectedTextBackgroundColor = .systemPink
        #expect(shape(view, row: 0) !== before)
    }

    // MARK: - the cache stays bounded

    @Test func rowsOffScreenAreForgotten() {
        let view = makeView()
        for row in 0..<3 { _ = shape(view, row: row) }
        #expect(view.rowDrawCacheCountForTesting == 3)

        view.pruneRowDrawCache(visible: 1...2)
        #expect(view.rowDrawCacheCountForTesting == 2, "row 0 left the screen and must be dropped")

        view.pruneRowDrawCache(visible: nil)
        #expect(view.rowDrawCacheCountForTesting == 0, "nothing on screen keeps nothing")
    }

    @Test func aPrunedRowIsShapedAgainWhenItComesBack() {
        let view = makeView()
        let before = shape(view, row: 0)
        view.pruneRowDrawCache(visible: 1...2)
        #expect(shape(view, row: 0) !== before, "the entry is gone, not merely unused")
    }
}
#endif
