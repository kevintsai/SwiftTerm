// The runs a frame's changes fall into — the input to "one rect per run instead of one band".
//
// The band is what a single `setNeedsDisplay` can express, and it is a lie about cost whenever a frame
// touches two ends of the pane: the rows between them get cleared and repainted for nothing. Measured in
// the field (fleetmux, 2026-09-09): a 66-row pane repainting all 66 rows 9–12 times a second while the row
// cache said most of those rows had not changed; the two-ends benchmark puts the same shape at −51% draw
// time and 7.5× fewer rows painted.
//
// These tests pin the split itself: where a run starts and ends, that padding does not silently glue two
// runs together, and that "nothing changed" still means nothing changed.

import AppKit
import XCTest

@testable import SwiftTerm

@MainActor
final class ChangedRowRunsTests: XCTestCase {
    private func makeView(cols: Int = 40, rows: Int = 20) -> TerminalView {
        let v = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        v.getTerminal().resize(cols: cols, rows: rows)
        return v
    }

    /// Paint everything once so the row cache knows what is on screen; after that only what we type changes.
    private func settle(_ v: TerminalView) {
        v.updateDisplay(notifyAccessibility: false)
        v.displayIfNeeded()
        v.display()
    }

    func testTwoSeparatedChangesAreTwoRunsNotOneBand() {
        let v = makeView(rows: 20)
        v.feed(text: "\u{1b}[2J")
        settle(v)
        // Row 3 and row 18 change; the rows between them do not.
        v.feed(text: "\u{1b}[3;1Htop\u{1b}[18;1Hbottom")
        v.getTerminal().clearUpdateRange()
        guard let runs = v.visuallyChangedRowRuns(rowStart: 0, rowEnd: 19) else {
            return XCTFail("兩列變了，不該回 nil")
        }
        XCTAssertEqual(runs.count, 2, "兩端各一段 → 兩個矩形，不是一條蓋住整格的帶子：\(runs)")
        XCTAssertTrue(runs[0].upperBound < runs[1].lowerBound, "runs 必須不重疊且遞增：\(runs)")
        let painted = runs.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(painted, 10, "只變兩列，卻要畫 \(painted) 列——帶子又回來了")
        // The band answer is the collapsed one, and must still be the union.
        let band = v.visuallyChangedRowBand(rowStart: 0, rowEnd: 19)
        XCTAssertEqual(band?.lowerBound, runs.first?.lowerBound)
        XCTAssertEqual(band?.upperBound, runs.last?.upperBound)
    }

    func testAdjacentChangesStayOneRun() {
        let v = makeView(rows: 20)
        v.feed(text: "\u{1b}[2J")
        settle(v)
        v.feed(text: "\u{1b}[8;1Ha\u{1b}[9;1Hb")   // two rows that touch
        v.getTerminal().clearUpdateRange()
        let runs = v.visuallyChangedRowRuns(rowStart: 0, rowEnd: 19)
        XCTAssertEqual(runs?.count, 1, "相鄰的變動不該拆成兩個矩形（padding 之後它們本來就相接）：\(String(describing: runs))")
    }

    func testNothingChangedIsStillNil() {
        let v = makeView(rows: 20)
        v.feed(text: "\u{1b}[2J\u{1b}[5;1Hhello")
        settle(v)
        XCTAssertNil(v.visuallyChangedRowRuns(rowStart: 0, rowEnd: 19),
                     "沒有任何一列變 → 不該要求重畫任何東西")
    }
}
