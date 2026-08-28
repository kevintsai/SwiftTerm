//
// A synchronized block must not cost a full-screen repaint.
//
// `endSynchronizedOutput` used to call `refresh(0, rows - 1)`, discarding the dirty range the block had
// accumulated. Every DEC 2026 frame therefore repainted every row. That matters for an embedder attached
// to tmux, which wraps each of its redraws in a begin/end pair for any client advertising 2026 — while
// sending only the cells that changed. The input was a diff; the blunt refresh made it a full frame.
//
// `throughTmuxSyncCorpusRepaintsOnlyWhatChanged` replays a REAL capture rather than a synthetic one: bytes
// taken off a `tmux -T sync attach` to a pane running btop, which is the exact shape a fleetmux pane sees.
//
import Foundation
import XCTest

@testable import SwiftTerm

/// Records the dirty range at the instant each synchronized block ends, then clears it — standing in for
/// the view, which is what normally consumes the range.
private final class SyncWatcher: TerminalDelegate {
    private(set) var framesEnded: [(startY: Int, endY: Int)?] = []

    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    func synchronizedOutputChanged(source: Terminal, active: Bool) {
        guard !active else { return }
        framesEnded.append(source.getUpdateRange())
        source.clearUpdateRange()
    }
}

final class SyncDirtyRangeTests: XCTestCase {
    private let esc = "\u{1b}"
    private var bsu: String { "\(esc)[?2026h" }
    private var esu: String { "\(esc)[?2026l" }

    private func makeTerminal(cols: Int = 80, rows: Int = 24) -> (Terminal, SyncWatcher) {
        let watcher = SyncWatcher()
        let terminal = Terminal(delegate: watcher, options: TerminalOptions(cols: cols, rows: rows, scrollback: 0))
        return (terminal, watcher)
    }

    /// A block that writes near the top must not dirty the bottom of the screen.
    ///
    /// The span is not tight, and deliberately not asserted as if it were: SwiftTerm tracks dirtiness as one
    /// contiguous range, and moving the cursor marks everything between its old and new row (the old spot
    /// has to be repainted too). So writing rows 3 and 4 from a cursor at home yields 0...3, not 2...3.
    /// What matters — and what the old code got wrong — is that rows 5..24 are left alone.
    func testASyncBlockNearTheTopLeavesTheBottomAlone() {
        let (terminal, watcher) = makeTerminal(rows: 24)
        terminal.feed(text: "\(esc)[H")  // home
        terminal.clearUpdateRange()

        terminal.feed(text: "\(bsu)\(esc)[3;1Hthird row\(esc)[4;1Hfourth row\(esu)")

        XCTAssertEqual(watcher.framesEnded.count, 1)
        guard let r = watcher.framesEnded[0] else { return XCTFail("the block dirtied nothing at all") }
        XCTAssertEqual(r.endY, 3, "row 4 is the furthest row touched")
        XCTAssertLessThan(
            r.endY - r.startY + 1, 24,
            "the whole point: a two-row write used to repaint all 24")
    }

    func testASyncBlockThatChangesNothingDirtiesNothing() {
        // The old code repainted all 24 rows for this.
        let (terminal, watcher) = makeTerminal(rows: 24)
        terminal.feed(text: "hello")
        terminal.clearUpdateRange()

        terminal.feed(text: "\(bsu)\(esu)")

        XCTAssertEqual(watcher.framesEnded.count, 1)
        XCTAssertNil(watcher.framesEnded[0], "an empty synchronized block has nothing to repaint")
    }

    /// The exception that made the blunt version look safe. A program that opens a block and dies leaves
    /// the screen in a state its own writes do not describe, so recovery repaints everything.
    func testTheSafetyTimeoutStillForcesAFullRepaint() {
        let (terminal, watcher) = makeTerminal(rows: 24)
        terminal.feed(text: "\(bsu)\(esc)[3;1Hhalf an update")  // begins, never ends
        XCTAssertTrue(terminal.synchronizedOutputActive)

        // The timeout is armed on the main queue; pump it rather than sleeping the thread that runs it.
        let deadline = Date().addingTimeInterval(2.5)
        while terminal.synchronizedOutputActive, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(terminal.synchronizedOutputActive, "the safety timer must have fired")

        XCTAssertEqual(watcher.framesEnded.count, 1)
        let r = watcher.framesEnded[0]
        XCTAssertEqual(r?.startY, 0)
        XCTAssertEqual(r?.endY, 23, "recovery repaints every row, exactly as before")
    }

    /// The safety net is one timer reused for the terminal's whole life, parked at `.distantFuture` between
    /// blocks rather than cancelled. A cancelled dispatch source cannot be re-armed, so getting that wrong
    /// disarms the net permanently — and silently, because the *first* block still recovers. This opens and
    /// closes a block first, so the timer under test is a reused one.
    func testTheSafetyTimeoutFiresForABlockOpenedAfterAnEarlierOneClosed() {
        let (terminal, watcher) = makeTerminal(rows: 24)
        terminal.feed(text: "\(bsu)\(esc)[1;1Hfirst frame\(esu)")   // a complete block: parks the timer
        XCTAssertFalse(terminal.synchronizedOutputActive)
        XCTAssertEqual(watcher.framesEnded.count, 1)

        terminal.feed(text: "\(bsu)\(esc)[3;1Hhalf an update")       // begins, never ends
        XCTAssertTrue(terminal.synchronizedOutputActive)

        let deadline = Date().addingTimeInterval(2.5)
        while terminal.synchronizedOutputActive, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(terminal.synchronizedOutputActive, "the reused safety timer must still fire")

        XCTAssertEqual(watcher.framesEnded.count, 2)
        XCTAssertEqual(watcher.framesEnded[1]?.startY, 0)
        XCTAssertEqual(watcher.framesEnded[1]?.endY, 23, "recovery repaints every row")
    }

    /// Real bytes: `tmux -T sync attach` to a pane running btop at 200x50, captured 2026-08-25.
    func testThroughTmuxSyncCorpusRepaintsOnlyWhatChanged() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/btop-through-tmux-sync.raw")
        let data = try Data(contentsOf: url)
        let (terminal, watcher) = makeTerminal(cols: 200, rows: 50)
        terminal.feed(buffer: [UInt8](data)[...])

        let frames = watcher.framesEnded.compactMap { $0 }
        XCTAssertGreaterThan(frames.count, 0, "the capture must actually contain synchronized frames")

        let rowsPerFrame = frames.map { $0.endY - $0.startY + 1 }
        let repainted = rowsPerFrame.reduce(0, +)
        let alwaysFull = frames.count * 50
        // Characterization against a real capture, not a tuned threshold. The old behaviour was exactly
        // `alwaysFull` — every frame, every row — so any real diff at all fails the old code. btop is close
        // to the worst case for this (a dense full-screen TUI); a mostly-static pane does far better.
        XCTAssertLessThan(
            repainted, alwaysFull,
            "every frame repainted the full screen — the accumulated range is being discarded again "
                + "(rows per frame: \(rowsPerFrame))")
        print("corpus: \(frames.count) frames, rows repainted \(repainted) vs \(alwaysFull) before: \(rowsPerFrame)")
    }
}
