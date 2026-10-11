//
//  KittyPlaceholderScrollBenchmark.swift
//
//  What one frame costs to draw while a kitty unicode-placeholder image scrolls through the screen,
//  through the real `TerminalView.draw(_:)` (CoreGraphics path — the one fleetmux uses).
//
//  Replays a recording of mdview (`TERM=xterm-kitty`, no tmux) held on `j`: the image is transmitted
//  once, then every frame scrolls the content pane one line, so every placeholder row moves. The
//  recording is split at begin-synchronized-update markers; after each frame the whole view is drawn
//  once, which is what a scroll costs (every row is dirty).
//
//  Off by default (it is a measurement, not an assertion about the machine it runs on):
//      SWIFTTERM_KITTY_SCROLL_CORPUS=<recording.raw> swift test --filter KittyPlaceholderScrollBenchmark
//  Optional: SWIFTTERM_KITTY_SCROLL_COLS / _ROWS (default 178×60, the size the recording was made at).
//
#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import SwiftTerm

final class KittyPlaceholderScrollBenchmark: XCTestCase {
    private static let bsu: [UInt8] = Array("\u{1b}[?2026h".utf8)

    @MainActor
    func testScrollingPlaceholderImageFrameCost() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SWIFTTERM_KITTY_SCROLL_CORPUS"] else {
            throw XCTSkip("set SWIFTTERM_KITTY_SCROLL_CORPUS=<recording> to run")
        }
        let cols = Int(env["SWIFTTERM_KITTY_SCROLL_COLS"] ?? "") ?? 178
        let rows = Int(env["SWIFTTERM_KITTY_SCROLL_ROWS"] ?? "") ?? 60
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))

        var frames: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if i + Self.bsu.count <= bytes.count, Array(bytes[i..<(i + Self.bsu.count)]) == Self.bsu {
                if !current.isEmpty { frames.append(current) }
                current = []
            }
            current.append(bytes[i])
            i += 1
        }
        if !current.isEmpty { frames.append(current) }

        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.terminal.resize(cols: cols, rows: rows)
        let cell = view.cellDimension ?? CGSize(width: 8, height: 16)
        view.frame = CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("no bitmap rep")
        }

        var withImage: [Double] = []
        var withoutImage: [Double] = []
        var maxCells = 0
        for frame in frames {
            view.terminal.feed(byteArray: frame)
            let placeholders = placeholderCells(view.terminal)
            let start = Date()
            view.cacheDisplay(in: view.bounds, to: rep)
            let ms = Date().timeIntervalSince(start) * 1000
            if placeholders > 0 {
                withImage.append(ms)
                maxCells = max(maxCells, placeholders)
            } else {
                withoutImage.append(ms)
            }
        }
        func median(_ xs: [Double]) -> Double {
            guard !xs.isEmpty else { return .nan }
            let s = xs.sorted()
            return s[s.count / 2]
        }
        print(String(format: "KITTYSCROLL %dx%d  frames with image %d (up to %d placeholder cells): median %.1f ms  max %.1f ms  |  without image %d: median %.1f ms",
                     cols, rows, withImage.count, maxCells, median(withImage), withImage.max() ?? .nan,
                     withoutImage.count, median(withoutImage)))
    }

    /// 畫面上有幾格 kitty placeholder（U+10EEEE 開頭的格子）
    private func placeholderCells(_ terminal: Terminal) -> Int {
        let buffer = terminal.displayBuffer
        var n = 0
        for row in 0..<terminal.rows {
            let line = buffer.lines[buffer.yDisp + row]
            for col in 0..<terminal.cols {
                if terminal.getCharacter(for: line[col]).unicodeScalars.first?.value == 0x10EEEE { n += 1 }
            }
        }
        return n
    }
}
#endif
