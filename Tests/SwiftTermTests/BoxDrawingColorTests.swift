//
//  BoxDrawingColorTests.swift
//
//  `drawBoxDrawings` resolves one `CGColor` and reuses it while the colour holds, because
//  `NSColor.cgColor` allocates on every call and a box-drawn frame is overwhelmingly one colour
//  repeated across the row. The failure that buys is a stale colour: cells drawn in whatever colour the
//  row started with, no matter what the program asked for afterwards.
//
//  That is a picture, not an object identity, so it is checked in pixels.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class BoxDrawingColorTests {
    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.customBlockGlyphs = true   // the path under test; false hands the glyphs back to the font
        return view
    }

    /// Every pixel, so the assertions do not depend on where a cell landed.
    private func pixels(_ view: TerminalView) -> [(r: CGFloat, g: CGFloat, b: CGFloat)] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        var out: [(CGFloat, CGFloat, CGFloat)] = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                out.append((c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return out
    }

    @Test func aColourChangeMidRowIsNotPaintedInThePreviousColour() throws {
        let view = makeView()
        // Horizontal box-drawing runs: red, then green, then red again — so a memo that never
        // invalidates and one that invalidates but never recovers both show up.
        view.terminal.feed(text: "\u{1b}[31m\u{2500}\u{2500}\u{2500}\u{1b}[32m\u{2500}\u{2500}\u{2500}\u{1b}[31m\u{2500}\u{2500}\u{2500}\u{1b}[0m")

        let seen = pixels(view)
        #expect(!seen.isEmpty, "nothing rendered")

        let reds = seen.filter { $0.r > 0.4 && $0.r > $0.g + 0.2 && $0.r > $0.b + 0.2 }
        let greens = seen.filter { $0.g > 0.4 && $0.g > $0.r + 0.2 && $0.g > $0.b + 0.2 }

        #expect(!reds.isEmpty, "the red run was not painted red")
        #expect(!greens.isEmpty, "the green run was painted in the row's first colour — a stale CGColor")
    }

    /// The colours the box glyphs are drawn in must be the palette's, so changing the palette changes
    /// the picture. Pins that the resolved colour is read per draw and not held across frames.
    @Test func aPaletteChangeRepaintsTheGlyphsInTheNewColour() throws {
        let view = makeView()
        view.terminal.feed(text: "\u{1b}[31m\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{1b}[0m")
        let before = pixels(view).filter { $0.r > 0.4 && $0.r > $0.g + 0.2 && $0.r > $0.b + 0.2 }
        #expect(!before.isEmpty, "the premise: ANSI red must be red to start with")

        var colors = view.terminal.ansiColors
        colors[1] = Color(red: 0, green: 0, blue: 65535)     // ANSI 1 is now blue
        view.installColors(Array(colors.prefix(16)))

        let after = pixels(view)
        let stillRed = after.filter { $0.r > 0.4 && $0.r > $0.g + 0.2 && $0.r > $0.b + 0.2 }
        let blues = after.filter { $0.b > 0.4 && $0.b > $0.r + 0.2 && $0.b > $0.g + 0.2 }
        #expect(blues.count > 0, "the new palette entry did not reach the box glyphs")
        #expect(stillRed.isEmpty, "glyphs kept the old palette colour")
    }
}
#endif
