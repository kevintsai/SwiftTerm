//
//  SyntheticSpinnerCorpus.swift
//
//  The shape a waiting agent's pane has, without anybody's actual terminal contents in it.
//
//  Measured off a real `tmux -T sync attach` while a claude session sat spinning: ~9 frames/s, ~78 bytes
//  per frame, and each frame is
//
//      BSU · hide cursor · home · down N · one spinner glyph · cursor to the bottom · show cursor · ESU
//
//  which is why the dirty band is the whole screen for a single glyph — `getUpdateRange()` is one range,
//  and it has to cover everywhere the cursor went. That shape is the whole point, so it is reproduced here
//  rather than committed: real captures are somebody's session (`RowDrawCacheBenchmark` keeps the same
//  rule, and `SWIFTTERM_NARROW_CORPUS=<path>` still points the tests at one for local measurement).
//
import Foundation

enum SyntheticSpinnerCorpus {
    private static let glyphs = ["✳", "✢", "✶", "✻", "✽", "⏺"]

    /// `count` frames for a `rows`-tall screen, each moving the spinner glyph and flying the cursor from
    /// the top to the bottom of the screen and back.
    static func frames(count: Int = 80, rows: Int = 66) -> [[UInt8]] {
        return (0..<count).map { i in
            let glyph = glyphs[i % glyphs.count]
            let spinnerRow = 22
            let bottom = max(rows - 2, 1)
            let inputRow = max(rows - 10, 1)
            var s = "\u{1b}[?2026h\u{1b}[?25l"          // begin synchronized update, hide cursor
            s += "\u{1b}[H"                              // home — this is what pins the band's top at 0
            s += "\u{1b}[\(spinnerRow);1H"               // to the spinner's row
            s += "\u{1b}[38;5;174m\(glyph)\u{1b}[39m"    // the one cell that actually changes
            s += "\u{1b}[\(bottom);1H"                   // …and the cursor flies to the bottom
            s += "\u{1b}[\(inputRow);3H"                 // then back up to the input line
            s += "\u{1b}[?25h\u{1b}[?2026l"              // show cursor, end synchronized update
            return Array(s.utf8)
        }
    }
}
