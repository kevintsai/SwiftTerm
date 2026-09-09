//
//  AppleRowDrawCache.swift
//
//  A per-row cache for the CoreText draw path, so a row that did not change between two frames is
//  not shaped again.
//
//  Why this exists. `drawTerminalContents` repaints a dirty *range* — one contiguous band of rows —
//  and a streaming TUI dirties a band that spans almost the whole screen, so nearly every frame is a
//  full-screen repaint. Inside that band every row was re-run through `buildAttributedString` (build
//  the `NSAttributedString` segments) and `CTLineCreateWithAttributedString` (shape them), whether or
//  not that row's bytes had changed since the previous frame. Measured on a live fleetmux window
//  (2026-08-27): `TerminalView.draw` was ~50% of the app's busy CPU while a single visible pane
//  streamed, and `buildAttributedString` was the hottest line inside it.
//
//  `BufferLine.generation` already exists for exactly this — the Metal renderer has used it to cache
//  per-row draw data since it landed. This file gives the CoreText path the same treatment.
//
//  The table is keyed by the LINE, not by the row number it is sitting at. That distinction is the
//  whole value of the cache on a streaming pane: a terminal that scrolls moves content *between* row
//  numbers, so a position-keyed table misses every row of every scrolled frame while the text on
//  screen is largely identical. Measured in fleetmux (2026-09-09) with four panes streaming: shaping
//  was 10.2% of one core out of ~33% total, and `RowDrawCacheScrollTests` shows why — 0 of 10
//  unchanged rows survived one scroll. The position-keyed version looked fine in every benchmark:
//  `lines.push` keeps absolute indices stable, so the miss only appears once the line list is full and
//  `Terminal.scroll` switches to `lines.recycle()` — which for an alt-screen buffer (what `tmux
//  attach` puts us in) is from the very first scroll.
//
//  The whole correctness question is the cache KEY: `buildAttributedString` reads more than the
//  line's bytes, and anything it reads that is not in the key becomes a stale-glyph bug. See
//  ``RowDrawKey`` for the inventory.
//

import Foundation
import CoreText

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Whether this row's link underlining can differ from what the cached copy assumed.
///
/// `shouldUnderlineLink` answers per cell, but its *inputs* are per row: the highlight mode, the
/// modifier key, and at most one `RowRange` for this row. Reducing them to this value lets the key
/// compare them without re-running the per-cell predicate.
enum RowLinkSignature: Equatable {
    /// No cell in this row can be underlined right now (hover mode with nothing hovering, or a
    /// `*WithModifier` mode with the modifier up).
    case off
    /// `.always` (or `.alwaysWithModifier` while the modifier is down): whether a cell is underlined
    /// depends only on whether it carries a payload — which is line content, already covered by
    /// `generation`.
    case payloadDriven
    /// A hover mode with a live highlight on this row: these columns are underlined.
    case hovered(Range<Int>)
}

/// Everything ``TerminalView/buildAttributedString(row:line:cols:)`` reads, reduced to something
/// comparable.
///
/// **This inventory is the contract.** It was taken by reading that function line by line rather than
/// from memory, because an input left out of here does not fail loudly — it renders last frame's
/// glyphs and nothing says so.
///
/// | input in `buildAttributedString` | represented here by |
/// |---|---|
/// | `line[col]`, `line.images` | `generation` (plus the `===` identity check in ``RowDrawCacheEntry``) |
/// | `cols` | `cols` |
/// | `selectedColumnsRange(row:cols:)` | `selection` |
/// | `shouldUnderlineLink(...)` | `link` |
/// | `customBlockGlyphs` | `customBlockGlyphs` |
/// | `getAttributes(...)`, `nativeForegroundColor`, `selectedTextBackgroundColor` — i.e. the colour and font caches | `styleEpoch` |
///
/// The last row is why `styleEpoch` exists: those live in dictionaries that are rebuilt wholesale,
/// so there is nothing cheap to compare. It is bumped from the two functions that already mean
/// "the colour/font caches are now wrong" — `resetCaches()` and `colorsChanged()` — instead of from a
/// hand-kept list of appearance properties. A new colour knob that forgets to route through one of
/// those is already broken today (it would not repaint either), so the cache adds no new obligation.
struct RowDrawKey: Equatable {
    let generation: UInt64
    let cols: Int
    let selection: Range<Int>?
    let link: RowLinkSignature
    let customBlockGlyphs: Bool
    let styleEpoch: UInt64
}

/// One shaped segment: the `CTLine` and its runs, which the background pass and the glyph pass both
/// walk. The runs are owned by the `CTLine`, so holding both together keeps them alive.
struct PreparedRowSegment {
    let segment: ViewLineSegment
    let ctLine: CTLine
    let runs: [CTRun]
}

/// What is currently painted at one screen row. See ``TerminalView/noteRowsOnScreen(rows:bufferOffset:)``.
struct RowOnScreen {
    let lineRef: BufferLine
    let key: RowDrawKey
}

/// What one row costs to produce, kept so the next frame does not produce it again.
struct RowDrawCacheEntry {
    /// The `BufferLine` this was built from — also what the table is keyed by.
    ///
    /// Kept as a strong reference for two reasons. It is the identity the key is derived from, and an
    /// `ObjectIdentifier` is only unique among *live* objects: without a reference here a freed line's
    /// address could be reused by a new one and hand back its glyphs. It is also re-checked with `===`
    /// on every lookup, which costs nothing and makes that argument local.
    let lineRef: BufferLine
    let key: RowDrawKey
    /// The absolute row this was shaped at, and whether reusing it anywhere else would be wrong.
    ///
    /// `buildAttributedString` takes `row` and almost never uses it: the one path that does is the
    /// kitty unicode placeholder decoder, which encodes the row into the placement. So the row is not
    /// part of the key — it is a *veto* recorded per entry, and only rows carrying placeholders pay it.
    let builtAtRow: Int
    let positionDependent: Bool
    let info: ViewLineInfo
    let prepared: [PreparedRowSegment]
}

extension TerminalView {
    /// Invalidate every cached row. Called from the two places that invalidate the colour/font caches.
    ///
    /// Bumping the epoch is the *whole* mechanism — deliberately not "bump and also empty the table".
    /// One rule decides whether an entry may be used (its key still matches), instead of that rule plus
    /// a second one that sometimes wipes the table; a second mechanism is one more thing that can be
    /// half-applied. Nothing is leaked by leaving the stale entries in place: the table is pruned to
    /// the lines on screen every frame, so a stale entry is overwritten the next time its line is
    /// drawn, and dropped once that line scrolls away.
    func invalidateRowDrawCache() {
        rowDrawStyleEpoch &+= 1
    }

    /// The link-underline inputs for one row, reduced to a comparable value. Cheap: at most one
    /// linear scan of `linkHighlightRange`, which holds the matches for the hovered link only.
    func rowLinkSignature(row: Int) -> RowLinkSignature {
        switch linkHighlightMode {
        case .always:
            return .payloadDriven
        case .alwaysWithModifier:
            return commandActive ? .payloadDriven : .off
        case .hover:
            guard let highlight = linkHighlightRange?.first(where: { $0.row == row }) else { return .off }
            return .hovered(highlight.range)
        case .hoverWithModifier:
            guard commandActive,
                  let highlight = linkHighlightRange?.first(where: { $0.row == row }) else { return .off }
            return .hovered(highlight.range)
        }
    }

    /// Everything one row's appearance depends on, as one comparable value. The single definition —
    /// the shaping cache, the on-screen record and the invalidation predicate all key on this, so there
    /// is no way for them to disagree about what "changed" means.
    func rowDrawKey(row: Int, line: BufferLine, cols: Int) -> RowDrawKey {
        RowDrawKey(generation: line.generation,
                   cols: cols,
                   selection: selectedColumnsRange(row: row, cols: cols),
                   link: rowLinkSignature(row: row),
                   customBlockGlyphs: customBlockGlyphs,
                   styleEpoch: rowDrawStyleEpoch)
    }

    /// The shaped state for `row`, from the cache when nothing that feeds it has changed.
    ///
    /// A hit does not require the line to still be at the row it was shaped at — that is the point of
    /// keying by the line. The only thing that can encode the row into the shaped result is a kitty
    /// placeholder, so such a row records ``RowDrawCacheEntry/positionDependent`` and refuses to be
    /// reused anywhere else; every other row travels with its content.
    func rowDrawState(row: Int, line: BufferLine, cols: Int) -> (info: ViewLineInfo, prepared: [PreparedRowSegment]) {
        let key = rowDrawKey(row: row, line: line, cols: cols)
        let identity = ObjectIdentifier(line)
        if let hit = rowDrawCache[identity], hit.lineRef === line, hit.key == key,
           !hit.positionDependent || hit.builtAtRow == row {
            rowDrawCacheHits &+= 1
            return (hit.info, hit.prepared)
        }
        rowDrawCacheMisses &+= 1
        let info = buildAttributedString(row: row, line: line, cols: cols)
        let prepared: [PreparedRowSegment] = info.segments.compactMap { segment in
            guard segment.attributedString.length > 0 else { return nil }
            let ctLine = CTLineCreateWithAttributedString(segment.attributedString)
            guard let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] else { return nil }
            return PreparedRowSegment(segment: segment, ctLine: ctLine, runs: runs)
        }
        rowDrawCache[identity] = RowDrawCacheEntry(lineRef: line,
                                                  key: key,
                                                  builtAtRow: row,
                                                  positionDependent: !info.kittyPlaceholders.isEmpty,
                                                  info: info,
                                                  prepared: prepared)
        return (info, prepared)
    }

    /// Forget every row outside what was just drawn.
    ///
    /// The bound has to be the *screen*, not the buffer: `displayBuffer.lines` runs to the scrollback
    /// limit, so keeping an entry per line would trade this CPU win for a per-pane pile of
    /// `NSAttributedString`s — a worse problem, and a harder one to see. A cache entry also holds its
    /// `BufferLine` alive, so pruning is what keeps scrolled-off lines collectable.
    /// `nil` = nothing is on screen (an empty buffer), so nothing is worth keeping.
    func pruneRowDrawCache(visible: ClosedRange<Int>?) {
        guard !rowDrawCache.isEmpty else { return }
        guard let visible else {
            rowDrawCache.removeAll(keepingCapacity: true)
            return
        }
        let lines = terminal.displayBuffer.lines
        var onScreen = Set<ObjectIdentifier>(minimumCapacity: visible.count)
        for row in visible where row >= 0 && row < lines.count {
            onScreen.insert(ObjectIdentifier(lines[row]))
        }
        rowDrawCache = rowDrawCache.filter { onScreen.contains($0.key) }
    }

    /// The rows inside a dirty band that would actually put different pixels on screen, as one range of
    /// **screen** rows — or nil when none of them would.
    ///
    /// `getUpdateRange()` hands back ONE contiguous range, and moving the cursor marks every row between
    /// its old and new position (`SyncDirtyRangeTests` pins that). A tmux frame that changes one spinner
    /// glyph therefore arrives as a band spanning everything the cursor flew over — measured on real
    /// captures: 65 rows of band for 2.6 rows of change (`DirtyBandProbe`). The view then clears and
    /// repaints that whole band, and clearing plus the CoreAnimation backing-store update that follows
    /// scale with AREA, not with how many cells differ.
    ///
    /// The predicate here is deliberately **the same one the draw path uses** — a `rowDrawCache` hit
    /// (same line, same key) — rather than a second, parallel notion of "changed" that could drift from
    /// it. A row with no cache entry counts as changed: no entry means no evidence its pixels are on
    /// screen (it may never have been drawn, or have been pruned).
    ///
    /// This narrows what we ASK for. It does **not** let the draw path skip rows inside the rect it is
    /// given: whatever AppKit hands `drawTerminalContents` is still cleared and repainted in full. That
    /// is what keeps this free of the ghosting class of bug — if the backing store is lost, or anything
    /// else invalidates us, AppKit asks for a bigger rect and every row in it is redrawn.
    func visuallyChangedRowBand(rowStart: Int, rowEnd: Int) -> ClosedRange<Int>? {
        guard let runs = visuallyChangedRowRuns(rowStart: rowStart, rowEnd: rowEnd) else { return nil }
        return runs[0].lowerBound...runs[runs.count - 1].upperBound
    }

    /// The same answer as ``visuallyChangedRowBand(rowStart:rowEnd:)``, but **as the runs it is made of**
    /// instead of collapsed into one band — in ascending row order, non-overlapping, already padded.
    ///
    /// Why the runs matter: the band is one rectangle, so two changed rows at opposite ends of the pane
    /// invalidate everything between them. That is the shape a full-screen TUI produces every frame — it
    /// touches its transcript area AND its status line — and it was measured in the field (fleetmux,
    /// 2026-09-09): a 66-row pane repainting all 66 rows, 9–12 times a second, while the row cache said
    /// most of those rows had not changed at all. Handing AppKit one rect per run keeps the untouched
    /// middle out of the dirty region, and out of the backing-store update that follows it.
    ///
    /// Padding is per run (a descender from the row above reaches into this one), and runs that touch
    /// after padding are merged — two rects that share an edge are one rect's worth of work.
    func visuallyChangedRowRuns(rowStart: Int, rowEnd: Int) -> [ClosedRange<Int>]? {
        let buffer = terminal.displayBuffer
        let cols = buffer.cols
        var runs: [ClosedRange<Int>] = []
        var runLo = -1
        var runHi = -1
        func closeRun() {
            guard runHi >= runLo, runLo >= 0 else { return }
            let padded = max(0, runLo - 1)...min(terminal.rows - 1, runHi + 1)
            // Merge with the previous run when padding made them touch or overlap.
            if let last = runs.last, padded.lowerBound <= last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound...max(last.upperBound, padded.upperBound)
            } else {
                runs.append(padded)
            }
            runLo = -1
            runHi = -1
        }
        for y in rowStart...rowEnd {
            let absolute = buffer.yDisp + y
            // Out of the buffer entirely → we cannot reason about it; repaint the band as before.
            guard absolute >= 0, absolute < buffer.lines.count else { return [rowStart...rowEnd] }
            let line = buffer.lines[absolute]
            if let onScreen = rowsOnScreen[y], onScreen.lineRef === line,
               onScreen.key == rowDrawKey(row: absolute, line: line, cols: cols) {
                closeRun()
                continue
            }
            if runLo < 0 { runLo = y }
            runHi = y
        }
        closeRun()
        return runs.isEmpty ? nil : runs
    }

    /// Record what the backing store now holds, for the rows a draw painted **in full**.
    ///
    /// Keyed by SCREEN row, which is the coordinate pixels actually live at — so scrolling invalidates
    /// itself: after the display moves, screen row 5 holds a different `BufferLine`, the identity check
    /// fails, and the row is repainted.
    ///
    /// Why this is not just `rowDrawCache`: that table answers "have we shaped this row before", and
    /// `drawTerminalContents` shapes every row that *intersects* the dirty rect — including a boundary
    /// row whose pixels are then clipped away. Reading it as "these pixels are on screen" left exactly
    /// those clipped rows stale (`NarrowedInvalidationRenderTests` on the btop corpus). Two questions,
    /// two records; they share the key so they cannot disagree about what changed.
    func noteRowsOnScreen(rows: ClosedRange<Int>, bufferOffset: Int) {
        let lines = terminal.displayBuffer.lines
        for absolute in rows {
            guard absolute >= 0, absolute < lines.count else { continue }
            guard let entry = rowDrawCache[ObjectIdentifier(lines[absolute])] else { continue }
            rowsOnScreen[absolute - bufferOffset] = RowOnScreen(lineRef: entry.lineRef, key: entry.key)
        }
    }

    /// Nothing on screen can be vouched for any more (the view is about to redraw from scratch).
    func forgetRowsOnScreen() {
        rowsOnScreen.removeAll(keepingCapacity: true)
    }

    // MARK: - test seam

    /// How many rows are currently cached. Lets a test assert pruning without reaching into storage.
    var rowDrawCacheCountForTesting: Int { rowDrawCache.count }

    /// Hits and misses since the last reset. See ``TerminalView/rowDrawCacheHits``.
    var rowDrawCacheStatsForTesting: (hits: Int, misses: Int) { (rowDrawCacheHits, rowDrawCacheMisses) }

    func resetRowDrawCacheStatsForTesting() {
        rowDrawCacheHits = 0
        rowDrawCacheMisses = 0
    }
}
