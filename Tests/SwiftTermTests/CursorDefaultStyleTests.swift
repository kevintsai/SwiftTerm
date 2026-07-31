//
//  CursorDefaultStyleTests.swift
//
//  Verifies `Terminal.defaultCursorStyle` (kitty `cursor_shape` semantics): applications drive the
//  cursor freely via DECSCUSR, but "reset to default" (Ps=0) returns to the user-configured style
//  instead of the hardcoded xterm blinking block.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class CursorDefaultStyleTests {
    private func makeHeadlessTerminal() -> HeadlessTerminal {
        HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
    }

    // DECSCUSR: CSI Ps SP q
    private func decscusr(_ terminal: Terminal, _ ps: Int) {
        terminal.feed(text: "\u{1b}[\(ps) q")
    }

    @Test func testAppCanRequestBlink() {
        let t = makeHeadlessTerminal().terminal!
        t.defaultCursorStyle = .steadyBlock
        decscusr(t, 5) // blinking bar (what an app like nvim might request)
        #expect(t.options.cursorStyle == .blinkBar)
    }

    @Test func testResetReturnsToConfiguredDefault() {
        let t = makeHeadlessTerminal().terminal!
        t.defaultCursorStyle = .steadyBlock
        decscusr(t, 5)     // app switches to a blinking bar
        #expect(t.options.cursorStyle == .blinkBar)
        decscusr(t, 0)     // reset to default → the configured steady block, NOT xterm blinking block
        #expect(t.options.cursorStyle == .steadyBlock)
    }

    @Test func testResetWithoutConfiguredDefaultIsXtermBlinkingBlock() {
        let t = makeHeadlessTerminal().terminal!
        // No defaultCursorStyle set → keep xterm behavior (Ps=0 == blinking block).
        decscusr(t, 2)     // steady block
        #expect(t.options.cursorStyle == .steadyBlock)
        decscusr(t, 0)
        #expect(t.options.cursorStyle == .blinkBlock)
    }

    @Test func testExplicitStylesStillApply() {
        let t = makeHeadlessTerminal().terminal!
        t.defaultCursorStyle = .steadyBlock
        decscusr(t, 3) // blinking underline
        #expect(t.options.cursorStyle == .blinkUnderline)
        decscusr(t, 6) // steady bar
        #expect(t.options.cursorStyle == .steadyBar)
    }
}
#endif
