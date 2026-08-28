//
//  TextRunFrameBenchmark.swift
//
//  What the draw loop costs on ordinary coloured text, per frame, through the real `TerminalView.draw(_:)`.
//
//  The screen is filled with short colour runs — a colour change every 8 columns — because the per-run
//  work is what this measures: CoreText hands back one `CTRun` per attribute change, and everything the
//  loop does with a run's attributes is paid once per run, per row, per frame. A screen of one long run
//  would hide exactly the cost in question. Agent output, `ls --color`, a diff, a log with levels — all
//  of them are many short runs.
//
//  Off by default (it is a measurement, not an assertion about the machine it runs on):
//      SWIFTTERM_TEXTBENCH=1 swift test --filter TextRunFrameBenchmark
//
#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import SwiftTerm

final class TextRunFrameBenchmark: XCTestCase {
    @MainActor
    func testColouredTextFrameCost() throws {
        guard ProcessInfo.processInfo.environment["SWIFTTERM_TEXTBENCH"] == "1" else {
            throw XCTSkip("set SWIFTTERM_TEXTBENCH=1 to run")
        }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let rows = view.terminal.rows
        let cols = view.terminal.cols

        let runWidth = Int(ProcessInfo.processInfo.environment["SWIFTTERM_TEXTBENCH_RUNWIDTH"] ?? "8") ?? 8
        let word = String(repeating: "abcdefgh", count: max(1, runWidth / 8)).prefix(runWidth).description
        var screen = ""
        for row in 0..<rows {
            screen += "\u{1b}[\(row + 1);1H"
            var col = 0
            var i = 0
            while col < cols {
                screen += "\u{1b}[3\((row &+ i) % 7 + 1)m" + word
                col += word.count
                i += 1
            }
        }
        screen += "\u{1b}[0m"
        view.terminal.feed(text: screen)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("no bitmap rep")
        }
        for _ in 0..<3 { view.cacheDisplay(in: view.bounds, to: rep) }

        let frames = 40
        let start = Date()
        for _ in 0..<frames { view.cacheDisplay(in: view.bounds, to: rep) }
        let elapsed = Date().timeIntervalSince(start)

        print(String(format: "TEXTBENCH %dx%d  %d runs/row  %d frames  %.1f ms/frame",
                     cols, rows, cols / max(1, word.count), frames, elapsed / Double(frames) * 1000))
    }
}
#endif
