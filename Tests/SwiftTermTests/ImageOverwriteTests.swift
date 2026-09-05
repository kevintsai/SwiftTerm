//
//  ImageOverwriteTests.swift
//
//  A sixel/iTerm2 picture lives in the cells it was painted over, so text printed there takes it
//  with it.  That is how a TUI erases an image (yazi writes spaces over the preview area and sends
//  nothing else), and it is the rule tmux applies to its own copy.  Erase operations are excluded
//  on purpose - tmux clears each row's tail right after drawing a picture there.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

private final class ProbeImage: TerminalImage {
    var pixelWidth: Int
    var pixelHeight: Int
    var col: Int
    var colSpan: Int

    init(col: Int, colSpan: Int, pixelWidth: Int = 360, pixelHeight: Int = 20) {
        self.col = col
        self.colSpan = colSpan
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

private final class ProbeKittyImage: TerminalImage, KittyPlacementImage {
    var pixelWidth: Int = 360
    var pixelHeight: Int = 20
    var col: Int
    var colSpan: Int
    var kittyIsKitty: Bool = true
    var kittyImageId: UInt32? = 7
    var kittyImageNumber: UInt32?
    var kittyPlacementId: UInt32? = 1
    var kittyZIndex: Int = 0
    var kittyCol: Int = 0
    var kittyRow: Int = 0
    var kittyCols: Int = 0
    var kittyRows: Int = 0
    var kittyPixelOffsetX: Int = 0
    var kittyPixelOffsetY: Int = 0

    init(col: Int, colSpan: Int) {
        self.col = col
        self.colSpan = colSpan
    }
}

final class ImageOverwriteTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// A terminal holding one 36-cell wide picture slice on each of rows 1...13, starting at column
    /// 63 - the shape yazi's preview pane produces in a 100x30 pane.
    private func terminalWithPreviewImage(kitty: Bool = false) -> Terminal {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 100, rows: 30))
        for row in 1...13 {
            let image: TerminalImage = kitty ? ProbeKittyImage(col: 63, colSpan: 36)
                                             : ProbeImage(col: 63, colSpan: 36)
            terminal.buffer.attachImage(image, toLineAt: terminal.buffer.yBase + row)
        }
        return terminal
    }

    private func rowsWithImages(_ terminal: Terminal) -> [Int] {
        let buffer = terminal.buffer
        return (0..<terminal.rows).filter { row in
            let idx = buffer.yBase + row
            guard idx < buffer.lines.count else { return false }
            return buffer.lines[idx].images?.isEmpty == false
        }
    }

    /// yazi's image_erase: park the cursor at the top-left of the preview and write spaces over it.
    private func feedYaziErase(_ terminal: Terminal) {
        for row in 2...14 {
            terminal.feed(text: "\u{1b}[\(row);64H" + String(repeating: " ", count: 36))
        }
    }

    @Test func testPrintedSpacesEraseThePictureUnderThem() {
        let terminal = terminalWithPreviewImage()
        #expect(rowsWithImages(terminal) == Array(1...13))

        feedYaziErase(terminal)

        #expect(rowsWithImages(terminal).isEmpty)
        #expect(terminal.buffer.hasAnyImages == false)
    }

    @Test func testPrintingOutsideTheImageColumnsLeavesItAlone() {
        let terminal = terminalWithPreviewImage()

        // The file list yazi keeps redrawing to the left of the preview.
        for row in 2...14 {
            terminal.feed(text: "\u{1b}[\(row);1H" + String(repeating: "x", count: 62))
        }

        #expect(rowsWithImages(terminal) == Array(1...13))
    }

    @Test func testNonAsciiPrintingErasesTheImageToo() {
        let terminal = terminalWithPreviewImage()

        // Wide characters go through the per-character path, not the ASCII fast path.
        for row in 2...14 {
            terminal.feed(text: "\u{1b}[\(row);64H" + String(repeating: "中", count: 18))
        }

        #expect(rowsWithImages(terminal).isEmpty)
    }

    @Test func testEraseInLineLeavesThePictureStanding() {
        let terminal = terminalWithPreviewImage()

        // tmux repaints a pane by writing the row's text and clearing its tail - which lands on the
        // picture's columns moments after the picture was drawn there.
        for row in 2...14 {
            terminal.feed(text: "\u{1b}[\(row);63Hx\u{1b}[K")
        }

        #expect(rowsWithImages(terminal) == Array(1...13))
    }

    @Test func testEraseCharactersLeaveThePictureStanding() {
        let terminal = terminalWithPreviewImage()

        for row in 2...14 {
            terminal.feed(text: "\u{1b}[\(row);64H\u{1b}[36X")
        }

        #expect(rowsWithImages(terminal) == Array(1...13))
    }

    @Test func testKittyPlacementIsNotErasedByText() {
        let terminal = terminalWithPreviewImage(kitty: true)

        feedYaziErase(terminal)

        #expect(rowsWithImages(terminal) == Array(1...13))
    }

    @Test func testEraseInDisplayToEndDropsThePicturesItCovers() {
        let terminal = terminalWithPreviewImage()

        terminal.feed(text: "\u{1b}[1;1H\u{1b}[J")

        #expect(rowsWithImages(terminal).isEmpty)
    }
}
#endif
