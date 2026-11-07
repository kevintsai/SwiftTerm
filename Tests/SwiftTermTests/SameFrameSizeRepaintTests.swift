//
//  SameFrameSizeRepaintTests.swift
//
//  `setFrameSize` with the size the view already has must not repaint the whole view.
//
//  An embedder hosts the terminal in a SwiftUI/AppKit layout, and every layout pass re-applies the view's
//  frame — usually unchanged. A layout pass is cheap to trigger: removing and re-adding the caret subview,
//  which a program does on every `CSI ?25l … CSI ?25h` (Claude Code does it on every spinner frame), asks
//  the window for one. When a same-size `setFrameSize` meant `needsDisplay = true`, each of those frames
//  repainted every row, and the narrowed invalidation (`visuallyChangedRowRuns`) never got to matter:
//  measured in fleetmux, 10 frames a second at 32 of 32 rows for a frame that changed one row.
//
#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
struct SameFrameSizeRepaintTests {
    final class RecordingView: TerminalView {
        var invalidations = 0
        override func setNeedsDisplay(_ invalidRect: NSRect) {
            super.setNeedsDisplay(invalidRect)
            invalidations += 1
        }
        override var needsDisplay: Bool {
            didSet { if needsDisplay { invalidations += 1 } }
        }
    }

    private func makeView() -> (NSWindow, RecordingView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = view
        view.terminal.feed(text: "hello\r\nworld\r\n")
        view.updateDisplay(notifyAccessibility: false)
        view.displayIfNeeded()
        view.invalidations = 0
        return (window, view)
    }

    @Test func reapplyingTheSameSizeDoesNotInvalidate() {
        let (window, view) = makeView()
        defer { window.close() }
        let before = (view.terminal.cols, view.terminal.rows)

        view.setFrameSize(view.frame.size)

        #expect(view.invalidations == 0)
        #expect((view.terminal.cols, view.terminal.rows) == before)
    }

    /// The control: a real size change still repaints. Without this, a harness that cannot see the
    /// `needsDisplay = true` path would pass the test above for the wrong reason.
    @Test func aRealSizeChangeStillInvalidates() {
        let (window, view) = makeView()
        defer { window.close() }

        view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height - 40))

        #expect(view.invalidations > 0)
    }
}
#endif
