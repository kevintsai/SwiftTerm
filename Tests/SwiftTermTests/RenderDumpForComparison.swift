#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import SwiftTerm

/// Renders a fixed screen and writes it to `SWIFTTERM_DUMP`. Two builds must produce the same bytes.
final class RenderDumpForComparison: XCTestCase {
    @MainActor
    func testDump() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTTERM_DUMP"] else {
            throw XCTSkip("set SWIFTTERM_DUMP=<path>")
        }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let rows = view.terminal.rows
        let cols = view.terminal.cols
        let word = "abcdefgh"
        var screen = ""
        for row in 0..<max(0, rows - 4) {
            screen += "\u{1b}[\(row + 1);1H"
            var col = 0, i = 0
            while col < cols {
                screen += "\u{1b}[3\((row &+ i) % 7 + 1)m" + word
                col += word.count; i += 1
            }
        }
        // Decorations and box glyphs on the last rows, so the skip path is in the picture too.
        screen += "\u{1b}[\(rows - 3);1H\u{1b}[4munderlined text\u{1b}[0m  \u{1b}[9mstruck text\u{1b}[0m"
        screen += "\u{1b}[\(rows - 2);1H\u{1b}[36m┌───────┬───────┐\u{1b}[0m"
        screen += "\u{1b}[\(rows - 1);1H\u{1b}[35m└───────┴───────┘\u{1b}[0m"
        screen += "\u{1b}[0m"
        view.terminal.feed(text: screen)
        view.selectedTextBackgroundColor = .systemPink
        view.selection.setSelection(start: Position(col: 0, row: 2), end: Position(col: 20, row: 2))

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("no bitmap rep")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("no png")
        }
        try data.write(to: URL(fileURLWithPath: path))
        print("DUMPED \(data.count) bytes -> \(path)")
    }
}
#endif
