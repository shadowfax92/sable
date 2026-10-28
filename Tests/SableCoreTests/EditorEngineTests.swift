import XCTest
@testable import SableCore

final class EditorEngineTests: XCTestCase {
    private func engine(_ text: String, _ cursor: Int = 0, mode: EditorMode = .normal) -> EditorEngine {
        EditorEngine(state: EditorState(text: text, selection: .init(anchor: cursor, head: cursor), mode: mode))
    }

    @discardableResult
    private func keys(_ input: String, _ engine: inout EditorEngine) throws -> EditorUpdate {
        var update = EditorUpdate(state: engine.state, disposition: .handled)
        for (index, key) in input.enumerated() {
            update = try engine.handle(.key(.character(key), timestamp: Double(index)))
        }
        return update
    }

    func testMotionTable() throws {
        let cases: [(String, Int, String, Int)] = [
            ("one two! end", 0, "w", 4), ("one two! end", 0, "2w", 7),
            ("one two! end", 6, "b", 4), ("one two! end", 0, "e", 2),
            ("one two! end", 2, "e", 6), ("  one\nnext", 4, "0", 0),
            ("  one\nnext", 4, "^", 2), ("  one\nnext", 0, "$", 4),
            ("one\ntwo\nthree", 5, "gg", 0), ("one\ntwo\nthree", 0, "G", 8),
            ("one\ntwo\nthree", 0, "2G", 4), ("one\ntwo\nthree", 0, "2gg", 4),
            ("abc\nq\nabcdef", 2, "jj", 8), ("abc\nq\nabcdef", 2, "jkj", 4),
            ("abc\nq\nabcdef", 2, "j$j", 6), ("abc\n", 0, "j", 4),
            ("abc", 0, "99l", 2), ("abc", 2, "99h", 0),
            ("", 0, "hjklwbe0^$ggG", 0), ("a\n\nb", 0, "j", 2),
        ]
        for (text, cursor, command, expected) in cases {
            var editor = engine(text, cursor)
            try keys(command, &editor)
            XCTAssertEqual(editor.state.cursor, expected, "\(text.debugDescription) at \(cursor): \(command)")
            XCTAssertEqual(editor.state.text, text)
        }
    }

    func testOperatorTable() throws {
        let cases: [(String, Int, String, String, Int, EditorMode)] = [
            ("one two three", 0, "dw", "two three", 0, .normal),
            ("one two three", 0, "2dw", "three", 0, .normal),
            ("one two three", 0, "d2w", "three", 0, .normal),
            ("one two three", 0, "cw", " two three", 0, .insert),
            ("one two three", 5, "ciw", "one  three", 4, .insert),
            ("one, two", 3, "ciw", "one two", 3, .insert),
            ("abc\ndef", 1, "D", "a\ndef", 0, .normal),
            ("abc\ndef", 1, "d$", "a\ndef", 0, .normal),
            ("abc\ndef", 1, "C", "a\ndef", 1, .insert),
            ("abc\ndef", 1, "c$", "a\ndef", 1, .insert),
            ("abc\ndef\nghi", 1, "dd", "def\nghi", 0, .normal),
            ("abc\ndef\nghi", 5, "dd", "abc\nghi", 4, .normal),
            ("abc\ndef", 5, "dd", "abc", 0, .normal),
            ("abc\n", 4, "dd", "abc", 0, .normal),
            ("abc\ndef\nghi", 1, "2dd", "ghi", 0, .normal),
            ("abc\ndef", 0, "dG", "", 0, .normal),
            ("abc\ndef\nghi", 5, "dgg", "ghi", 0, .normal),
            ("abc\ndef", 1, "x", "ac\ndef", 1, .normal),
            ("👩🏽‍💻e\u{301}🇺🇸", 0, "2x", "🇺🇸", 0, .normal),
            ("a\nb", 0, "99x", "\nb", 0, .normal),
        ]
        for (text, cursor, command, expected, position, mode) in cases {
            var editor = engine(text, cursor)
            try keys(command, &editor)
            XCTAssertEqual(editor.state.text, expected, command)
            XCTAssertEqual(editor.state.cursor, position, command)
            XCTAssertEqual(editor.state.mode, mode, command)
        }
    }

    func testInsertEntryAndOpenLineTable() throws {
        let cases: [(String, Int, String, String, Int)] = [
            ("  abc", 3, "i", "  abc", 3), ("  abc", 3, "a", "  abc", 4),
            ("  abc", 3, "I", "  abc", 2), ("  abc", 3, "A", "  abc", 5),
            ("abc\ndef", 1, "o", "abc\n\ndef", 4),
            ("abc\ndef", 5, "O", "abc\n\ndef", 4),
            ("abc", 0, "o", "abc\n", 4), ("abc", 0, "O", "\nabc", 0),
            ("", 0, "a", "", 0), ("", 0, "o", "\n", 1),
        ]
        for (text, cursor, command, expected, position) in cases {
            var editor = engine(text, cursor)
            try keys(command, &editor)
            XCTAssertEqual(editor.state, EditorState(text: expected, selection: .init(anchor: position, head: position), mode: .insert), command)
        }
    }

    func testEffectsAndNativeInsertionOwnership() throws {
        var editor = engine("abc")
        XCTAssertEqual(try editor.handle(.key(.enter, timestamp: 0)).effects, [.copyAndClose("abc")])
        try keys("i", &editor)
        XCTAssertEqual(try editor.handle(.key(.enter, timestamp: 1)).disposition, .passToNative)
        XCTAssertEqual(try editor.handle(.key(.tab, timestamp: 2)).disposition, .passToNative)
        XCTAssertEqual(try editor.handle(.key(.character("文"), timestamp: 3)).disposition, .passToNative)
        _ = try editor.handle(.nativeUpdate(text: "文\nabc", selection: .init(anchor: 2, head: 2)))
        XCTAssertEqual(try editor.handle(.key(.enter, modifiers: .command, timestamp: 4)).effects, [.pasteAndClose("文\nabc")])
        XCTAssertTrue(try editor.handle(.key(.escape, timestamp: 5)).effects.isEmpty)
        XCTAssertEqual(editor.state.mode, .normal)
        XCTAssertEqual(try editor.handle(.key(.escape, timestamp: 6)).effects, [.cancel])
        try keys("v", &editor)
        XCTAssertEqual(try editor.handle(.key(.enter, modifiers: .command, timestamp: 7)).effects, [.pasteAndClose("文\nabc")])
    }

    func testChordsRequireExactNativeJAndTimelyUnmodifiedSecondKey() throws {
        for second: Character in ["j", "k"] {
            var editor = engine("abc", 1, mode: .insert)
            XCTAssertEqual(try editor.handle(.key(.character("j"), timestamp: 10)).disposition, .passToNative)
            XCTAssertEqual(editor.state.text, "abc", "Native insertion remains adapter-owned")
            _ = try editor.handle(.nativeUpdate(text: "ajbc", selection: .init(anchor: 2, head: 2)))
            XCTAssertEqual(try editor.handle(.key(.character(second), timestamp: 10.2)).disposition, .handled)
            XCTAssertEqual(editor.state.text, "abc")
            XCTAssertEqual(editor.state.mode, .normal)
            XCTAssertEqual(editor.state.cursor, 0)
        }
        for boundary in ["slow", "flush", "selection", "native", "modified", "backwards-time", "nan"] {
            var editor = engine("", mode: .insert)
            _ = try editor.handle(.key(.character("j"), timestamp: 10))
            _ = try editor.handle(.nativeUpdate(text: "j", selection: .init(anchor: 1, head: 1)))
            if boundary == "flush" { _ = try editor.handle(.flushPendingInput) }
            if boundary == "selection" { _ = try editor.handle(.setSelection(.init(anchor: 1, head: 1))) }
            if boundary == "native" { _ = try editor.handle(.nativeUpdate(text: "j!", selection: .init(anchor: 2, head: 2))) }
            let time = boundary == "slow" ? 11.0 : boundary == "backwards-time" ? 9.0 : boundary == "nan" ? .nan : 10.1
            let update = try editor.handle(.key(.character("k"), modifiers: boundary == "modified" ? .option : [], timestamp: time))
            XCTAssertEqual(update.disposition, .passToNative, boundary)
            XCTAssertEqual(editor.state.text, boundary == "native" ? "j!" : "j", boundary)
            XCTAssertEqual(editor.state.mode, .insert, boundary)
        }
    }

    func testUnconfirmedJSelectionReplacementAndCommitNeverLoseText() throws {
        var editor = engine("abc", mode: .insert)
        _ = try editor.handle(.key(.character("j"), timestamp: 0))
        XCTAssertEqual(try editor.handle(.key(.character("k"), timestamp: 0.1)).disposition, .passToNative)
        _ = try editor.handle(.nativeUpdate(text: "paste 👩🏽‍💻", selection: .init(anchor: 7, head: 7)))
        _ = try editor.handle(.key(.character("j"), timestamp: 1))
        _ = try editor.handle(.nativeUpdate(text: "paste 👩🏽‍💻j", selection: .init(anchor: 8, head: 8)))
        XCTAssertEqual(try editor.handle(.key(.enter, modifiers: .command, timestamp: 1.1)).effects, [.pasteAndClose("paste 👩🏽‍💻j")])
        _ = try editor.handle(.key(.escape, timestamp: 1.2))
        XCTAssertEqual(editor.state.text, "paste 👩🏽‍💻j")
    }

    func testVisualInclusiveSelectionYankPasteAndNativeSelection() throws {
        var editor = engine("abcd")
        try keys("vl", &editor)
        XCTAssertEqual(editor.state.selection.range, 0..<2)
        try keys("y", &editor)
        XCTAssertEqual(editor.state.mode, .normal)
        try keys("$p", &editor)
        XCTAssertEqual(editor.state.text, "abcdab")
        _ = try editor.handle(.setSelection(.init(anchor: 3, head: 1)))
        XCTAssertEqual(editor.state.mode, .visual)
        XCTAssertEqual(editor.state.selection, .init(anchor: 3, head: 1))
        try keys("d", &editor)
        XCTAssertEqual(editor.state.text, "adab")
        try keys("P", &editor)
        XCTAssertEqual(editor.state.text, "abcdab")
    }

    func testLinewiseRegisterRetainsKindAndTrailingLine() throws {
        for (text, command, expected) in [
            ("a\nb", "yyp", "a\na\nb"), ("a\nb", "jddp", "a\nb"),
            ("a\n", "jyyp", "a\n\n"), ("a", "yyP", "a\na"),
            ("", "yyp", "\n"), ("a\nb", "yy2p", "a\na\na\nb"),
        ] {
            var editor = engine(text)
            try keys(command, &editor)
            XCTAssertEqual(editor.state.text, expected, command)
        }
    }

    func testUndoRedoIncludesNativeTransactionsAndChangeSession() throws {
        var editor = engine("one two")
        try keys("cw", &editor)
        _ = try editor.handle(.nativeUpdate(text: "new two", selection: .init(anchor: 3, head: 3)))
        _ = try editor.handle(.nativeUpdate(text: "new! two", selection: .init(anchor: 4, head: 4)))
        _ = try editor.handle(.key(.escape, timestamp: 0))
        try keys("u", &editor)
        XCTAssertEqual(editor.state.text, "one two")
        _ = try editor.handle(.key(.character("r"), modifiers: .control, timestamp: 1))
        XCTAssertEqual(editor.state.text, "new! two")
        try keys("i", &editor)
        _ = try editor.handle(.nativeUpdate(text: "changed", selection: .init(anchor: 7, head: 7)))
        _ = try editor.handle(.key(.character("z"), modifiers: .command, timestamp: 2))
        XCTAssertEqual(editor.state.text, "new! two")
        XCTAssertEqual(editor.state.mode, .insert)
        _ = try editor.handle(.key(.character("z"), modifiers: [.command, .shift], timestamp: 3))
        XCTAssertEqual(editor.state.text, "changed")
        _ = try editor.handle(.nativeUpdate(text: "branch", selection: .init(anchor: 6, head: 6)))
        _ = try editor.handle(.key(.escape, timestamp: 4))
        try keys("u", &editor)
        XCTAssertEqual(editor.state.text, "changed")
    }

    func testUnicodeLineBoundariesAndVisualReverseMotions() throws {
        var editor = engine("e\u{301}👩🏽‍💻🇺🇸\r\n字\r\n")
        try keys("$", &editor)
        XCTAssertEqual(editor.state.cursor, 2)
        try keys("j", &editor)
        XCTAssertEqual(editor.state.cursor, 4)
        try keys("j", &editor)
        XCTAssertEqual(editor.state.cursor, 6)
        try keys("kk", &editor)
        XCTAssertEqual(editor.state.cursor, 2)
        try keys("vhh", &editor)
        XCTAssertEqual(editor.state.selection, .init(anchor: 3, head: 0))
        try keys("l", &editor)
        XCTAssertEqual(editor.state.selection.range, 1..<3)
        try keys("d", &editor)
        XCTAssertEqual(editor.state.text, "e\u{301}\r\n字\r\n")
        try keys("u", &editor)
        XCTAssertEqual(editor.state.text, "e\u{301}👩🏽‍💻🇺🇸\r\n字\r\n")
    }

    func testEmptyLineOperatorsAndNativeSelectionClamping() throws {
        for command in ["dw", "cw", "ciw", "x", "d$", "c$"] {
            var editor = engine("a\n\nb", 2)
            try keys(command, &editor)
            if command == "dw" { XCTAssertEqual(editor.state.text, "a\nb") }
            else { XCTAssertEqual(editor.state.text, "a\n\nb", command) }
        }
        var editor = engine("abc")
        _ = try editor.handle(.setSelection(.init(anchor: 99, head: -1)))
        XCTAssertEqual(editor.state.selection.range, 0..<3)
        try keys("c", &editor)
        XCTAssertEqual(editor.state.text, "")
        _ = try editor.handle(.nativeUpdate(text: "👩🏽‍💻", selection: .init(anchor: 99, head: 99)))
        XCTAssertEqual(editor.state.cursor, 1)
        _ = try editor.handle(.key(.escape, timestamp: 0))
        try keys("u", &editor)
        XCTAssertEqual(editor.state.text, "abc")
    }

    func testChordsReplaceSelectionSafelyAndJoinInsertUndo() throws {
        var editor = engine("abc")
        try keys("i", &editor)
        _ = try editor.handle(.nativeUpdate(text: "Xabc", selection: .init(anchor: 1, head: 1)))
        _ = try editor.handle(.key(.character("j"), timestamp: 1))
        _ = try editor.handle(.nativeUpdate(text: "Xjabc", selection: .init(anchor: 2, head: 2)))
        _ = try editor.handle(.key(.character("k"), timestamp: 1.1))
        XCTAssertEqual(editor.state.text, "Xabc")
        try keys("u", &editor)
        XCTAssertEqual(editor.state.text, "abc")
        try keys("i", &editor)
        _ = try editor.handle(.setSelection(.init(anchor: 0, head: 2)))
        _ = try editor.handle(.key(.character("j"), timestamp: 2))
        _ = try editor.handle(.nativeUpdate(text: "jc", selection: .init(anchor: 1, head: 1)))
        _ = try editor.handle(.key(.character("j"), timestamp: 2.1))
        XCTAssertEqual(editor.state.text, "abc", "Chord rollback restores precisely the selected replacement")
    }

    func testDeterministicMixedSequencesKeepRangesValid() throws {
        var seed: UInt64 = 0x5ab1e
        let inputs = Array("hjk lwbe0^$igGvaIAoOxdcywpPu1239?!")
        for text in ["", "\n", "one two\n\nlast\n", "e\u{301}👩🏽‍💻\r\n🇺🇸"] {
            var editor = engine(text)
            for step in 0..<600 {
                seed = seed &* 6364136223846793005 &+ 1
                let key = inputs[Int((seed >> 32) % UInt64(inputs.count))]
                if editor.state.mode == .insert {
                    _ = try editor.handle(.key(.escape, timestamp: Double(step)))
                } else {
                    _ = try editor.handle(.key(.character(key), timestamp: Double(step)))
                }
                let state = editor.state
                XCTAssertTrue((0...state.text.count).contains(state.selection.anchor))
                XCTAssertTrue((0...state.text.count).contains(state.selection.head))
                if state.mode == .normal { XCTAssertTrue(state.selection.isEmpty) }
                // Avoid unbounded document growth while still exercising real paste.
                if state.text.count > 2_000 { break }
            }
        }
    }

    func testWordChangeRetainsFollowingWordsAndLineSeparators() throws {
        let cases: [(String, Int, String, String)] = [
            ("a b", 0, "cw", " b"), ("one two", 2, "cw", "on two"),
            ("a\nb", 0, "cw", "\nb"), ("a b c", 0, "c2w", " c"),
            ("a \nb", 1, "dw", "a\nb"), ("a \nb", 1, "cw", "a\nb"),
            ("a \nb c", 1, "d2w", "ac"), ("a\n\nb", 2, "dw", "a\nb"),
        ]
        for (text, cursor, command, expected) in cases {
            var editor = engine(text, cursor)
            try keys(command, &editor)
            XCTAssertEqual(editor.state.text, expected, "\(command) at \(cursor) in \(text.debugDescription)")
        }
    }

    func testHorizontalOperatorEndpointsIncludeFinalCell() throws {
        for command in ["dl", "cl", "ylp"] {
            var editor = engine("abc", 2)
            try keys(command, &editor)
            XCTAssertEqual(editor.state.text, command == "ylp" ? "abcc" : "ab", command)
        }
        var editor = engine("abc", 1)
        try keys("d2l", &editor)
        XCTAssertEqual(editor.state.text, "a")
        editor = engine("abc\ndef", 2)
        try keys("99dl", &editor)
        XCTAssertEqual(editor.state.text, "ab\ndef")
    }

    func testChordRollbackPreservesRedoBranch() throws {
        for second: Character in ["j", "k"] {
            var editor = engine("abc")
            try keys("xui", &editor)
            _ = try editor.handle(.key(.character("j"), timestamp: 1))
            _ = try editor.handle(.nativeUpdate(text: "jabc", selection: .init(anchor: 1, head: 1)))
            _ = try editor.handle(.key(.character(second), timestamp: 1.1))
            _ = try editor.handle(.key(.character("r"), modifiers: .control, timestamp: 2))
            XCTAssertEqual(editor.state.text, "bc")
        }
    }

    func testOpenLinesPreserveNewlineGraphemes() throws {
        for newline in ["\n", "\r", "\r\n"] {
            for command in ["o", "jO"] {
                var editor = engine("a" + newline + "b")
                try keys(command, &editor)
                XCTAssertEqual(editor.state.text, "a" + newline + newline + "b", command)
                XCTAssertEqual(editor.state.cursor, 2, "Newline is one Character even for CRLF")
            }
        }
    }

    func testRejectedPrefixesDoNotLeakIntoNextCommand() throws {
        var editor = engine("abc")
        XCTAssertEqual(try keys("dgx", &editor).disposition, .unsupported)
        XCTAssertEqual(editor.state.text, "abc")
        try keys("x", &editor)
        XCTAssertEqual(editor.state.text, "bc")
        try keys("d", &editor)
        _ = try editor.handle(.key(.character("a"), modifiers: .command, timestamp: 0))
        try keys("x", &editor)
        XCTAssertEqual(editor.state.text, "c")
    }

    func testUnknownCommandsClearOperatorsAndRejectNormalNativeUpdates() throws {
        for command in ["d?x", "dg?x", "di?x", "c?x", "2?x", "g?x"] {
            var editor = engine("abcd")
            try keys(command, &editor)
            XCTAssertEqual(editor.state.text, "bcd", command)
            XCTAssertEqual(editor.state.mode, .normal)
        }
        var editor = engine("abc")
        XCTAssertEqual(try keys("r", &editor).disposition, .unsupported)
        XCTAssertEqual(try editor.handle(.nativeUpdate(text: "lost", selection: .init(anchor: 0, head: 0))).disposition, .unsupported)
        XCTAssertEqual(editor.state.text, "abc")
        try keys("d", &editor)
        _ = try editor.handle(.key(.escape, timestamp: 0))
        try keys("x", &editor)
        XCTAssertEqual(editor.state.text, "bc")
    }
}
