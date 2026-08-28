//
//  RunDecorationDrawTests.swift
//
//  The draw loop reads a run's attributes out of the `CFDictionary` CoreText hands back, and skips the
//  decoration pass for runs that carry no decoration. Both are invisible to `RowDrawCacheRenderTests`,
//  which compares a warm view against a cold one — same code on both sides, so a change that is wrong
//  in the same way twice still matches.
//
//  These assert the picture instead: the colour a run asked for is the colour on screen, and a run that
//  asked for an underline or a strikethrough still gets one.
//
#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class RunDecorationDrawTests {
    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
    }

    private func pixels(_ view: TerminalView) -> [(r: CGFloat, g: CGFloat, b: CGFloat)] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        var out: [(CGFloat, CGFloat, CGFloat)] = []
        for y in 0..<rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                out.append((c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return out
    }

    /// Ink = anything that is not the background. Counting it is enough to tell "a line was drawn here"
    /// from "it was not", without depending on where the glyphs landed.
    private func inkCount(_ view: TerminalView) -> Int {
        pixels(view).filter { $0.r > 0.25 || $0.g > 0.25 || $0.b > 0.25 }.count
    }

    @Test func aRunsForegroundColourIsTheColourOnScreen() throws {
        let view = makeView()
        view.terminal.feed(text: "\u{1b}[31mRRRRRRRRRR\u{1b}[32mGGGGGGGGGG\u{1b}[0m")
        let seen = pixels(view)
        let reds = seen.filter { $0.r > 0.35 && $0.r > $0.g + 0.15 && $0.r > $0.b + 0.15 }
        let greens = seen.filter { $0.g > 0.35 && $0.g > $0.r + 0.15 && $0.g > $0.b + 0.15 }
        #expect(!reds.isEmpty, "the red run was not painted red")
        #expect(!greens.isEmpty, "the green run was not painted green — the fill was set from the wrong run")
    }

    @Test func anUnderlinedRunStillDrawsItsUnderline() throws {
        let plain = makeView()
        plain.terminal.feed(text: "underlined")
        let plainInk = inkCount(plain)

        let underlined = makeView()
        underlined.terminal.feed(text: "\u{1b}[4munderlined\u{1b}[0m")
        let underlinedInk = inkCount(underlined)

        #expect(plainInk > 0, "the premise: plain text must draw something")
        #expect(underlinedInk > plainInk,
                "underlined text drew no more ink than plain — the decoration pass was skipped for a run that needed it")
    }

    @Test func aStruckRunStillDrawsItsLine() throws {
        let plain = makeView()
        plain.terminal.feed(text: "struck")
        let plainInk = inkCount(plain)

        let struck = makeView()
        struck.terminal.feed(text: "\u{1b}[9mstruck\u{1b}[0m")
        #expect(inkCount(struck) > plainInk,
                "struck text drew no more ink than plain — the decoration pass was skipped for a run that needed it")
    }

    @Test func aSelectionStillPaintsItsBackground() throws {
        let view = makeView()
        view.terminal.feed(text: "selected text")
        let before = inkCount(view)
        view.selectedTextBackgroundColor = .systemPink
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 8, row: 0))
        #expect(inkCount(view) > before,
                "the selection background never reached the screen — the run's background attribute was not read")
    }
}
#endif
