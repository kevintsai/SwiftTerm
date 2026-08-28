//
//  RowDrawCacheRenderTests.swift
//
//  The invariant the unit tests cannot state: **a view that has been reusing cached rows must draw
//  exactly what a view that has never cached anything draws.**
//
//  `RowDrawCacheTests` pins that the right things force a rebuild, but it observes an object identity,
//  not a picture. A cache key can be right in that sense and still paint the wrong pixels. So this
//  drives one view through a sequence of state changes — rendering after each, so its cache is warm and
//  full of assumptions — and after every step renders a FRESH view that was replayed to the same state
//  and has therefore cached nothing. The two bitmaps must be byte-identical.
//
//  That is what "no stale glyphs" actually means, and it is checkable without a window, without a
//  screenshot, and without anyone looking at anything.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class RowDrawCacheRenderTests {
    /// One thing that can be done to a view, applied identically to the warm and the cold copy.
    private struct Step {
        let name: String
        let apply: (TerminalView) -> Void
    }

    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
    }

    /// Render the view's whole bounds into a bitmap. Goes through `draw(_:)`, so it exercises the real
    /// `drawTerminalContents` — cache and all.
    private func render(_ view: TerminalView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// The sequence. Each step is a state change that the cache key claims to notice; rendering between
    /// them is what makes the warm view's cache stale if the key is wrong.
    private var steps: [Step] {
        [
            Step(name: "initial text") { $0.terminal.feed(text: "hello world\r\nsecond line\r\nthird line\r\n") },
            Step(name: "overwrite a row") { $0.terminal.feed(text: "\u{1b}[1;1Hoverwritten") },
            Step(name: "append below") { $0.terminal.feed(text: "fourth line\r\nfifth line\r\n") },
            Step(name: "select a span") {
                $0.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
            },
            Step(name: "extend the selection") {
                $0.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 4, row: 1))
            },
            Step(name: "clear the selection") { $0.selection.selectNone() },
            Step(name: "hover a link with the modifier down") {
                $0.linkHighlightMode = .hoverWithModifier
                $0.commandActive = true
                $0.linkHighlightRange = [Terminal.LinkMatch.RowRange(row: 0, range: 0..<5)]
            },
            Step(name: "release the modifier") { $0.commandActive = false },
            Step(name: "drop the hover") { $0.linkHighlightRange = nil },
            Step(name: "bigger font") { $0.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular) },
            Step(name: "smaller font") { $0.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) },
            // ⚠ Must be written in an ANSI colour, or a palette change below cannot show: default
            // foreground/background do not come from the 16-colour table, so swapping that table would
            // repaint nothing and the step would prove nothing. (It did — mutation-checked.)
            Step(name: "text in ANSI colours") { $0.terminal.feed(text: "\u{1b}[31mred\u{1b}[32m green\u{1b}[0m\r\n") },
            Step(name: "new palette") {
                var colors = $0.terminal.ansiColors
                colors[1] = Color(red: 0, green: 0, blue: 65535)
                colors[2] = Color(red: 65535, green: 65535, blue: 0)
                $0.installColors(Array(colors.prefix(16)))
            },
            Step(name: "select a span to colour") {
                $0.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
            },
            // Separated from the selection change above on purpose: together, the selection key alone
            // forces the rebuild and the epoch is never exercised.
            Step(name: "new selection colour, same selection") { $0.selectedTextBackgroundColor = .systemPink },
            // Box drawing first, or toggling the renderer below changes nothing on screen and the step
            // proves nothing (mutation-checked: without this line the `customBlockGlyphs` mutant lived).
            Step(name: "box drawing characters") { $0.terminal.feed(text: "\u{250c}\u{2500}\u{2510}\r\n\u{2514}\u{2500}\u{2518}\r\n") },
            Step(name: "font-drawn box glyphs") { $0.customBlockGlyphs = false },
            Step(name: "custom box glyphs again") { $0.customBlockGlyphs = true },
            Step(name: "text after all of that") { $0.terminal.feed(text: "\r\nafter everything\r\n") },
            Step(name: "scroll the buffer past a screenful") {
                for i in 0..<40 { $0.terminal.feed(text: "scrolling line \(i)\r\n") }
            },
        ]
    }

    @Test func aWarmCacheDrawsWhatAColdOneDraws() throws {
        let warm = makeView()
        for (index, step) in steps.enumerated() {
            step.apply(warm)
            // Render the warm view: this is also what fills its cache with assumptions about the state
            // it has just been put into.
            let warmPixels = render(warm)

            // A view that has done everything up to and including this step, and cached nothing that
            // could be stale, because every row it has is being shaped for the first time at this state.
            let cold = makeView()
            for earlier in steps[0...index] { earlier.apply(cold) }
            let coldPixels = render(cold)

            #expect(warmPixels != nil, "step \(index) (\(step.name)): the warm view rendered nothing")
            #expect(warmPixels == coldPixels,
                    "step \(index) (\(step.name)): a warm cache drew something a cold one did not — a cache key is missing an input that this step changes")
        }
    }

    /// The guard copied from the Metal renderer: scrolling rotates `BufferLine` references inside the
    /// `CircularList`, so one absolute row number comes to hold a *different* line — whose `generation`
    /// can be coincidentally equal. Nothing here touches view state; only the buffer scrolls.
    ///
    /// ⚠ **On the ALTERNATE screen, and that is the whole point.** On the main buffer, scrolling appends:
    /// `lines.count` and `yDisp` both grow, so every row is drawn at a row number that has never been
    /// cached, and no stale entry can be served. The alternate screen has no scrollback — `yDisp` stays
    /// at 0 and the same 40-odd row numbers are reused forever, with the lines beneath them rotating.
    /// That is where the guard earns its keep, and it is also where every TUI under tmux lives.
    ///
    /// Written on the main buffer first, and mutation-checked: removing the `===` left it green.
    @Test func scrollingTheAlternateScreenDoesNotLeaveRowsBehind() throws {
        let enterAlt = "\u{1b}[?1049h"
        func script(_ rounds: Int) -> [String] {
            var out = [enterAlt]
            for round in 0..<rounds { out.append("row \(round) aaaaaaaaaaaaaaaaaaaa\r\n") }
            return out
        }

        let warm = makeView()
        warm.terminal.feed(text: enterAlt)
        #expect(warm.terminal.isCurrentBufferAlternate, "the premise: this must be the alt screen")

        for round in 0..<40 {
            warm.terminal.feed(text: "row \(round) aaaaaaaaaaaaaaaaaaaa\r\n")
            let warmPixels = render(warm)

            let cold = makeView()
            for chunk in script(round + 1) { cold.terminal.feed(text: chunk) }
            let coldPixels = render(cold)

            #expect(warmPixels == coldPixels,
                    "round \(round): a rotated row was served from the previous line's entry")
        }
    }
}
#endif
