import Testing
@testable import SwiftTerm

#if os(macOS)
import AppKit
#endif

/// Legacy (non-kitty) Control+key encoding. The interesting cases are the punctuation keys:
/// letters fall out of the ASCII arithmetic, punctuation is pure xterm convention.
struct ControlKeyEncodingTests {
#if os(macOS)
    private func controlBytes(_ characters: String) -> [UInt8] {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        return view.applyControlToEventCharacters(characters)
    }

    /// Control+/ is what editors read as `<C-_>` (Comment.nvim's default toggler, emacs' undo).
    /// It has no ASCII derivation, so a terminal that only does the arithmetic sends nothing at all.
    @Test func controlSlashSendsUnitSeparator() {
        #expect(controlBytes("/") == [0x1f])
    }

    @Test func controlUnderscoreSendsUnitSeparator() {
        #expect(controlBytes("_") == [0x1f])
    }

    @Test func controlLettersUseAsciiArithmetic() {
        #expect(controlBytes("c") == [0x03])
        #expect(controlBytes("C") == [0x03])
        #expect(controlBytes("a") == [0x01])
    }

    @Test func controlBracketsAndFriends() {
        #expect(controlBytes("[") == [0x1b])
        #expect(controlBytes("]") == [0x1d])
        #expect(controlBytes("\\") == [0x1c])
        #expect(controlBytes("^") == [0x1e])
        #expect(controlBytes(" ") == [0x00])
    }

    /// Keys with no control meaning stay silent rather than leaking a bare character.
    @Test func unmappedPunctuationSendsNothing() {
        #expect(controlBytes(".") == [])
        #expect(controlBytes(",") == [])
    }
#endif
}
