//
// `Terminal.contentVersion` — the token a host samples on its own rhythm.
//
// The property that matters is the NEGATIVE one: feeding bytes that change nothing must not bump it, or a
// sampler gains nothing by consulting it. The positive direction is easy; these pin both, plus the
// documented blind spot (a pure cursor move marks no row dirty, so it does not bump).
//
import Testing

@testable import SwiftTerm

final class ContentVersionTests {
    private let esc = "\u{1b}"

    @Test func writingTextBumpsTheVersion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        let before = terminal.contentVersion
        terminal.feed(text: "hello")
        #expect(terminal.contentVersion > before)
    }

    @Test func anIdleTerminalHoldsItsVersion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "hello")
        let settled = terminal.contentVersion
        // Reading the buffer the way a sampler would must not itself count as a change.
        _ = terminal.getCursorViewportLocation()
        _ = terminal.buffer.lines[0]
        #expect(terminal.contentVersion == settled)
    }

    @Test func clearingTheUpdateRangeDoesNotResetTheVersion() {
        // The whole point: the view consumes `getUpdateRange` every frame, and the sampler must still be
        // able to tell "changed since I last looked" afterwards.
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "hello")
        let afterWrite = terminal.contentVersion
        terminal.clearUpdateRange()
        #expect(terminal.getUpdateRange() == nil, "the view has taken the dirty range")
        #expect(terminal.contentVersion == afterWrite, "but the token survives it")

        terminal.feed(text: " world")
        #expect(terminal.contentVersion > afterWrite, "and still moves for the next change")
    }

    @Test func aFullScreenRepaintBumpsTheVersion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        let before = terminal.contentVersion
        terminal.updateFullScreen()
        #expect(terminal.contentVersion > before)
    }

    /// The documented blind spot. A sampler that also cares about the cursor must compare it separately —
    /// which is exactly what fleetmux's occupancy scan does, because its payload carries the cursor.
    @Test func aPureCursorMoveDoesNotBumpTheVersion() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "hello")
        terminal.clearUpdateRange()
        let settled = terminal.contentVersion
        let cursorBefore = terminal.buffer.x

        terminal.feed(text: "\(esc)[D")  // CUB: one column left, no cell touched
        #expect(terminal.buffer.x != cursorBefore, "the cursor really did move")
        #expect(
            terminal.contentVersion == settled,
            "cursor-only movement marks no row dirty; a sampler must compare the cursor separately")
    }
}
