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
        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(data: nil,
                                  width: pixelWidth,
                                  height: pixelHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
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
#endif
