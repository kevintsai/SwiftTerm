//
//  MacTerminalSurface.swift
//
//  The view's own backing store, and the reason it has to own one.
//
//  A pane that is streaming scrolls on nearly every frame, and a scroll moves almost every pixel on
//  screen without changing what they depict: measured on a real tmux capture, 24 of 24 rows are
//  repainted while 2 carry new content (fleetmux spec 27 §5, `ScrollBlitCeilingTests`). The way out is
//  to move those pixels instead of re-rendering them — but AppKit will not do it for us:
//  `NSView.scroll(_:by:)` on a layer-backed view (which `TerminalView` is) makes AppKit ask for the
//  whole view again, measured in `ScrollBlitFeasibilitySpike`. So the pixels have to live somewhere we
//  can move them, which means the view owns a bitmap and hands it to the screen.
//
//  **This file is only the surface.** Painting into it produces exactly what painting into AppKit's
//  backing store produced — same rows, same rects, same order — so that the move-instead-of-repaint
//  step lands on top of something already proven pixel-identical. `usesOwnSurface = false` restores the
//  direct-to-AppKit path, which is how the render tests get a control arm.
//

#if os(macOS)
import AppKit
import CoreGraphics

extension TerminalView {
    /// The bitmap the terminal is painted into, recreated when the geometry or the display scale moves.
    ///
    /// Returns `nil` when no surface can be made (zero-sized view, allocation failure); every caller
    /// falls back to painting straight into the view's context, so a failure here costs performance and
    /// never correctness.
    func ensureSurface() -> (surface: CGContext, isFresh: Bool)? {
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width >= 1, size.height >= 1 else { return nil }

        if let existing = surface, surfaceSize == size, surfaceScale == scale {
            return (existing, false)
        }
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())

        if presentsViaLayerContents, let made = makeLayerBackedSurface(pixelWidth, pixelHeight, scale) {
            surface = made
            surfaceSize = size
            surfaceScale = scale
            surfaceNeedsFullRepaint = true
            forgetRowsOnScreen()
            return (made, true)
        }

        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(data: nil,
                                  width: pixelWidth,
                                  height: pixelHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  // Host-native BGRA. CoreGraphics keeps its fast paths for this layout
                                  // only; the big-endian ARGB this first asked for made every fill and
                                  // blit take a software path — measured 1.45x slower on the same work.
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            surface = nil
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        surface = ctx
        surfaceSize = size
        surfaceScale = scale
        // A fresh surface holds nothing, so nothing on screen can be vouched for either — otherwise the
        // next frame would "keep" rows that were never painted into this bitmap.
        forgetRowsOnScreen()
        return (ctx, true)
    }

    /// Paint `rect` of the terminal into the surface.
    ///
    /// `NSGraphicsContext.current` has to be set, not just the `CGContext` passed along: the image paths
    /// inside `drawTerminalContents` draw through `NSImage`, which reads the current context.
    func paintIntoSurface(_ rect: CGRect, _ ctx: CGContext, bufferOffset: Int) {
        guard !rect.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        drawTerminalContents(dirtyRect: rect, context: ctx, bufferOffset: bufferOffset)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// Put the surface on screen, clipped to the rects AppKit asked for.
    ///
    /// One `draw` of the whole image rather than one per rect: the clip already limits what lands, and
    /// the image is a snapshot of the same bitmap either way.
    func presentSurface(_ ctx: CGContext, into viewContext: CGContext, clippedTo rects: [CGRect]) {
        guard let image = ctx.makeImage(), !rects.isEmpty else { return }
        viewContext.saveGState()
        viewContext.clip(to: rects)
        viewContext.interpolationQuality = .none
        viewContext.draw(image, in: bounds)
        viewContext.restoreGState()
    }
}

extension TerminalView {
    /// Move the pixels that only scrolled, instead of re-rendering them.
    ///
    /// Returns the number of screen rows the surface was shifted by, or 0 if nothing was moved.
    ///
    /// **How the shift is found**: by line identity. `rowsOnScreen` records which `BufferLine` is painted
    /// at each screen row; if the line now at row `y` is the one that was recorded at `y + d` for the same
    /// `d` across most rows, the display scrolled by `d`. That is the same signal the row cache keys on,
    /// so the two cannot disagree about what moved.
    ///
    /// **Why a majority and not all rows**: a DECSTBM region scrolls only part of the pane (tmux keeps a
    /// status line out of it). Shifting the whole surface then moves rows that did not scroll — which is
    /// safe, because their records move with them, stop matching, and they get repainted. It costs a
    /// couple of extra rows, not correctness.
    ///
    /// **Why an integral row height is required**: the shift is a byte move, so a row has to be a whole
    /// number of pixels. `cellHeight` is already `ceil`'d and macOS scales are 1 or 2, so this holds in
    /// practice; when it does not, the guard simply declines and every row is repainted as before.
    func blitScrolledPixels() -> Int {
        guard usesOwnSurface, blitsScrolledPixels, let ctx = surface, !rowsOnScreen.isEmpty else { return 0 }
        let rowPixels = cellDimension.height * surfaceScale
        guard rowPixels >= 1, abs(rowPixels - rowPixels.rounded()) < 0.001 else { return 0 }
        let rowPx = Int(rowPixels.rounded())

        let buffer = terminal.displayBuffer
        let rows = terminal.rows
        var current: [Int: ObjectIdentifier] = [:]
        for y in 0..<rows {
            let absolute = buffer.yDisp + y
            guard absolute >= 0, absolute < buffer.lines.count else { continue }
            current[y] = ObjectIdentifier(buffer.lines[absolute])
        }
        guard !current.isEmpty else { return 0 }

        var votes: [Int: Int] = [:]
        for (y, id) in current {
            for (prevY, prev) in rowsOnScreen where ObjectIdentifier(prev.lineRef) == id {
                let d = prevY - y
                if d != 0 { votes[d, default: 0] += 1 }
            }
        }
        // A shift has to explain most of the screen. A couple of coincidentally equal lines (two blank
        // rows) must not be enough to move the whole surface.
        guard let (shift, agreeing) = votes.max(by: { $0.value < $1.value }),
              agreeing * 2 > rows, abs(shift) < rows else { return 0 }

        let moveRows = rows - abs(shift)
        guard moveRows > 0, let data = ctx.data else { return 0 }
        let bytesPerRow = ctx.bytesPerRow
        let height = ctx.height
        let moveBytes = moveRows * rowPx * bytesPerRow
        let offsetBytes = abs(shift) * rowPx * bytesPerRow
        guard moveBytes > 0, offsetBytes + moveBytes <= height * bytesPerRow else { return 0 }

        // Screen row 0 is the top of the image, which is the first row in the bitmap's memory. Content
        // moving UP the screen (`shift > 0`: the line that was at row `shift` is now at row 0) therefore
        // moves toward lower addresses.
        if shift > 0 {
            memmove(data, data.advanced(by: offsetBytes), moveBytes)
        } else {
            memmove(data.advanced(by: offsetBytes), data, moveBytes)
        }

        // The records move with the pixels, so the rows that scrolled now compare equal and drop out of
        // the invalidation. A row whose shaped output encodes its position (a kitty placeholder) is the
        // one thing that cannot be reused at a different row, so its record is dropped instead of moved.
        var moved: [Int: RowOnScreen] = [:]
        for (prevY, record) in rowsOnScreen {
            let newY = prevY - shift
            guard newY >= 0, newY < rows else { continue }
            if rowDrawCache[ObjectIdentifier(record.lineRef)]?.positionDependent == true { continue }
            moved[newY] = record
        }
        rowsOnScreen = moved
        blitCount += 1
        blitRows += moveRows
        return shift
    }
}

extension TerminalView {
    /// Record what the surface still needs painted, and ask AppKit for what the screen still needs.
    ///
    /// These are the same set until a blit happens, and different afterwards — the whole point of the
    /// surface. The screen needs everything (AppKit's backing store did not scroll); the surface needs
    /// only the rows that actually changed.
    func queueSurfacePaintAndInvalidate(_ runs: [ClosedRange<Int>],
                                        nothingChanged: Bool,
                                        blitted: Int,
                                        rect: (ClosedRange<Int>) -> CGRect) {
        if !nothingChanged {
            for run in runs {
                let r = rect(run)
                surfacePaintRows += run.count
                if usesOwnSurface { pendingSurfacePaint.append(r) }
                if blitted == 0 { setNeedsDisplay(r) }
            }
        }
        if blitted != 0 {
            surfaceMovedPixelsThisCycle = true
            // Everything moved on screen, so everything has to be put back — even the rows that were
            // not repainted. Skipping this is precisely the ghosting bug this design has to avoid.
            setNeedsDisplay(bounds)
        }
    }
}

extension TerminalView {
    /// A surface the compositor samples directly: an `IOSurface` with a `CGContext` over its memory.
    ///
    /// No copy anywhere in the frame — not `makeImage()`, not a blit into the view's context. The layer
    /// is told to stop managing its own contents (`.never`), because the contents are ours now.
    ///
    /// Single-buffered on purpose. Double buffering would mean copying the front buffer into the back
    /// one every frame to keep incremental painting valid, which is the very cost this exists to remove.
    /// The exposure is a torn frame if the compositor samples mid-paint; a terminal repaints the torn
    /// rows on the next frame anyway, and the alternative gives back the entire win.
    func makeLayerBackedSurface(_ pixelWidth: Int, _ pixelHeight: Int, _ scale: CGFloat) -> CGContext? {
        guard pixelWidth > 0, pixelHeight > 0, let layer else { return nil }
        guard let io = IOSurface(properties: [
            .width: pixelWidth,
            .height: pixelHeight,
            .bytesPerElement: 4,
            .pixelFormat: UInt32(0x42475241),   // 'BGRA', the layout CoreGraphics has fast paths for
        ]) else { return nil }
        io.lock(options: [], seed: nil)
        let ctx = CGContext(data: io.baseAddress,
                            width: pixelWidth,
                            height: pixelHeight,
                            bitsPerComponent: 8,
                            bytesPerRow: io.bytesPerRow,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        io.unlock(options: [], seed: nil)
        guard let ctx else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        surfaceIOSurface = io
        layerContentsRedrawPolicy = .never
        layer.contentsScale = scale
        layer.contents = io
        return ctx
    }

    /// Paint whatever is outstanding into the surface and let the compositor know it changed.
    ///
    /// Called from `updateDisplay` rather than from `draw(_:)`: with `.never` AppKit no longer asks us
    /// to draw, because it is not managing these pixels any more.
    func renderIntoLayerSurface(bufferOffset: Int) {
        guard presentsViaLayerContents, usesOwnSurface else { return }
        guard let (ctx, isFresh) = ensureSurface() else { return }
        let full = isFresh || surfaceNeedsFullRepaint
        let toPaint = full ? [bounds] : pendingSurfacePaint
        surfaceNeedsFullRepaint = false
        pendingSurfacePaint.removeAll(keepingCapacity: true)
        surfaceMovedPixelsThisCycle = false
        guard !toPaint.isEmpty else { return }
        for r in toPaint {
            paintIntoSurface(r.intersection(bounds), ctx, bufferOffset: bufferOffset)
        }
        // Re-assigning is how CA is told this surface holds a new frame; it does not copy it.
        layer?.contents = surfaceIOSurface
    }
}

extension TerminalView {
    /// The surface's pixels, for tests that need to compare what was painted rather than what reached
    /// the screen — B2 never goes through `draw(_:)`, so a harness that captures drawing sees nothing.
    /// Repacked to tight rows on the way out: an `IOSurface` and a `CGBitmapContext` pad their rows
    /// differently, so raw buffers of the same image are not the same length and comparing them
    /// reports "different size" instead of "different picture".
    var surfacePixelsForTesting: (bytes: Data, bytesPerRow: Int, height: Int)? {
        guard let ctx = surface, let data = ctx.data else { return nil }
        let tight = ctx.width * 4
        var out = Data(capacity: tight * ctx.height)
        for y in 0..<ctx.height {
            out.append(Data(bytes: data.advanced(by: y * ctx.bytesPerRow), count: tight))
        }
        return (out, tight, ctx.height)
    }
}

#endif
