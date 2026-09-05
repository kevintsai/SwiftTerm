//
//  SixelPreviewEraseTests.swift
//
//  Real bytes: `tmux -L … attach` to a pane running yazi 26.9.1 at 100x30, hovering a PNG and then
//  moving off it, captured 2026-09-06.  yazi picks the sixel driver here (tmux advertises sixel), so
//  the preview arrives as a DCS picture and is retired by writing spaces over the cells it covers -
//  no escape sequence says "delete that image".  Between the two, tmux repaints the pane and clears
//  each row's tail with EL, right on top of the picture it just drew; honouring that would wipe
//  every preview the instant it appeared.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
final class SixelPreviewEraseTests {
    /// Offset in the capture where yazi has drawn the preview and tmux has finished repainting
    /// around it; everything after it is the move to the next file, which erases the preview.
    private static let eraseStartsAt = 45291

    private func rowsWithImages(_ terminal: Terminal) -> [Int] {
        let buffer = terminal.buffer
        return (0..<terminal.rows).filter { row in
            let idx = buffer.yBase + row
            guard idx < buffer.lines.count else { return false }
            return buffer.lines[idx].images?.isEmpty == false
        }
    }

    private func capture() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/yazi-sixel-preview-through-tmux.raw")
        return [UInt8](try Data(contentsOf: url))
    }

    /// The rows yazi wrote its preview onto, and the ones it later writes spaces over.  How far the
    /// picture reaches below them depends on this view's cell height, which is a property of the
    /// test font rather than of the capture - so the assertions stay on the rows yazi addressed.
    private static let previewRows = Array(1...13)

    @Test func testPreviewSurvivesTheRepaintAndGoesWhenYaziErasesIt() throws {
        let bytes = try capture()
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        view.resize(cols: 100, rows: 30)

        view.feed(byteArray: bytes[0..<Self.eraseStartsAt])
        let drawn = Set(rowsWithImages(view.getTerminal()))
        #expect(Self.previewRows.allSatisfy { drawn.contains($0) },
                "the sixel preview must still be on screen after tmux repaints around it")

        view.feed(byteArray: bytes[Self.eraseStartsAt...])
        let left = Set(rowsWithImages(view.getTerminal()))
        #expect(Self.previewRows.allSatisfy { !left.contains($0) },
                "moving off the image erases the preview cells, which takes the picture with them")
    }
}
#endif
