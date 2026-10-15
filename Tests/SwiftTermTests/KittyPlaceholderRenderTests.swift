//
//  KittyPlaceholderRenderTests.swift
//
//  Kitty unicode-placeholder images through the real CoreGraphics draw path (`draw(_:)`):
//
//  1. the right part of the image lands in the right cell (drawing one run per row with a resampled
//     image must put the same pixels where per-cell drawing of the source did);
//  2. a view that has been drawing all along — row cache warm, resampled images cached — draws exactly
//     what a fresh view replayed to the same state draws, across the things that could make either cache
//     stale: the image scrolling (rows reused at another position) and a new image under the same id.
//

#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class KittyPlaceholderRenderTests {
    private let imageId: UInt32 = 0x0A0B0C

    /// A PNG whose top half is split `left` | `right` and whose bottom half is `bottom` —
    /// so a cell shows the wrong part both if columns and if rows (orientation) come out wrong.
    private func twoColourPNG(width: Int, height: Int, left: CGColor, right: CGColor, bottom: CGColor? = nil) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext's origin is bottom-left: the top half is y ∈ [height/2, height)
        ctx.setFillColor(left)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(right)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        if let bottom {
            ctx.setFillColor(bottom)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    /// Transmit `png` as a virtual placement of `cols × rows` cells under `imageId`
    private func transmit(_ png: Data, cols: Int, rows: Int) -> String {
        "\u{1b}_Ga=T,U=1,f=100,i=\(imageId),c=\(cols),r=\(rows),q=2;\(png.base64EncodedString())\u{1b}\\"
    }

    /// Placeholder text for image row `r`, `cols` cells wide, starting at the cursor (fg = image id;
    /// first cell carries row + column diacritics, the rest are bare and inherit from the left)
    private func placeholderRow(_ r: Int, cols: Int) -> String {
        let fg = "\u{1b}[38;2;\(imageId >> 16 & 0xff);\(imageId >> 8 & 0xff);\(imageId & 0xff)m"
        let rowMark = Character(Unicode.Scalar(KittyPlaceholder.diacritics[r])!)
        let colMark = Character(Unicode.Scalar(KittyPlaceholder.diacritics[0])!)
        var s = fg + "\u{10EEEE}" + String(rowMark) + String(colMark)
        s += String(repeating: "\u{10EEEE}", count: cols - 1)
        return s + "\u{1b}[0m"
    }

    private func makeView() -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        view.terminal.resize(cols: 20, rows: 8)
        return view
    }

    private func render(_ view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Colour at the centre of screen cell (col, row)
    private func colour(_ rep: NSBitmapImageRep, _ view: TerminalView, col: Int, row: Int) -> NSColor {
        let cell = view.cellDimension!
        let sx = CGFloat(rep.pixelsWide) / view.bounds.width
        let sy = CGFloat(rep.pixelsHigh) / view.bounds.height
        // Row 0 is the top of the view; the bitmap's y = 0 is its top row of pixels
        let x = Int((CGFloat(col) + 0.5) * cell.width * sx)
        let y = Int((CGFloat(row) + 0.5) * cell.height * sy)
        return rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    private let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    // Colour management shifts the pure primaries a little (red reads ~1.0/0.1/0.0): "this channel
    // dominates" is the question, not exact values
    private func isRed(_ c: NSColor) -> Bool { c.redComponent > 0.8 && c.blueComponent < 0.35 && c.greenComponent < 0.35 }
    private func isBlue(_ c: NSColor) -> Bool { c.blueComponent > 0.8 && c.redComponent < 0.35 && c.greenComponent < 0.35 }
    private func isGreen(_ c: NSColor) -> Bool { c.greenComponent > 0.8 && c.redComponent < 0.35 && c.blueComponent < 0.35 }

    /// The image (8 × 2 cells) at rows 1–2, column 2
    private func showImage(_ view: TerminalView, left: CGColor, right: CGColor, bottom: CGColor? = nil) {
        let cell = view.cellDimension!
        let png = twoColourPNG(width: Int(cell.width * 8), height: Int(cell.height * 2), left: left, right: right, bottom: bottom)
        view.terminal.feed(text: transmit(png, cols: 8, rows: 2))
        view.terminal.feed(text: "\u{1b}[2;3H" + placeholderRow(0, cols: 8))
        view.terminal.feed(text: "\u{1b}[3;3H" + placeholderRow(1, cols: 8))
    }

    @Test func eachCellShowsItsPartOfTheImage() {
        let view = makeView()
        showImage(view, left: red, right: blue, bottom: green)
        let rep = render(view)
        // Image row 0 (screen row 1): red | blue. Image row 1 (screen row 2): green — upside down would swap them
        for col in 2..<6 { #expect(isRed(colour(rep, view, col: col, row: 1)), "cell \(col),1") }
        for col in 6..<10 { #expect(isBlue(colour(rep, view, col: col, row: 1)), "cell \(col),1") }
        for col in 2..<10 { #expect(isGreen(colour(rep, view, col: col, row: 2)), "cell \(col),2") }
        // Outside the placement nothing of the image is drawn
        #expect(!isRed(colour(rep, view, col: 1, row: 1)))
        #expect(!isBlue(colour(rep, view, col: 10, row: 1)))
        #expect(!isRed(colour(rep, view, col: 3, row: 3)))
    }

    @Test func aWarmViewDrawsWhatAColdOneDraws() {
        // Every step is applied to both; the warm view renders after each step (caches full of
        // assumptions), the cold one is rebuilt from scratch and rendered once. Pixels must match.
        let steps: [(String, (TerminalView) -> Void)] = [
            ("show the image", { self.showImage($0, left: self.red, right: self.blue) }),
            ("scroll one line", { $0.terminal.feed(text: "\u{1b}[8;1H\n") }),
            ("scroll back down (reverse index at the top)", { $0.terminal.feed(text: "\u{1b}[1;1H\u{1b}M") }),
            ("scroll up again", { $0.terminal.feed(text: "\u{1b}[8;1H\n") }),
            ("new image under the same id", { v in
                let cell = v.cellDimension!
                let png = self.twoColourPNG(width: Int(cell.width * 8), height: Int(cell.height * 2),
                                            left: self.green, right: self.green)
                v.terminal.feed(text: self.transmit(png, cols: 8, rows: 2))
            }),
        ]
        let warm = makeView()
        var applied: [(TerminalView) -> Void] = []
        for (name, step) in steps {
            step(warm)
            applied.append(step)
            let warmRep = render(warm)
            let cold = makeView()
            for s in applied { s(cold) }
            let coldRep = render(cold)
            #expect(warmRep.representation(using: .png, properties: [:]) == coldRep.representation(using: .png, properties: [:]),
                    "after: \(name)")
        }
        // And the last step really changed the picture (otherwise the comparison proves nothing)
        let rep = render(warm)
        var sawGreen = false
        for row in 0..<warm.terminal.rows {
            for col in 2..<10 where isGreen(colour(rep, warm, col: col, row: row)) { sawGreen = true }
        }
        #expect(sawGreen, "the re-transmitted image is drawn")
    }

    /// A PNG of 1-pixel black / white stripes: vertical in the left half, horizontal in the right —
    /// any resampling on the way (down and back up) turns either half grey
    private func stripesPNG(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 0, to: width / 2, by: 2) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: height)) }
        for y in stride(from: 0, to: height, by: 2) { ctx.fill(CGRect(x: width / 2, y: y, width: width - width / 2, height: 1)) }
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// Share of neighbouring pixels that still alternate black / white (left half along a row, right
    /// half down a column): 1 = sharp, ~0 = grey
    private func stripeContrast(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var sharp = 0, pairs = 0
        for y in 0..<(h - 1) {
            for x in 0..<(w / 2 - 1) {
                pairs += 1
                if abs(Int(px[y * w + x]) - Int(px[y * w + x + 1])) > 160 { sharp += 1 }
            }
            for x in (w / 2)..<w {
                pairs += 1
                if abs(Int(px[y * w + x]) - Int(px[(y + 1) * w + x])) > 160 { sharp += 1 }
            }
        }
        return Double(sharp) / Double(pairs)
    }

    /// The image as the view draws it in an app: inside a window, through its backing layer, at 2x.
    /// There AppKit keeps the device scale in the context's base transform — `context.ctm` reads 1
    /// while a point is 2 device pixels — so a scale taken from the CTM resampled the image to half
    /// resolution and the screen blew it back up: blurry. `cacheDisplay` (the other tests) exposes the
    /// scale in the CTM and cannot see this. Returns the resampled copy the view blits, and the scale.
    private func drawThroughWindowLayer(png: (CGSize) -> Data) throws -> (TTImage, CGFloat, CGSize) {
        let view = makeView()
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let scale = window.backingScaleFactor
        try #require(scale >= 2, "needs a 2x screen to mean anything (backingScaleFactor = \(scale))")
        let cell = view.cellDimension!
        let points = CGSize(width: cell.width * 8, height: cell.height * 2)
        view.terminal.feed(text: transmit(png(CGSize(width: points.width * scale, height: points.height * scale)), cols: 8, rows: 2))
        view.terminal.feed(text: "\u{1b}[2;3H" + placeholderRow(0, cols: 8))
        view.terminal.feed(text: "\u{1b}[3;3H" + placeholderRow(1, cols: 8))
        // The draw AppKit performs for a window-hosted, layer-backed view
        let layer = try #require(view.layer)
        layer.setNeedsDisplay()
        layer.displayIfNeeded()
        let image = try #require(view.kittyPlaceholderImages.scaledImage(imageId: imageId), "the image was drawn")
        return (image, scale, points)
    }

    @Test func anImageIsResampledToDevicePixelsWhenDrawnThroughAWindowLayer() throws {
        let (image, scale, points) = try drawThroughWindowLayer { size in
            self.twoColourPNG(width: Int(size.width), height: Int(size.height), left: self.red, right: self.blue)
        }
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == Int((points.width * scale).rounded()), "width \(cg.width) device pixels")
        #expect(cg.height == Int((points.height * scale).rounded()), "height \(cg.height) device pixels")
    }

    @Test func anImageWithOnePixelPerDevicePixelStaysSharpThroughAWindowLayer() throws {
        let (image, _, _) = try drawThroughWindowLayer { size in
            self.stripesPNG(width: Int(size.width), height: Int(size.height))
        }
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let contrast = stripeContrast(cg)
        #expect(contrast > 0.99, "\(Int(contrast * 100))% of neighbouring pixels keep the 1 px stripes")
    }

    @Test func resamplingToTheSourceSizeKeepsEveryPixel() {
        // The cache's own resample, isolated from the view: at 1:1 it must be a copy
        let cache = KittyPlaceholderImageCache()
        let png = stripesPNG(width: 64, height: 32)
        let stored = KittyGraphicsImage(payload: .png(png), byteSize: png.count, lastAccessTick: 1, revision: 1)
        let image = cache.image(imageId: 1, stored: stored, pixelWidth: 64, pixelHeight: 32, size: CGSize(width: 32, height: 16),
                                colorSpace: CGColorSpaceCreateDeviceRGB())
        let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #expect(cg.map { stripeContrast($0) } == 1.0)
    }

    @Test func theImageCacheIsBoundedByTheImageStore() {
        let cache = KittyPlaceholderImageCache()
        let state = KittyGraphicsState()
        let png = twoColourPNG(width: 16, height: 8, left: red, right: blue)
        let stored = KittyGraphicsImage(payload: .png(png), byteSize: png.count, lastAccessTick: 1, revision: 1)
        state.imagesById[7] = stored
        #expect(cache.image(imageId: 7, stored: stored, pixelWidth: 32, pixelHeight: 16, size: CGSize(width: 16, height: 8),
                             colorSpace: CGColorSpaceCreateDeviceRGB()) != nil)
        cache.prune(keeping: state)
        #expect(cache.count == 1, "still in the store")
        state.imagesById[7] = nil
        cache.prune(keeping: state)
        #expect(cache.count == 0, "deleted from the store → dropped")
    }
}
#endif
