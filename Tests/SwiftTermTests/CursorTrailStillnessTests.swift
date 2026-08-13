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
#endif
