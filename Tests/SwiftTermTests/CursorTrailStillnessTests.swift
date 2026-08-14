//
//  CursorTrailStillnessTests.swift
//
//  kitty's `cursor_trail <ms>` gate: the trail only follows a cursor that has STAYED PUT for that long.
//  The clock that matters is the client program's last cursor move (`Terminal.cursorPositionChangedAt`,
//  stamped while parsing) — not "when the renderer last noticed a different position".
//
//  Why this has its own test: with a render-time clock the gate is a no-op (a renderer samples ~60 times a
//  second, so one frame later the cursor always looks "still"), and the trail chases every transient position
//  an app sweeps through while painting a frame — e.g. a full-screen redraw that parks the cursor at the top
//  of the screen and only then returns it to the prompt. The visible symptom is a cursor trail that keeps
//  flying off and snapping back while a TUI is busy.
//

#if os(macOS)
import AppKit
import XCTest

@testable import SwiftTerm

/// The other half of the fix: `Terminal` stamps `cursorPositionChangedAt` **while parsing**, so the gate above
/// has a clock that reflects the program, not the renderer.
final class CursorPositionStampTests: XCTestCase {
    private func makeTerminal() -> Terminal { Terminal(delegate: HeadlessDelegate()) }

    private final class HeadlessDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    private func feed(_ t: Terminal, _ s: String) {
        let bytes = Array(s.utf8)
        t.feed(buffer: bytes[...])
    }

    func testMovingTheCursorStampsTheClock() {
        let t = makeTerminal()
        feed(t, "\u{1b}[5;5H")
        let first = t.cursorPositionChangedAt
        XCTAssertGreaterThan(first, 0, "a cursor move stamps the clock")

        feed(t, "\u{1b}[20;1H")
        XCTAssertGreaterThan(t.cursorPositionChangedAt, first, "a later move re-stamps it")
    }

    /// A feed that ends where it started (an app painting a line and returning to its prompt) is NOT a move —
    /// nothing on screen suggests the cursor went anywhere, so the trail must not treat it as one.
    func testAFeedThatReturnsToTheSameCellDoesNotStamp() {
        let t = makeTerminal()
        feed(t, "\u{1b}[10;3H")
        let stamped = t.cursorPositionChangedAt

        feed(t, "\u{1b}[1;1Hredraw\u{1b}[10;3H")
        XCTAssertEqual(t.cursorPositionChangedAt, stamped, "net-zero cursor movement leaves the clock alone")
    }

    func testPrintingTextCountsAsMovement() {
        let t = makeTerminal()
        feed(t, "\u{1b}[1;1H")
        let stamped = t.cursorPositionChangedAt
        feed(t, "hello")
        XCTAssertGreaterThan(t.cursorPositionChangedAt, stamped, "printing advances the cursor → it moved")
    }
}

final class CursorTrailStillnessTests: XCTestCase {
    /// A cell rect at `row` (row 0 at the top), in the view's y-up point space.
    private func rect(row: CGFloat, height: CGFloat = 400) -> CGRect {
        CGRect(x: 0, y: height - (row + 1) * 16, width: 8, height: 16)
    }

    private func makeView(clock: @escaping () -> CFTimeInterval) -> CursorTrailView {
        let v = CursorTrailView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        v.clientClock = clock
        v.stillness = 0.010  // 10ms, like kitty's `cursor_trail 10`
        return v
    }

    /// While the program is still painting (it moved the cursor microseconds ago), the target must stay put —
    /// the trail must not be pulled toward a position the app is only passing through.
    func testTargetIsFrozenWhileTheProgramKeepsMovingTheCursor() {
        var now: CFTimeInterval = 100
        let v = makeView(clock: { now })

        // Settle on row 25 (the prompt): the app moved there and has been idle since.
        v.cursorMoved(rect: rect(row: 25), cellWidth: 8, cellHeight: 16, visible: true, clientMovedAt: now - 1)
        v.stepForTesting()
        let settled = v.committedTargetYForTesting

        // Mid-redraw: the app is sweeping the cursor (parked at row 1) and moved it *just now*.
        now += 0.001
        v.cursorMoved(rect: rect(row: 1), cellWidth: 8, cellHeight: 16, visible: true, clientMovedAt: now)
        v.stepForTesting()
        XCTAssertEqual(v.committedTargetYForTesting, settled,
                       "the program is still painting → the target must not follow the transient position")

        // Still painting a few frames later.
        now += 0.005
        v.cursorMoved(rect: rect(row: 3), cellWidth: 8, cellHeight: 16, visible: true, clientMovedAt: now)
        v.stepForTesting()
        XCTAssertEqual(v.committedTargetYForTesting, settled, "still painting → still frozen")
    }

    /// Once the program has been quiet for longer than the gate, the target follows normally.
    func testTargetFollowsOnceTheProgramHasSettled() {
        var now: CFTimeInterval = 100
        let v = makeView(clock: { now })
        v.cursorMoved(rect: rect(row: 25), cellWidth: 8, cellHeight: 16, visible: true, clientMovedAt: now - 1)
        v.stepForTesting()
        let settled = v.committedTargetYForTesting

        let movedAt = now
        v.cursorMoved(rect: rect(row: 5), cellWidth: 8, cellHeight: 16, visible: true, clientMovedAt: movedAt)
        now = movedAt + 0.050  // quiet for 50ms ≫ 10ms gate
        v.stepForTesting()
        XCTAssertNotEqual(v.committedTargetYForTesting, settled,
                          "the program settled at the new position → the trail follows it")
        XCTAssertEqual(v.committedTargetYForTesting[0], rect(row: 5).maxY, accuracy: 0.01)
    }
}

/// The gap the first stillness fix left open: what tmux emits BETWEEN two synchronized frames.
///
/// Recorded off a real (isolated) tmux server with the client advertising `sync`, 200x60 pane, a TUI
/// repainting ~20fps — 39 of 41 inter-frame windows were byte-for-byte this shape:
///
///     ESC[?2026l  ESC[5;170H  ESC[?25l  ESC[10;153H … ESC[54;173H  ESC[?2026h  <next frame>
///
/// i.e. tmux ends the synchronized block, moves the STILL-VISIBLE cursor to a fixed spot near the top right,
/// only then hides it and sweeps it across the pane, and only then opens the next synchronized block. Nothing
/// in that window is inside a synchronized update, so a view that samples on its own timer is free to render
/// it — and the trail flies to the top right and snaps back, always in the same direction. (Measured exposure
/// of that state: 0.1–0.9ms, which is why it shows up as an occasional flick rather than a constant smear.)
///
/// Two rules close it, and this test pins both:
///   1. a stillness gate that outlasts one sampling interval (the visible top-right jump), and
///   2. never sampling a HIDDEN cursor's position (the sweep that follows).
final class CursorTrailTmuxInterFrameTests: XCTestCase {
    private final class HeadlessDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    private let cellW: CGFloat = 8, cellH: CGFloat = 16, viewH: CGFloat = 960  // 60 rows × 16pt

    /// The caret rect for the terminal's CURRENT cursor cell, the way `updateCursorPosition()` computes it.
    private func caretRect(_ t: Terminal) -> CGRect {
        CGRect(x: CGFloat(t.buffer.x) * cellW, y: viewH - CGFloat(t.buffer.y + 1) * cellH,
               width: cellW, height: cellH)
    }

    /// One render: sample the terminal exactly like `notifyCursorTrail(visible:)` does, `delay` seconds after
    /// the client's last cursor move (a view samples up to a frame late — that lateness is the whole bug).
    private func render(_ v: CursorTrailView, _ t: Terminal, delay: CFTimeInterval) {
        v.clientClock = { t.cursorPositionChangedAt + delay }
        v.cursorMoved(rect: caretRect(t), cellWidth: cellW, cellHeight: cellH,
                      visible: !t.cursorHidden, clientMovedAt: t.cursorPositionChangedAt)
        v.stepForTesting()
    }

    private func feed(_ t: Terminal, _ s: String) {
        let bytes = Array(s.utf8)
        t.feed(buffer: bytes[...])
    }

    func testTheTrailIgnoresTmuxsUnsynchronizedGapBetweenFrames() {
        let t = Terminal(delegate: HeadlessDelegate())
        t.resize(cols: 200, rows: 60)
        let v = CursorTrailView(frame: CGRect(x: 0, y: 0, width: 1600, height: viewH))

        // Settled at the prompt (row 59, col 5) — the app has been idle there.
        feed(t, "\u{1b}[59;5H\u{1b}[?25h")
        render(v, t, delay: 1.0)
        let prompt = v.committedTargetYForTesting
        XCTAssertEqual(prompt[0], caretRect(t).maxY, accuracy: 0.01, "the trail starts settled on the prompt")

        // tmux closes the frame and jumps the still-VISIBLE cursor to the top right. A chunk boundary here
        // means this is the state the next render samples — one frame (16.7ms) later.
        feed(t, "\u{1b}[?2026l\u{1b}[5;170H")
        render(v, t, delay: 0.0167)
        XCTAssertEqual(v.committedTargetYForTesting, prompt,
                       "a position the client set a frame ago is not 'settled' — the trail must stay on the prompt")

        // …then tmux hides the cursor and sweeps it across the whole pane. Give these MORE than the gate, so
        // only the hidden-cursor rule can save us: those cells were never on screen.
        for move in ["\u{1b}[?25l\u{1b}[10;153H", "\u{1b}[15;132H", "\u{1b}[30;69H", "\u{1b}[54;173H"] {
            feed(t, move)
            render(v, t, delay: 0.5)
            XCTAssertEqual(v.committedTargetYForTesting, prompt,
                           "the cursor is hidden — the trail must not chase where tmux parked it")
        }

        // Next frame: tmux repaints inside a synchronized block, puts the cursor back on the prompt, shows it.
        feed(t, "\u{1b}[?2026h\u{1b}[1;1Hrepainted\u{1b}[59;5H\u{1b}[?25h\u{1b}[?2026l")
        render(v, t, delay: 0.5)
        XCTAssertEqual(v.committedTargetYForTesting, prompt, "back where it started — nothing to animate")
    }

    /// The gate must not become a freeze: a real move the program then leaves alone is still followed.
    func testARealMoveIsStillFollowedOnceTheProgramLeavesItAlone() {
        let t = Terminal(delegate: HeadlessDelegate())
        t.resize(cols: 200, rows: 60)
        let v = CursorTrailView(frame: CGRect(x: 0, y: 0, width: 1600, height: viewH))

        feed(t, "\u{1b}[59;5H\u{1b}[?25h")
        render(v, t, delay: 1.0)
        let prompt = v.committedTargetYForTesting

        feed(t, "\u{1b}[10;40H")
        render(v, t, delay: 0.5)  // quiet for 500ms ≫ the gate
        XCTAssertNotEqual(v.committedTargetYForTesting, prompt, "a settled move is followed")
        XCTAssertEqual(v.committedTargetYForTesting[0], caretRect(t).maxY, accuracy: 0.01)
    }
}
#endif
