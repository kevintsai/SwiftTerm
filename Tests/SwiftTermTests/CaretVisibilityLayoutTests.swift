//
//  CaretVisibilityLayoutTests.swift
//
//  Hiding and showing the cursor (`CSI ?25l` / `CSI ?25h`) must not make the window lay out again.
//
//  Programs that redraw in place hide the cursor at the start of every frame and show it at the end —
//  Claude Code does it on every spinner frame, ~10 times a second. When that meant removing the caret
//  subview and adding it back, each frame changed the view hierarchy, AppKit asked the window for a layout
//  pass, and an embedder hosting the terminal in SwiftUI re-ran layout for its whole window: measured in
//  fleetmux, a third of the main thread's busy time with nothing but a spinner on screen. Visibility is a
//  property of the caret, not of the hierarchy.
//
//  The harness hosts the terminal the way an embedder does — `NSHostingView` around an
//  `NSViewRepresentable` — because that host is what turns a subview change into a whole-window layout.
//  A plain container (autoresizing or constraint-based) never relays it, and a test built on one passes
//  for the wrong reason; the control test below is there to catch exactly that.
//
#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SwiftTerm

@MainActor
struct CaretVisibilityLayoutTests {
    final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() {
            super.layout()
            layouts += 1
        }
    }

    struct Hosted: NSViewRepresentable {
        let view: TerminalView
        func makeNSView(context: Context) -> TerminalView { view }
        func updateNSView(_ nsView: TerminalView, context: Context) {}
    }

    private func makeHierarchy() -> (NSWindow, CountingHost<Hosted>, TerminalView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let host = CountingHost(rootView: Hosted(view: view))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = host
        window.layoutIfNeeded()
        view.terminal.feed(text: "hello\r\n")
        view.updateDisplay(notifyAccessibility: false)
        window.layoutIfNeeded()
        host.layouts = 0
        return (window, host, view)
    }

    @Test func hidingAndShowingTheCursorDoesNotLayOutTheWindow() {
        let (window, host, view) = makeHierarchy()
        defer { window.close() }

        // Both paths that decide visibility: the delegate calls during the feed, and `updateCursorPosition`
        // in the frame's `updateDisplay` — which also runs while the cursor is hidden.
        for _ in 0..<5 {
            view.terminal.feed(text: "\u{1b}[?25l")
            view.updateDisplay(notifyAccessibility: false)
            window.layoutIfNeeded()
            view.terminal.feed(text: "\u{1b}[?25h")
            view.updateDisplay(notifyAccessibility: false)
            window.layoutIfNeeded()
        }

        #expect(host.layouts == 0)
    }

    @Test func theCaretFollowsTheCursorVisibility() {
        let (window, _, view) = makeHierarchy()
        defer { window.close() }
        guard let caret = view.caretView else { Issue.record("no caret view"); return }

        view.terminal.feed(text: "\u{1b}[?25l")
        view.updateDisplay(notifyAccessibility: false)  // `updateCursorPosition` runs here too, every frame
        #expect(caret.superview === view)
        #expect(caret.isHidden)

        view.terminal.feed(text: "\u{1b}[?25h")
        #expect(caret.superview === view)
        #expect(!caret.isHidden)
    }

    /// The control: a hierarchy change under the hosted terminal does lay the window out in this harness.
    /// Without it, a harness that never relays layout would pass the first test for the wrong reason.
    @Test func aHierarchyChangeDoesLayOutTheWindow() {
        let (window, host, view) = makeHierarchy()
        defer { window.close() }

        let extra = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        for _ in 0..<5 {
            view.addSubview(extra)
            window.layoutIfNeeded()
            extra.removeFromSuperview()
            window.layoutIfNeeded()
        }

        #expect(host.layouts > 0)
    }
}
#endif
