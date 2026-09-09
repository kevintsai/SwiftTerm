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

    /// The rect a run of changed screen rows is painted through — the ONE definition of it.
    ///
    /// A run is painted wider than the rows it names: one cell below for descenders and tall unicode that
    /// reach out of their own row, and all the way to the bottom edge when the run ends at the last row.
    /// Every path that paints a run has to use this same rect, or the swap chain's buffers paint different
    /// amounts for the same recorded rows and disagree at run edges.
    func rowRunInvalidationRect(_ run: ClosedRange<Int>) -> CGRect {
        let baseLine = frame.height
        var region = CGRect(x: 0,
                            y: baseLine - (cellDimension.height + CGFloat(run.upperBound) * cellDimension.height),
                            width: frame.width,
                            height: CGFloat(run.upperBound - run.lowerBound + 1) * cellDimension.height)
        if run.upperBound == terminal.rows - 1 {
            // The last row also owns the sub-cell remainder below it.
            region = CGRect(x: 0, y: 0, width: frame.width, height: region.height + region.origin.y)
        } else {
            let newY = max(0, region.origin.y - cellDimension.height)
            region = CGRect(x: 0, y: newY, width: frame.width, height: region.maxY - newY)
        }
        return region
    }

    /// Adjacent and overlapping rows merged into runs, ascending. Two rects that touch are one rect's work.
    func coalescedRowRuns(_ rows: Set<Int>) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for row in rows.sorted() {
            if let last = out.last, row <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, row)
            } else {
                out.append(row...row)
            }
        }
        return out
    }

    /// The buffer this frame is being painted into — the one about to be handed to the compositor.
    var currentSurfaceBuffer: TerminalSurfaceBuffer? {
        guard surfaceChainIndex >= 0, surfaceChainIndex < surfaceChain.count else { return nil }
        return surfaceChain[surfaceChainIndex]
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
        guard moveRows > 0, ctx.data != nil else { return 0 }
        let moveBytes = moveRows * rowPx * ctx.bytesPerRow
        let offsetBytes = abs(shift) * rowPx * ctx.bytesPerRow
        guard moveBytes > 0, offsetBytes + moveBytes <= ctx.height * ctx.bytesPerRow else { return 0 }

        // Move the buffer we are painting into; the others record the scroll and apply it when their
        // turn comes (`catchUpSurface`), so no surface is written while it may still be on screen.
        withSurfaceLocked { shiftSurfaceBytes(ctx, by: shift) }
        // What this buffer still owes moved with its pixels. Its debt is named in screen rows, and the
        // screen just moved under it.
        if let front = currentSurfaceBuffer {
            front.owed = shiftedRows(front.owed, by: shift)
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
        // Once per frame, scroll and rows together — see `TerminalSurfaceBuffer.pending`.
        recordFrameOnIdleBuffers(shift: blitted, rows: nothingChanged ? [] : runs)
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
    /// A chain of them, not one. The first cut was single-buffered on the theory that double buffering
    /// means copying the front buffer into the back one every frame — true when every frame repaints
    /// everything, and false here: a buffer catches up by replaying the memmoves and the handful of rows
    /// it missed. Writing into the surface the compositor is sampling is what the single buffer actually
    /// bought, and that is the flicker.
    func makeLayerBackedSurface(_ pixelWidth: Int, _ pixelHeight: Int, _ scale: CGFloat) -> CGContext? {
        guard pixelWidth > 0, pixelHeight > 0, let layer else { return nil }
        surfaceChain.removeAll(keepingCapacity: true)
        surfaceChainIndex = 0
        for _ in 0..<Self.surfaceChainLength {
            guard let (io, ctx) = makeOneSurface(pixelWidth, pixelHeight, scale) else { return nil }
            surfaceChain.append(TerminalSurfaceBuffer(io: io, ctx: ctx))
        }
        let first = surfaceChain[0]
        surfaceIOSurface = first.io
        layerContentsRedrawPolicy = .never
        layer.contentsScale = scale
        layer.contents = first.io
        return first.ctx
    }

    /// Three: the buffer about to be written must not be one the compositor might still be sampling, and
    /// with two the next one to write is the one presented on the previous frame.
    static var surfaceChainLength: Int { 3 }

    func makeOneSurface(_ pixelWidth: Int, _ pixelHeight: Int, _ scale: CGFloat) -> (IOSurface, CGContext)? {
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
        return (io, ctx)
    }

    /// Pick the surface this frame will be painted into and bring it current, BEFORE this frame's own
    /// scroll and repaint are applied to it. Order matters: the operations it missed are older than the
    /// ones about to happen, and replaying them afterwards would move this frame's pixels twice.
    func prepareSurfaceForFrame() {
        guard presentsViaLayerContents, usesOwnSurface, !surfaceChain.isEmpty else { return }
        surfaceChainIndex = (surfaceChainIndex + 1) % surfaceChain.count
        let back = surfaceChain[surfaceChainIndex]
        surface = back.ctx
        surfaceIOSurface = back.io
        // Only the byte moves, and only the ones this buffer missed. **Its rows are deliberately not
        // painted here.** They would be painted with the content this frame already carries but at the
        // coordinates of the frame before it, and the blit that runs next would then displace them —
        // measured as the buffer handed to the compositor being wrong from frame 3 of a scrolling corpus
        // (`theBufferPresentedEachFrameHoldsThatFrame`). The debt is carried through the blit instead and
        // paid in `renderIntoLayerSurface`, together with this frame's own rows and in this frame's
        // coordinates.
        withSurfaceLocked { replayMissedScrolls(back) }
    }

    /// Paint whatever is outstanding into the surface and let the compositor know it changed.
    ///
    /// Called from `updateDisplay` rather than from `draw(_:)`: with `.never` AppKit no longer asks us
    /// to draw, because it is not managing these pixels any more.
    func renderIntoLayerSurface(bufferOffset: Int) {
        guard presentsViaLayerContents, usesOwnSurface else { return }
        guard let (ctx, isFresh) = ensureSurface() else { return }
        let full = isFresh || surfaceNeedsFullRepaint
        var toPaint = full ? [bounds] : pendingSurfacePaint
        if let front = currentSurfaceBuffer {
            if full {
                front.owed.removeAll(keepingCapacity: true)
            } else if !front.owed.isEmpty {
                // The rows this buffer missed while it was idle, now in this frame's coordinates, painted
                // through the same rect as the rows this frame changed.
                toPaint.append(contentsOf: coalescedRowRuns(front.owed).map(rowRunInvalidationRect))
                surfacePaintRows += front.owed.count
                front.owed.removeAll(keepingCapacity: true)
            }
        }
        if full {
            // A full repaint is a frame the other buffers missed too — and at creation they are blank,
            // so without this they stay blank apart from whatever incremental rows land on them later.
            // That is not a subtle drift: it is two out of three frames showing an empty terminal.
            markEveryIdleBufferFullyOwed()
        }
        surfaceNeedsFullRepaint = false
        pendingSurfacePaint.removeAll(keepingCapacity: true)
        let moved = surfaceMovedPixelsThisCycle
        surfaceMovedPixelsThisCycle = false
        // A blit with nothing to repaint still has to be handed over: the pixels moved in THIS buffer,
        // and the one the compositor is still holding did not move — it has the scroll sitting in its
        // pending list. Returning here would leave an unscrolled frame on screen.
        guard !toPaint.isEmpty || moved else { return }
        withSurfaceLocked {
            for r in toPaint {
                paintIntoSurface(r.intersection(bounds), ctx, bufferOffset: bufferOffset)
            }
        }
        // A different object every frame is the only thing Core Animation reads as "a new picture".
        layer?.contents = surfaceIOSurface
    }

    /// Hold the surface's lock across CPU writes.
    ///
    /// Not decoration: `IOSurface` tracks a seed that moves on unlock, and that seed is how anything
    /// else — the compositor included — can tell the memory it is sampling has been rewritten. The first
    /// cut locked only at creation and then wrote every frame outside the lock, so the seed never moved
    /// after the first frame.
    func withSurfaceLocked(_ body: () -> Void) {
        guard let io = surfaceIOSurface else { return body() }
        io.lock(options: [], seed: nil)
        body()
        io.unlock(options: [], seed: nil)
    }

    /// Re-establish the layer's contents if something dropped them.
    ///
    /// It cannot do more than that. There is no public way to say "the object you are holding now
    /// contains a different picture": re-assigning `layer.contents` with the same object carries no
    /// information, and `-[CALayer setContentsChanged]` — which means exactly that — is not in the public
    /// headers, and this fork does not call private API. Handing Core Animation a **different** surface
    /// is the documented way to announce a frame, which is why the chain exists rather than a signal.
    func noteSurfaceContentsChanged() {
        guard let layer, let io = surfaceIOSurface else { return }
        if layer.contents == nil { layer.contents = io }
    }
}

extension TerminalView {
    /// The surface's pixels, for tests that need to compare what was painted rather than what reached
    /// the screen — B2 never goes through `draw(_:)`, so a harness that captures drawing sees nothing.
    /// Repacked to tight rows on the way out: an `IOSurface` and a `CGBitmapContext` pad their rows
    /// differently, so raw buffers of the same image are not the same length and comparing them
    /// reports "different size" instead of "different picture".
    /// Catch every buffer in the chain up, then hand back each one's pixels.
    ///
    /// This is the invariant a swap chain lives or dies on: the compositor is shown a different buffer
    /// every frame, so *all* of them must hold the same picture once current. A test that only reads the
    /// buffer painted last would pass while the other two show something older — which is not a subtle
    /// wrongness, it is the flicker.
    func allSurfacePixelsForTesting(bufferOffset: Int) -> [(bytes: Data, bytesPerRow: Int, height: Int)] {
        // Catching a buffer up paints, and painting writes `rowsOnScreen` — the record of what the SCREEN
        // holds. Two of these three buffers are not the screen, so the record is put back afterwards
        // rather than left describing memory nobody was shown.
        let onScreen = rowsOnScreen
        defer { rowsOnScreen = onScreen }
        var out: [(Data, Int, Int)] = []
        for buffer in surfaceChain {
            withSurfaceLocked { catchUpSurface(buffer, bufferOffset: bufferOffset) }
            guard let data = buffer.ctx.data else { continue }
            let tight = buffer.ctx.width * 4
            var bytes = Data(capacity: tight * buffer.ctx.height)
            for y in 0..<buffer.ctx.height {
                bytes.append(Data(bytes: data.advanced(by: y * buffer.ctx.bytesPerRow), count: tight))
            }
            out.append((bytes, tight, buffer.ctx.height))
        }
        return out
    }

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


/// One surface in the swap chain, plus what it still owes.
///
/// `pending` is the frames this buffer was not the target of. Replaying one is a memmove by that
/// frame's scroll plus a repaint of the rows that frame changed — the rows are stored as SCREEN rows and
/// are shifted along by each later scroll, so they still name the right place when they are finally
/// painted.
final class TerminalSurfaceBuffer {
    let io: IOSurface
    let ctx: CGContext
    /// Screen rows whose pixels in THIS buffer are not current, in its own current coordinates.
    var owed: Set<Int> = []
    /// The frames this buffer missed, oldest first. **A frame is one pair**, not a scroll and a row set
    /// kept apart: the rows are named in the coordinates that exist AFTER that frame's scroll, so
    /// replaying the scroll and the rows out of step moves the rows a second time — measured as chain
    /// buffers disagreeing by tens of thousands of pixels.
    var pending: [(shift: Int, rows: [Int])] = []

    init(io: IOSurface, ctx: CGContext) {
        self.io = io
        self.ctx = ctx
    }
}

extension TerminalView {
    /// Bring `buffer` up to the present: apply the scrolls it missed, then repaint what it owes.
    ///
    /// Returns the rows that had to be painted, so the caller can tell a cheap catch-up from an
    /// expensive one without a second measurement.
    /// Only the test seam calls this. The frame path splits the two halves apart on purpose — see
    /// `prepareSurfaceForFrame` for why doing them together is the bug this chain had.
    @discardableResult
    func catchUpSurface(_ buffer: TerminalSurfaceBuffer, bufferOffset: Int) -> Int {
        replayMissedScrolls(buffer)
        return payOwedRows(buffer, bufferOffset: bufferOffset)
    }

    /// Apply the byte moves `buffer` missed, carrying its outstanding rows along with them.
    ///
    /// Split out from the painting because the two happen at different moments for the buffer this frame
    /// is painting into: its scrolls are older than this frame and must be applied before this frame's
    /// own, while its rows must be painted after, in this frame's coordinates. See `prepareSurfaceForFrame`.
    func replayMissedScrolls(_ buffer: TerminalSurfaceBuffer) {
        for frame in buffer.pending {
            if frame.shift != 0 {
                shiftSurfaceBytes(buffer.ctx, by: frame.shift)
                buffer.owed = shiftedRows(buffer.owed, by: frame.shift)
            }
            // Added AFTER the shift, because that is the coordinate system they were recorded in.
            buffer.owed.formUnion(frame.rows)
        }
        buffer.pending.removeAll(keepingCapacity: true)
    }

    /// Paint what `buffer` owes, through the same rect the front path paints a run through.
    ///
    /// Painting also writes `rowsOnScreen`, which records what THE SCREEN holds. That is correct for the
    /// buffer about to be handed over and wrong for any other, which is why the frame path pays this debt
    /// from `renderIntoLayerSurface` — after the narrowing has read that record, and only for the buffer
    /// being presented. See `catchUpSurface` for the one caller that is not that.
    @discardableResult
    func payOwedRows(_ buffer: TerminalSurfaceBuffer, bufferOffset: Int) -> Int {
        guard !buffer.owed.isEmpty else { return 0 }
        let painted = buffer.owed.count
        for run in coalescedRowRuns(buffer.owed) {
            paintIntoSurface(rowRunInvalidationRect(run).intersection(bounds), buffer.ctx,
                             bufferOffset: bufferOffset)
        }
        buffer.owed.removeAll(keepingCapacity: true)
        return painted
    }

    /// Screen rows moved by a scroll of `shift`, dropping the ones that fell off the screen.
    func shiftedRows(_ rows: Set<Int>, by shift: Int) -> Set<Int> {
        guard shift != 0, !rows.isEmpty else { return rows }
        return Set(rows.compactMap { row -> Int? in
            let moved = row - shift
            return (moved >= 0 && moved < terminal.rows) ? moved : nil
        })
    }

    /// Move a surface's pixels by `shift` screen rows. Screen row 0 is the first row in memory, so
    /// content moving up the screen moves toward lower addresses.
    func shiftSurfaceBytes(_ ctx: CGContext, by shift: Int) {
        guard shift != 0, let data = ctx.data else { return }
        let rowPixels = cellDimension.height * surfaceScale
        guard rowPixels >= 1, abs(rowPixels - rowPixels.rounded()) < 0.001 else { return }
        let rowPx = Int(rowPixels.rounded())
        let moveRows = terminal.rows - abs(shift)
        guard moveRows > 0 else { return }
        let bytesPerRow = ctx.bytesPerRow
        let moveBytes = moveRows * rowPx * bytesPerRow
        let offsetBytes = abs(shift) * rowPx * bytesPerRow
        guard moveBytes > 0, offsetBytes + moveBytes <= ctx.height * bytesPerRow else { return }
        if shift > 0 {
            memmove(data, data.advanced(by: offsetBytes), moveBytes)
        } else {
            memmove(data.advanced(by: offsetBytes), data, moveBytes)
        }
    }

    /// Record on every OTHER buffer what this frame did, so they can catch up when their turn comes.
    /// Every other buffer owes the whole screen — used when this frame repaints everything.
    func markEveryIdleBufferFullyOwed() {
        guard !surfaceChain.isEmpty else { return }
        let everything = Array(0..<terminal.rows)
        for (i, buffer) in surfaceChain.enumerated() where i != surfaceChainIndex {
            buffer.pending.append((shift: 0, rows: everything))
        }
    }

    /// Called **once per frame**, with that frame's scroll and its changed rows together.
    func recordFrameOnIdleBuffers(shift: Int, rows: [ClosedRange<Int>]) {
        guard !surfaceChain.isEmpty, shift != 0 || !rows.isEmpty else { return }
        let flat = rows.flatMap { Array($0) }
        for (i, buffer) in surfaceChain.enumerated() where i != surfaceChainIndex {
            buffer.pending.append((shift: shift, rows: flat))
        }
    }
}

#endif
