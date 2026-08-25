//
//  MacCursorTrailView.swift
//
//  A "cursor trail" / motion-trail overlay for the macOS CoreGraphics terminal view — a faithful
//  port of kitty's implementation (kitty/cursor_trail.c + trail_{vertex,fragment}.glsl), adapted
//  from GPU/NDC space to an AppKit CoreGraphics sibling view drawn in the terminal's point space.
//
//  How it maps to kitty:
//   * kitty tracks the four corners of the cursor rectangle (TR, BR, BL, TL) and eases each toward
//     its target every frame with an exponential ease-out. Leading corners (moving away from the
//     cursor centre) decay fast, trailing corners decay slow — that spread is what stretches the
//     block into the elongated "comet" trapezoid you see on a big jump.
//   * `cursor_trail_decay <fast> <slow>` → `decayFast` / `decaySlow` (seconds to reach 1/1024 of the
//     remaining distance).
//   * `cursor_trail_start_threshold <cells>` → `startThreshold`: while the trail is settled, a move
//     smaller than this many cells snaps (no trail). A bigger jump starts a trail.
//   * `cursor_trail <ms>` → `stillness`: the target only follows the cursor once it has stayed put
//     for this long, so a rapidly-bouncing cursor (progress spinner) doesn't smear.
//
//  Rendering is a solid-colour quad through the four eased corners (kitty's fragment shader is a flat
//  colour × opacity; the taper is purely geometric, not a length gradient). The current cursor cell
//  is covered by the opaque `CaretView` drawn above this view, so kitty's "cut out the cursor area"
//  step is unnecessary here. CoreGraphics only — the Metal renderer path is not covered (fleetmux
//  uses the CoreGraphics path).
//

#if os(macOS)
import AppKit
import QuartzCore

/// Overlay that draws the animated cursor trail. Owned by `TerminalView`, inserted just below the
/// `CaretView`. Non-interactive (never steals mouse hits). Animation is driven by a `CADisplayLink`
/// that pauses itself the moment the trail has settled, so idle terminals cost nothing.
final class CursorTrailView: NSView {
    weak var terminalView: TerminalView?

    // Config (mapped from kitty options; see file header).
    var decayFast: CGFloat = 0.1
    var decaySlow: CGFloat = 0.4
    var startThreshold: Int = 2
    /// kitty `cursor_trail` stillness gate, in seconds (its option is milliseconds): the target only follows
    /// a cursor the CLIENT has left alone for this long.
    ///
    /// kitty ships 1–3ms because it parses everything pending and draws the result in one lockstep frame, so a
    /// position the program is only passing through is never a position it renders. A view that samples the
    /// terminal on its own timer has no such guarantee: it reads whatever the last completed feed left behind,
    /// up to a frame later. The gate therefore has to outlast one sampling interval (16.7ms) to mean anything
    /// here — under it, "the program moved the cursor 5ms ago" still reads as "settled".
    var stillness: CFTimeInterval = 0.030

    /// How long the stillness gate may hold the target back before it yields, in seconds.
    ///
    /// The gate exists to ignore positions an app is only *passing through* while it paints — and painting a
    /// frame is bounded in time. Sustained cursor movement is not: hold `j` in nvim and the key repeat
    /// (~30 ms on macOS) outpaces a 30 ms gate forever, so the target never commits, and the trail is drawn
    /// from wherever the cursor started all the way to wherever it is now — for as long as the key is held.
    /// Kevin reported exactly that on 2026-08-25: "按住時原本位置持續反白，放開才收".
    ///
    /// So the gate yields once it has been holding longer than any plausible frame. Deliberately expressed
    /// as TIME rather than distance: a repaint sweep moves the cursor a long way with the cursor *visible*
    /// (`testTargetIsFrozenWhileTheProgramKeepsMovingTheCursor` is that case), so a distance cap would
    /// reopen the very bug that test pins, while a sweep is over in a few milliseconds.
    var maxFreezeSeconds: CFTimeInterval = 0.20

    // Cell size in points (from the terminal's `cellDimension`), for the cell-based thresholds.
    private var cellW: CGFloat = 8
    private var cellH: CGFloat = 16

    // kitty CursorTrail state, in the terminal view's point space (y-up: `top` > `bottom`).
    private var cornerX = [CGFloat](repeating: 0, count: 4)
    private var cornerY = [CGFloat](repeating: 0, count: 4)
    private var edgeX: [CGFloat] = [0, 0]     // committed target: [left, right]
    private var edgeY: [CGFloat] = [0, 0]     // committed target: [top, bottom]
    private var rawEdgeX: [CGFloat] = [0, 0]  // latest cursor rect, awaiting the stillness gate
    private var rawEdgeY: [CGFloat] = [0, 0]
    private var opacity: CGFloat = 0
    private var needsRender = false
    private var cursorVisible = true
    private var updatedAt: CFTimeInterval = 0
    /// When the CLIENT PROGRAM last moved the cursor (`Terminal.cursorPositionChangedAt`, a parse-time stamp on
    /// `ProcessInfo.systemUptime`) — kitty's `cursor->position_changed_by_client_at`. **Not** "when this view
    /// last noticed a different position": a renderer samples at most a few dozen times a second, so a
    /// render-time stamp always looks "still" one frame later and the stillness gate degenerates into "follow
    /// whatever I happened to sample". That is what made the trail chase the transient positions an app sweeps
    /// through mid-redraw (cursor parked at the top of the pane, then back to the prompt) instead of ignoring
    /// them the way kitty does.
    private var clientMovedAt: CFTimeInterval = 0
    /// When the gate first started holding a pending position back, on `clientClock`. 0 = not holding.
    private var frozenSince: CFTimeInterval = 0
    /// Latched once the gate has yielded (see `maxFreezeSeconds`), so the target keeps following instead of
    /// committing once every `maxFreezeSeconds` and jumping. Cleared the moment the cursor actually settles.
    private var chasing = false
    /// True while the display link is running and the quad should be drawn.
    private var active = false
    private var everPositioned = false

    // corner i → which x/y edge it tracks (kitty `corner_index[2][4]`).
    // corner 0 = (right, top)=TR, 1 = (right, bottom)=BR, 2 = (left, bottom)=BL, 3 = (left, top)=TL.
    private static let cornerIndexX = [1, 1, 0, 0]
    private static let cornerIndexY = [0, 1, 1, 0]

    // A main-runloop timer drives the animation (CADisplayLink is macOS 14+ only, and SwiftTerm
    // supports older). It runs only while a trail is settling, then invalidates itself.
    private var timer: Timer?
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Non-interactive overlay — let the terminal take every hit.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func makeBackingLayer() -> CALayer {
        let l = super.makeBackingLayer()
        l.isOpaque = false
        l.backgroundColor = NSColor.clear.cgColor
        return l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTimer() }
    }

    /// Tear down before the view is dropped (called when the trail is disabled).
    func stopAndRemove() {
        stopTimer()
        removeFromSuperview()
    }

    // MARK: - Input from updateCursorPosition

    /// Called from `updateCursorPosition()` on every cursor move / redraw. `rect` is the caret frame
    /// in this view's coordinate space; `visible` is whether the caret is currently shown.
    /// `clientMovedAt` is `Terminal.cursorPositionChangedAt` (the parse-time stamp); pass 0 when unknown, which
    /// makes the stillness gate open immediately (previous behaviour).
    func cursorMoved(rect: CGRect, cellWidth: CGFloat, cellHeight: CGFloat, visible: Bool,
                     clientMovedAt: CFTimeInterval) {
        cellW = max(1, cellWidth)
        cellH = max(1, cellHeight)
        cursorVisible = visible
        self.clientMovedAt = clientMovedAt

        // A HIDDEN cursor has no position worth trailing. Programs and tmux both park the cursor wherever it
        // is cheapest while `DECTCEM` is off — tmux sweeps it clear across the pane between frames — and none
        // of those cells were ever on screen. Sampling them is how a trail ends up flying to a corner nobody's
        // cursor visited. Keep the last position the user could actually see; the opacity ramp below still
        // fades the quad out for as long as the cursor stays hidden.
        if visible {
            rawEdgeX = [rect.minX, rect.maxX]
            rawEdgeY = [rect.maxY, rect.minY]
        } else if !everPositioned {
            // Nothing to anchor to yet — wait for a visible cursor rather than snapping to a hidden one.
            return
        }

        let now = CACurrentMediaTime()

        // First placement: snap everything to the cursor so the trail never animates in from (0,0).
        if !everPositioned {
            everPositioned = true
            edgeX = rawEdgeX
            edgeY = rawEdgeY
            snapCornersToTarget()
            opacity = visible ? 1 : 0
            updatedAt = now
            return
        }
        kick()
    }

    // MARK: - Animation loop

    private func kick() {
        guard window != nil else { return }
        if !active {
            active = true
            updatedAt = CACurrentMediaTime()
        }
        if timer == nil {
            // .common mode so the trail keeps animating during scroll / event tracking.
            let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
                self?.step()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        active = false
    }

    private func step() {
        let now = CACurrentMediaTime()
        if updatedAt == 0 { updatedAt = now }

        // 1. Commit the target once the cursor has been still long enough (kitty stillness gate). The clock is
        //    the PROGRAM's last cursor move — while it is still painting a frame the target stays frozen, so the
        //    trail never chases a position the app is only passing through. A hidden cursor never commits at
        //    all: `cursorMoved` stops refreshing the position while it is hidden, so the pending one is stale
        //    by definition, and letting the gate expire over it would drag the trail to wherever the cursor
        //    happened to be when it vanished.
        if cursorVisible {
            let now = clientNow()
            if now - clientMovedAt >= stillness {
                // Settled: commit, and forget that we were ever holding anything back.
                frozenSince = 0
                chasing = false
                edgeX = rawEdgeX
                edgeY = rawEdgeY
            } else if rawEdgeX != edgeX || rawEdgeY != edgeY {
                // The gate is holding a pending position back. Time it: a frame ends, a held key does not.
                if frozenSince == 0 { frozenSince = now }
                if chasing || now - frozenSince >= maxFreezeSeconds {
                    chasing = true
                    edgeX = rawEdgeX
                    edgeY = rawEdgeY
                }
            } else {
                frozenSince = 0
            }
        }

        // 2. Ease the corners toward the target.
        updateCorners(now: now)

        // 3. Opacity ramps toward 1 while the cursor is visible, fades to 0 while hidden.
        let dt = CGFloat(now - updatedAt)
        if cursorVisible {
            opacity = min(1, opacity + dt / max(0.0001, decaySlow))
        } else {
            opacity = max(0, opacity - dt / max(0.0001, decaySlow))
        }

        // 4. Decide whether more frames are needed.
        updateNeedsRender()
        updatedAt = now
        setNeedsDisplay(bounds)

        // Keep going while corners are still converging, or while a hidden cursor is still fading out.
        let keepGoing = needsRender || (!cursorVisible && opacity > 0.001)
        if !keepGoing {
            stopTimer()
            setNeedsDisplay(bounds) // clear the settled quad (it now exactly overlaps the caret)
        }
    }

    /// "Now" on the same monotonic clock as `clientMovedAt` (`Terminal.cursorPositionChangedAt`).
    /// Injectable so the stillness gate can be tested deterministically.
    var clientClock: () -> CFTimeInterval = { ProcessInfo.processInfo.systemUptime }
    private func clientNow() -> CFTimeInterval { clientClock() }

    /// Test seam: the committed target the corners are easing toward, as `[top, bottom]` in point space.
    /// The gate's whole job is deciding *when* this is allowed to follow the cursor.
    var committedTargetYForTesting: [CGFloat] { edgeY }
    /// Test seam: run one animation frame without waiting for the timer.
    func stepForTesting() { step() }

    private func targetX(_ i: Int) -> CGFloat { edgeX[Self.cornerIndexX[i]] }
    private func targetY(_ i: Int) -> CGFloat { edgeY[Self.cornerIndexY[i]] }

    private func snapCornersToTarget() {
        for i in 0..<4 {
            cornerX[i] = targetX(i)
            cornerY[i] = targetY(i)
        }
    }

    private func shouldSkip() -> Bool {
        // Cursor hidden and fully faded → nothing to animate.
        if !cursorVisible && opacity <= 0 { return true }
        // While settled, ignore small moves (start threshold, in cells, both axes).
        if startThreshold > 0 && !needsRender {
            let dx = (cornerX[0] - edgeX[1]) / cellW    // corner0.x vs right edge
            let dy = (cornerY[0] - edgeY[0]) / cellH    // corner0.y vs top edge
            if abs(dx.rounded()) <= CGFloat(startThreshold) && abs(dy.rounded()) <= CGFloat(startThreshold) {
                return true
            }
        }
        return false
    }

    private func updateCorners(now: CFTimeInterval) {
        if shouldSkip() {
            snapCornersToTarget()
            return
        }
        guard updatedAt < now else { return }

        let centerX = (edgeX[0] + edgeX[1]) * 0.5
        let centerY = (edgeY[0] + edgeY[1]) * 0.5
        let diag2 = norm(edgeX[1] - edgeX[0], edgeY[1] - edgeY[0]) * 0.5
        let dt = CGFloat(now - updatedAt)

        var dx = [CGFloat](repeating: 0, count: 4)
        var dy = [CGFloat](repeating: 0, count: 4)
        var dot = [CGFloat](repeating: 0, count: 4)
        var anyMoved = false
        for i in 0..<4 {
            let ddx = targetX(i) - cornerX[i]
            let ddy = targetY(i) - cornerY[i]
            if abs(ddx) < 1e-6 && abs(ddy) < 1e-6 {
                dx[i] = 0; dy[i] = 0; dot[i] = 0
                continue
            }
            dx[i] = ddx
            dy[i] = ddy
            anyMoved = true
            // Alignment of the corner's motion with its outward (centre→corner) direction: a corner
            // moving outward (the leading edge of the jump) scores high → decays fast.
            let denom = (diag2 * norm(ddx, ddy))
            dot[i] = denom == 0 ? 0
                : (ddx * (targetX(i) - centerX) + ddy * (targetY(i) - centerY)) / denom
        }
        guard anyMoved else { return }

        var minDot = CGFloat.greatestFiniteMagnitude
        var maxDot = -CGFloat.greatestFiniteMagnitude
        for i in 0..<4 {
            minDot = min(minDot, dot[i])
            maxDot = max(maxDot, dot[i])
        }

        for i in 0..<4 {
            if dx[i] == 0 && dy[i] == 0 { continue }
            let decay: CGFloat = (minDot == maxDot)
                ? decaySlow
                : decaySlow + (decayFast - decaySlow) * (dot[i] - minDot) / (maxDot - minDot)
            let step = 1 - exp2(-10 * dt / max(0.0001, decay))
            cornerX[i] += dx[i] * step
            cornerY[i] += dy[i] * step
        }
    }

    private func updateNeedsRender() {
        needsRender = false
        // Half a point of slack — corners this close read as fully converged.
        let threshold: CGFloat = 0.5
        for i in 0..<4 {
            if abs(targetX(i) - cornerX[i]) >= threshold || abs(targetY(i) - cornerY[i]) >= threshold {
                needsRender = true
                return
            }
        }
    }

    private func norm(_ x: CGFloat, _ y: CGFloat) -> CGFloat { (x * x + y * y).squareRoot() }

    // MARK: - Drawing

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard active, opacity > 0.001, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let base = terminalView?.caretColor ?? NSColor.white
        ctx.setFillColor(base.withAlphaComponent(opacity).cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cornerX[0], y: cornerY[0]))
        for i in 1..<4 { ctx.addLine(to: CGPoint(x: cornerX[i], y: cornerY[i])) }
        ctx.closePath()
        ctx.fillPath()
    }
}
#endif
