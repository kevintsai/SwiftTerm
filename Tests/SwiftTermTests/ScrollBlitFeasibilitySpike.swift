//
//  ScrollBlitFeasibilitySpike.swift
//
//  Decides which scroll-blitting implementation is even possible before any of it is written.
//
//  fleetmux spec 27 §5 wants the pane to stop repainting all N rows when a scroll only moved them —
//  measured on a real capture, every draw repaints 24 of 24 rows while 1–2 carry new content. §5.5
//  lists the open risks and says AppKit's guarantee for `scrollRect(_:by:)` on a LAYER-BACKED view
//  must be measured, not inferred from the documentation. `TerminalView` sets `wantsLayer = true`,
//  so that one question forks the whole design:
//
//    A. `scrollRect(_:by:)` really moves the backing store → let AppKit do it, repaint the exposed strip.
//    B. it does not → the view has to own its own bitmap, blit inside it, and hand that to `draw`.
//
//  What this measures: which rects AppKit asks `draw(_:)` for after a scroll, and whether the pixels
//  that were NOT redrawn survived. A view that gets asked for the whole bounds again has gained
//  nothing; a view whose untouched pixels come back wrong has gained a ghosting bug.
//

#if os(macOS)
import AppKit
import XCTest

/// Draws each row in a colour derived from the content index currently at that row, so "did the
/// pixels move" is answerable by reading one pixel per row.
final class BlitProbeView: NSView {
    static let rowHeight: CGFloat = 10
    static let rows = 12

    /// Content index shown at screen row 0. Bumping it by one models one line of scroll.
    var offset = 0
    /// Every rect `draw(_:)` was asked for, in order, cleared by the test between phases.
    var askedFor: [NSRect] = []

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        askedFor.append(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for row in 0..<Self.rows {
            let rect = NSRect(x: 0,
                              y: CGFloat(row) * Self.rowHeight,
                              width: bounds.width,
                              height: Self.rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            let value = CGFloat((offset + row) % 255) / 255.0
            ctx.setFillColor(CGColor(red: value, green: 0, blue: 0, alpha: 1))
            ctx.fill(rect)
        }
    }

    /// The red channel at the vertical middle of one screen row.
    func redAt(row: Int) -> Int? {
        let rect = NSRect(x: 0,
                          y: CGFloat(row) * Self.rowHeight,
                          width: bounds.width,
                          height: Self.rowHeight)
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        guard let colour = rep.colorAt(x: 1, y: rep.pixelsHigh / 2) else { return nil }
        return Int((colour.redComponent * 255).rounded())
    }
}

final class ScrollBlitFeasibilitySpike: XCTestCase {
    func testWhatScrollRectDoesToALayerBackedView() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_BLIT_SPIKE"] == "1",
                          "spike; set SWIFTTERM_BLIT_SPIKE=1 to run")

        let size = NSSize(width: 40, height: BlitProbeView.rowHeight * CGFloat(BlitProbeView.rows))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        let view = BlitProbeView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        window.contentView = view
        window.orderBack(nil)

        // Phase 1 — cold: everything is painted, and we record what row 0 and row 1 hold.
        view.needsDisplay = true
        view.displayIfNeeded()
        let coldAsks = view.askedFor
        let beforeRow1 = view.redAt(row: 1)
        view.askedFor = []

        // Control — can this harness even observe a partial ask? Invalidate one strip and nothing else.
        // Without this arm, "AppKit asked for the whole view" could just be the probe being blind.
        view.setNeedsDisplay(NSRect(x: 0, y: 0, width: size.width, height: BlitProbeView.rowHeight))
        view.displayIfNeeded()
        let controlAsks = view.askedFor
        let controlArea = controlAsks.reduce(0.0) { $0 + $1.height }
        view.askedFor = []

        // Phase 2 — the scroll a streaming pane performs: content moves down one row on screen, and
        // only the newly exposed row carries anything new.
        view.offset += 1
        let rowHeight = BlitProbeView.rowHeight
        view.scroll(view.bounds, by: NSSize(width: 0, height: rowHeight))
        view.setNeedsDisplay(NSRect(x: 0, y: 0, width: size.width, height: rowHeight))
        view.displayIfNeeded()
        let scrollAsks = view.askedFor
        let askedArea = scrollAsks.reduce(0.0) { $0 + $1.height }
        let fullArea = size.height

        // What did row 1 end up holding? If AppKit moved the backing store, it holds what row 0 held
        // before the scroll. If it did not, it holds whatever a repaint produced — or nothing.
        let afterRow1 = view.redAt(row: 1)

        print("""

        ── scrollRect(_:by:) on a layer-backed NSView ──────────────────────────────
          cold draw asked for      : \(coldAsks.count) rect(s), \(Int(coldAsks.reduce(0.0) { $0 + $1.height })) px tall
          CONTROL, strip only      : \(controlAsks.count) rect(s), \(Int(controlArea)) px tall  → probe \(controlArea < fullArea ? "CAN see a partial ask" : "is blind, ignore everything below")
          after scroll asked for   : \(scrollAsks.count) rect(s), \(Int(askedArea)) px tall  (full view = \(Int(fullArea)) px)
          rects                    : \(scrollAsks.map { "\(Int($0.minY))..<\(Int($0.maxY))" }.joined(separator: ", "))
          row 1 red before / after : \(beforeRow1.map(String.init) ?? "nil") / \(afterRow1.map(String.init) ?? "nil")
          verdict                  : \(askedArea < fullArea ? "AppKit asked for LESS than the whole view" : "AppKit asked for the WHOLE view — scrollRect bought nothing")
        ────────────────────────────────────────────────────────────────────────────

        """)
    }
}
#endif
