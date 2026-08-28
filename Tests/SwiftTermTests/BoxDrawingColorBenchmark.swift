//
//  BoxDrawingColorBenchmark.swift
//
//  What resolving the box-drawing CGColor once per run is worth, on a box-heavy screen, without
//  opening a window. Renders whole frames through `TerminalView.draw(_:)` — so unlike the shaping
//  benchmark this includes the CoreGraphics drawing, which is where box glyphs live.
//
//  The screen is filled with box-drawing characters, one ANSI colour per row: that is what a panelled
//  TUI (btop, lazygit, a bordered table) actually looks like, and it is the shape the per-run memo is
//  built for. A screen where every cell is a different colour would defeat the memo by construction and
//  measure nothing anyone runs.
//
//  Off by default (it is a measurement, not an assertion about the machine it runs on):
//      SWIFTTERM_BOXBENCH=1 swift test --filter BoxDrawingColorBenchmark
//
#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import SwiftTerm

final class BoxDrawingColorBenchmark: XCTestCase {
    @MainActor
    func testBoxDrawingFrameCost() throws {
        guard ProcessInfo.processInfo.environment["SWIFTTERM_BOXBENCH"] == "1" else {
            throw XCTSkip("set SWIFTTERM_BOXBENCH=1 to run")
        }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        view.customBlockGlyphs = true

        let glyphs = Array("─│┌┐└┘├┤┬┴┼━┃┏┓┗┛".unicodeScalars)
        let rows = view.terminal.rows
        let cols = view.terminal.cols
        var screen = ""
        for row in 0..<rows {
            screen += "\u{1b}[\(row + 1);1H\u{1b}[3\((row % 7) + 1)m"
            for col in 0..<cols {
                screen.unicodeScalars.append(glyphs[(row &+ col) % glyphs.count])
            }
        }
        screen += "\u{1b}[0m"
        view.terminal.feed(text: screen)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("no bitmap rep")
        }
        // Warm up: first frame pays for font loading and the initial shaping.
        for _ in 0..<3 { view.cacheDisplay(in: view.bounds, to: rep) }

        let frames = 40
        let start = Date()
        for _ in 0..<frames { view.cacheDisplay(in: view.bounds, to: rep) }
        let elapsed = Date().timeIntervalSince(start)

        print(String(format: "BOXBENCH %dx%d  %d frames  %.1f ms/frame  (%.2f s total)",
                     cols, rows, frames, elapsed / Double(frames) * 1000, elapsed))
    }
}
#endif
