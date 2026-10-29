import XCTest
@testable import SableCore

/// Drives the same semantic events as the native adapter, without a text view,
/// clipboard, windows or timing dependencies. Search-field edits are complete
/// replacements, so IME/paste cannot accidentally become document mutations.
final class EditorVimSearchTests: XCTestCase {
    private func editor(_ text: String, at cursor: Int = 0) -> EditorEngine {
        EditorEngine(state: .init(text: text, selection: .init(anchor: cursor, head: cursor)))
    }

    @discardableResult
    private func keys(_ keys: String, _ engine: inout EditorEngine) throws -> EditorUpdate {
        var result = EditorUpdate(state: engine.state, disposition: .handled)
        for key in keys {
            result = try engine.handle(.key(.character(key), timestamp: 0))
            XCTAssertEqual(result.state, engine.state)
        }
        return result
    }

    @discardableResult
    private func search(_ query: String, _ engine: inout EditorEngine, backward: Bool = false) throws -> EditorUpdate {
        try keys(backward ? "?" : "/", &engine)
        _ = try engine.handle(.setSearchQuery(query))
        return try engine.handle(.acceptSearch)
    }

    func testLineSelectionIncludesNewlineAndPublishesCaretWithinTheLine() throws {
        var engine = editor("abcd\nxy\nlast", at: 2)
        try keys("V", &engine)
        XCTAssertEqual(engine.state.mode, .visual)
        XCTAssertEqual(engine.state.visualSelectionKind, .line)
        XCTAssertEqual(engine.state.selection, .init(anchor: 0, head: 5))
        XCTAssertEqual(engine.state.activeCursor, 2)
        XCTAssertEqual(engine.state.visualAnchor, 2)
        try keys("j", &engine)
        XCTAssertEqual(engine.state.selection, .init(anchor: 0, head: 8))
        XCTAssertEqual(engine.state.activeCursor, 6)
        try keys("j", &engine)
        XCTAssertEqual(engine.state.selection.range, 0..<12)
        XCTAssertEqual(engine.state.activeCursor, 10, "Vertical goal column survives a short line")
        _ = try engine.handle(.key(.escape, timestamp: 1))
        XCTAssertEqual(engine.state.cursor, 10)
        XCTAssertEqual(engine.state.visualSelectionKind, .character)
        XCTAssertNil(engine.state.visualAnchor)
    }

    func testReverseLineSelectionRetainsAnchorThroughCrossing() throws {
        var engine = editor("aa\nbb\ncc", at: 4)
        try keys("Vk", &engine)
        XCTAssertEqual(engine.state.selection, .init(anchor: 6, head: 0))
        XCTAssertEqual(engine.state.activeCursor, 1)
        XCTAssertEqual(engine.state.visualAnchor, 4)
        try keys("jj", &engine)
        XCTAssertEqual(engine.state.selection, .init(anchor: 3, head: 8))
        XCTAssertEqual(engine.state.activeCursor, 7)
        XCTAssertEqual(engine.state.visualAnchor, 4)
        try keys("d", &engine)
        XCTAssertEqual(engine.state.text, "aa")
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "aa\nbb\ncc")
        XCTAssertEqual(engine.state.mode, .normal)
        XCTAssertEqual(engine.state.visualSelectionKind, .character)
        XCTAssertEqual(engine.state.activeCursor, engine.state.cursor)
    }

    func testVisualKindsToggleAndSwitchUsingTheRealActiveCell() throws {
        var engine = editor("abcd\nlast", at: 2)
        try keys("Vv", &engine)
        XCTAssertEqual(engine.state.visualSelectionKind, .character)
        XCTAssertEqual(engine.state.selection.range, 2..<3)
        try keys("V", &engine)
        XCTAssertEqual(engine.state.selection.range, 0..<5)
        try keys("V", &engine)
        XCTAssertEqual(engine.state.mode, .normal)
        XCTAssertEqual(engine.state.cursor, 2)
        try keys("vV", &engine)
        XCTAssertEqual(engine.state.visualSelectionKind, .line)
        XCTAssertEqual(engine.state.selection.range, 0..<5)
    }

    func testLineSelectionsHandleBlankFinalTrailingAndUnicodeLines() throws {
        for (text, cursor, selection, afterDelete) in [
            ("a\n\nb", 2, 2..<3, "a\nb"),
            ("a\nb", 2, 2..<3, "a"),
            ("a\n", 2, 2..<2, "a"),
            ("", 0, 0..<0, ""),
            ("👩🏽‍💻e\u{301}\r\n🇺🇸", 0, 0..<3, "🇺🇸"),
        ] {
            var engine = editor(text, at: cursor)
            try keys("V", &engine)
            XCTAssertEqual(engine.state.selection.range, selection, text.debugDescription)
            try keys("d", &engine)
            XCTAssertEqual(engine.state.text, afterDelete)
            try keys("u", &engine)
            XCTAssertEqual(engine.state.text, text)
            XCTAssertEqual(engine.state.visualSelectionKind, .character)
        }
        var engine = editor("a\nb\n", at: 4)
        try keys("Vkk", &engine)
        XCTAssertEqual(engine.state.selection, .init(anchor: 4, head: 0))
        XCTAssertEqual(engine.state.visualAnchor, 4, "Empty trailing anchor is not the preceding line")
        try keys("2j", &engine)
        XCTAssertEqual(engine.state.selection, .init(anchor: 4, head: 4))
        XCTAssertEqual(engine.state.activeCursor, 4)
    }

    func testLineYankDeletePasteAndUndoRespectRegisterKind() throws {
        for (text, cursor, command, expected) in [
            ("aa\nbb\ncc", 0, "Vyp", "aa\naa\nbb\ncc"),
            ("aa\nbb\ncc", 3, "Vdp", "aa\ncc\nbb"),
            ("aa\nbb\ncc", 6, "Vkdp", "aa\nbb\ncc"),
            ("a\n", 2, "Vyp", "a\n\n"),
            ("a\nb", 0, "Vy2p", "a\na\na\nb"),
        ] {
            var engine = editor(text, at: cursor)
            try keys(command, &engine)
            XCTAssertEqual(engine.state.text, expected, command)
            try keys("u", &engine)
            if command.contains("d") { try keys("u", &engine) }
            XCTAssertEqual(engine.state.text, text, command)
        }
        var engine = editor("a\nb\nc")
        try keys("VjyGVp", &engine)
        XCTAssertEqual(engine.state.text, "a\nb\na\nb")
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "a\nb\nc")
    }

    func testLinePasteOfCharacterRegisterAndChangeGroup() throws {
        var engine = editor("ab\ncd\nef")
        try keys("vlyjVp", &engine)
        XCTAssertEqual(engine.state.text, "ab\nabef", "Character register replaces the complete selected line, including newline")
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "ab\ncd\nef")
        try keys("Vc", &engine)
        XCTAssertEqual(engine.state.mode, .insert)
        _ = try engine.handle(.nativeUpdate(text: "new\ncd\nef", selection: .init(anchor: 3, head: 3)))
        _ = try engine.handle(.key(.escape, timestamp: 1))
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "ab\ncd\nef")
    }

    func testNativeSelectionKeepsLineKindCanonicalAndSnapshotCanStartSession() throws {
        var engine = editor("abcd\nef\nlast", at: 1)
        try keys("V", &engine)
        _ = try engine.handle(.setSelection(.init(anchor: 1, head: 7)))
        XCTAssertEqual(engine.state.visualSelectionKind, .line)
        XCTAssertEqual(engine.state.selection, .init(anchor: 0, head: 8))
        XCTAssertEqual(engine.state.activeCursor, 6)
        XCTAssertEqual(engine.state.visualAnchor, 1)
        let snapshot = engine.state
        engine = EditorEngine(state: snapshot)
        XCTAssertEqual(engine.state, snapshot)
        try keys("k", &engine)
        XCTAssertEqual(engine.state.selection.range, 0..<5)
        _ = try engine.handle(.setSelection(.init(anchor: 7, head: 1)))
        XCTAssertEqual(engine.state.selection, .init(anchor: 8, head: 0))
        XCTAssertEqual(engine.state.activeCursor, 1)
        XCTAssertEqual(engine.state.visualAnchor, 6)
        _ = try engine.handle(.setSelection(.init(anchor: 99, head: -99)))
        XCTAssertEqual(engine.state.selection, .init(anchor: 12, head: 0))
        XCTAssertEqual(engine.state.activeCursor, 0)
    }

    func testCountsAndMotionsExtendLogicalLineSelection() throws {
        var engine = editor("ab\ncd\nef\ngh")
        try keys("2V", &engine)
        XCTAssertEqual(engine.state.selection.range, 0..<6)
        try keys("G", &engine)
        XCTAssertEqual(engine.state.selection.range, 0..<11)
        try keys("gg", &engine)
        XCTAssertEqual(engine.state.selection.range, 0..<3)
        try keys("2w", &engine)
        XCTAssertEqual(engine.state.selection.range, 0..<9)
    }

    func testSearchOpensPreviewsReplacesAndAcceptsWithoutDocumentOrDeliveryEffects() throws {
        let text = "one TWO one two"
        var engine = editor(text)
        try keys("/", &engine)
        XCTAssertEqual(engine.state.search?.isActive, true)
        XCTAssertEqual(engine.state.search?.query, "")
        _ = try engine.handle(.setSearchQuery("two"))
        XCTAssertEqual(engine.state.activeCursor, 4)
        XCTAssertEqual(engine.state.search?.match, 4..<7)
        XCTAssertEqual(engine.state.search?.matchIndex, 1)
        XCTAssertEqual(engine.state.search?.matchCount, 2)
        _ = try engine.handle(.setSearchQuery("one"))
        XCTAssertEqual(engine.state.activeCursor, 8, "Replacement previews from the opening caret, not the previous result")
        let accepted = try engine.handle(.key(.enter, timestamp: 0))
        XCTAssertTrue(accepted.effects.isEmpty)
        XCTAssertEqual(accepted.disposition, .handled)
        XCTAssertEqual(accepted.state.search?.isActive, false)
        XCTAssertEqual(accepted.state.text, text)
        XCTAssertEqual(try engine.handle(.key(.enter, timestamp: 1)).effects, [.copyAndClose(text)])
    }

    func testSearchCommandEnterAlsoAcceptsAndNeverDelivers() throws {
        var engine = editor("a b a")
        try keys("/a", &engine)
        let update = try engine.handle(.key(.enter, modifiers: .command, timestamp: 0))
        XCTAssertTrue(update.effects.isEmpty)
        XCTAssertEqual(update.state.search?.isActive, false)
        XCTAssertEqual(update.state.cursor, 4)
        XCTAssertEqual(try engine.handle(.key(.enter, modifiers: .command, timestamp: 1)).effects, [.pasteAndClose("a b a")])
    }

    func testCanceledSearchRestoresPositionAndPreviousCommittedQuery() throws {
        var engine = editor("one two one two")
        try search("one", &engine)
        let committed = engine.state
        try keys("?", &engine)
        _ = try engine.handle(.setSearchQuery("two"))
        XCTAssertNotEqual(engine.state.selection, committed.selection)
        let canceled = try engine.handle(.key(.escape, timestamp: 0))
        XCTAssertTrue(canceled.effects.isEmpty)
        XCTAssertEqual(engine.state, committed)
        try keys("n", &engine)
        XCTAssertEqual(engine.state.cursor, 0)
        XCTAssertEqual(engine.state.search?.query, "one")
        XCTAssertEqual(engine.state.search?.direction, .forward)
        var fresh = editor("abc")
        try keys("/b", &fresh)
        _ = try fresh.handle(.cancelSearch)
        XCTAssertNil(fresh.state.search)
        XCTAssertEqual(fresh.state.cursor, 0)
    }

    func testNAndNReverseAndCountWrapThroughDistinctResultsIncludingCursor() throws {
        var engine = editor("a a a")
        try search("a", &engine)
        XCTAssertEqual(engine.state.cursor, 2)
        try keys("2n", &engine)
        XCTAssertEqual(engine.state.cursor, 0)
        XCTAssertEqual(engine.state.search?.didWrap, true)
        try keys("N", &engine)
        XCTAssertEqual(engine.state.cursor, 4)
        try keys("n", &engine)
        XCTAssertEqual(engine.state.cursor, 0)
        try search("a", &engine, backward: true)
        XCTAssertEqual(engine.state.cursor, 4)
        try keys("nN", &engine)
        XCTAssertEqual(engine.state.cursor, 4)
        XCTAssertEqual(engine.state.search?.direction, .backward)
        try keys("9999n", &engine)
        XCTAssertEqual(engine.state.cursor, 4)
        var single = editor("a")
        try search("a", &single)
        XCTAssertEqual(single.state.search?.matchIndex, 1)
        XCTAssertEqual(single.state.search?.didWrap, true)
        try keys("nN", &single)
        XCTAssertEqual(single.state.cursor, 0)
    }

    func testEmptyQueryNoMatchAndRepeatWithoutPriorSearchAreHarmless() throws {
        var engine = editor("abc abc", at: 1)
        XCTAssertTrue(try keys("nN", &engine).effects.isEmpty)
        try keys("/", &engine)
        _ = try engine.handle(.acceptSearch)
        XCTAssertNil(engine.state.search)
        XCTAssertEqual(engine.state.cursor, 1)
        try search("abc", &engine)
        try keys("/", &engine)
        _ = try engine.handle(.setSearchQuery("not here"))
        XCTAssertEqual(engine.state.search?.hasNoMatch, true)
        XCTAssertEqual(engine.state.cursor, 4)
        _ = try engine.handle(.setSearchQuery(""))
        XCTAssertEqual(engine.state.search?.hasNoMatch, false)
        _ = try engine.handle(.acceptSearch)
        XCTAssertEqual(engine.state.search?.query, "abc")
        XCTAssertEqual(engine.state.cursor, 0, "Empty accept repeats the previous committed query")
        try search("missing", &engine)
        XCTAssertEqual(engine.state.search?.matchCount, 0)
        XCTAssertEqual(engine.state.search?.hasNoMatch, true)
        XCTAssertNil(engine.state.search?.match)
        try keys("nN", &engine)
        XCTAssertEqual(engine.state.cursor, 0)
    }

    func testLiteralSmartcaseUnicodeAndWholeGraphemeBounds() throws {
        for (text, query, count, cursor) in [
            ("foo FOO Foo", "foo", 3, 4),
            ("foo FOO Foo", "Foo", 1, 8),
            ("a.b axb a.b", "a.b", 2, 8),
            ("é e\u{301} É", "é", 3, 2),
            ("👩🏽‍💻 x 👩🏽‍💻", "👩🏽‍💻", 2, 4),
            ("👩🏽‍💻 x", "👩", 0, 0),
            ("e\u{301} x", "\u{301}", 0, 0),
            ("aaa", "aa", 2, 1),
        ] {
            var engine = editor(text)
            try search(query, &engine)
            XCTAssertEqual(engine.state.search?.matchCount, count, query.debugDescription)
            XCTAssertEqual(engine.state.activeCursor, cursor, query.debugDescription)
            XCTAssertEqual(engine.state.text, text)
            if let range = engine.state.search?.match {
                XCTAssertTrue((0...text.count).contains(range.lowerBound))
                XCTAssertTrue((0...text.count).contains(range.upperBound))
            }
        }
    }

    func testVisualCharacterAndLineSearchPreserveAnchorAndCancellation() throws {
        for kind in ["v", "V"] {
            var engine = editor("one\ntwo\none", at: 1)
            try keys(kind, &engine)
            let original = engine.state
            try keys("/", &engine)
            _ = try engine.handle(.setSearchQuery("one"))
            XCTAssertEqual(engine.state.activeCursor, 8)
            XCTAssertEqual(engine.state.visualAnchor, 1)
            XCTAssertEqual(engine.state.selection.range, kind == "V" ? 0..<11 : 1..<9)
            _ = try engine.handle(.cancelSearch)
            XCTAssertEqual(engine.state, original)
            try search("one", &engine)
            XCTAssertEqual(engine.state.mode, .visual)
            try keys("N", &engine)
            XCTAssertEqual(engine.state.activeCursor, 0)
            XCTAssertEqual(engine.state.selection.range, kind == "V" ? 0..<4 : 0..<2)
        }
    }

    func testSearchMetadataRecomputesAfterEditUndoRedoAndNativeInsertWithoutJumping() throws {
        var engine = editor("cat cat")
        try search("cat", &engine)
        try keys("dw", &engine)
        XCTAssertEqual(engine.state.text, "cat ")
        XCTAssertEqual(engine.state.search?.matchCount, 1)
        XCTAssertNil(engine.state.search?.match)
        try keys("u", &engine)
        XCTAssertEqual(engine.state.search?.match, 4..<7)
        XCTAssertEqual(engine.state.search?.matchCount, 2)
        _ = try engine.handle(.key(.character("r"), modifiers: .control, timestamp: 0))
        XCTAssertEqual(engine.state.search?.matchCount, 1)
        try keys("i", &engine)
        _ = try engine.handle(.nativeUpdate(text: "dog", selection: .init(anchor: 3, head: 3)))
        XCTAssertEqual(engine.state.search?.hasNoMatch, true)
        XCTAssertNil(engine.state.search?.match)
        _ = try engine.handle(.key(.escape, timestamp: 1))
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "cat ")
        XCTAssertEqual(engine.state.search?.matchCount, 1)
    }

    func testSearchFieldFallbackBackspaceAndRejectedDocumentUpdate() throws {
        var engine = editor("abc abd")
        try keys("/abc", &engine)
        XCTAssertEqual(engine.state.text, "abc abd")
        XCTAssertEqual(engine.state.search?.query, "abc")
        _ = try engine.handle(.key(.backspace, timestamp: 0))
        XCTAssertEqual(engine.state.search?.query, "ab")
        XCTAssertEqual(engine.state.search?.matchCount, 2)
        let rejected = try engine.handle(.nativeUpdate(text: "QUERY", selection: .init(anchor: 5, head: 5)))
        XCTAssertEqual(rejected.disposition, .unsupported)
        XCTAssertEqual(engine.state.text, "abc abd")
        _ = try engine.handle(.flushPendingInput)
        XCTAssertEqual(engine.state.search?.isActive, true)
        XCTAssertEqual(engine.state.search?.query, "ab")
        _ = try engine.handle(.cancelSearch)
        for event in [EditorEvent.setSearchQuery("ignored"), .acceptSearch, .cancelSearch] {
            XCTAssertTrue(try engine.handle(event).effects.isEmpty)
            XCTAssertNil(engine.state.search)
        }
    }

    func testSelectionDuringSearchCancelsPreviewThenAppliesNativeSelection() throws {
        var engine = editor("one two one")
        try search("one", &engine)
        try keys("/two", &engine)
        _ = try engine.handle(.setSelection(.init(anchor: 0, head: 3)))
        XCTAssertEqual(engine.state.mode, .visual)
        XCTAssertEqual(engine.state.search?.isActive, false)
        XCTAssertEqual(engine.state.search?.query, "one")
        XCTAssertEqual(engine.state.selection, .init(anchor: 0, head: 3))
    }

    func testSearchAtEOFAndCountedInitialSearch() throws {
        var engine = editor("x\nx\n", at: 4)
        try search("x", &engine)
        XCTAssertEqual(engine.state.cursor, 0)
        XCTAssertEqual(engine.state.search?.didWrap, true)
        try keys("2/", &engine)
        _ = try engine.handle(.setSearchQuery("x"))
        XCTAssertEqual(engine.state.cursor, 0)
        XCTAssertTrue(try engine.handle(.acceptSearch).effects.isEmpty)
        var empty = editor("")
        try search("x", &empty)
        XCTAssertEqual(empty.state.search?.hasNoMatch, true)
        XCTAssertEqual(empty.state.cursor, 0)
    }

    func testNewlineQueriesKeepExactMatchCaretAndRepeatAcrossSeparators() throws {
        for separator in ["\n", "\r", "\r\n"] {
            for visual in ["", "v", "V"] {
                var engine = editor("a" + separator + "b" + separator + "c")
                try keys(visual, &engine)
                try search(separator, &engine)
                XCTAssertEqual(engine.state.activeCursor, 1, visual)
                XCTAssertEqual(engine.state.search?.match, 1..<2)
                try keys("n", &engine)
                XCTAssertEqual(engine.state.activeCursor, 3)
                XCTAssertEqual(engine.state.search?.match, 3..<4)
                try keys("n", &engine)
                XCTAssertEqual(engine.state.activeCursor, 1)
                XCTAssertEqual(engine.state.search?.didWrap, true)
                XCTAssertEqual(engine.state.text, "a" + separator + "b" + separator + "c")
            }
        }
    }

    func testSearchDoesNotConsumeUndoRedoOrRegisterAndHistoryKeepsLatestQuery() throws {
        var engine = editor("cat dog cat dog")
        try keys("xyy", &engine)
        try search("dog", &engine)
        try keys("/cat", &engine)
        _ = try engine.handle(.cancelSearch)
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "cat dog cat dog")
        XCTAssertEqual(engine.state.search?.query, "dog")
        _ = try engine.handle(.key(.character("r"), modifiers: .control, timestamp: 0))
        XCTAssertEqual(engine.state.text, "at dog cat dog")
        XCTAssertEqual(engine.state.search?.query, "dog")
        try keys("p", &engine)
        XCTAssertEqual(engine.state.text, "at dog cat dog\nat dog cat dog")
    }

    func testLineRegisterPreservesCRLFGraphemesAndEchoKeepsTrailingAnchor() throws {
        var engine = editor("👩🏽‍💻\r\n🇺🇸\r\n", at: 4)
        try keys("Vk", &engine)
        let snapshot = engine.state
        _ = try engine.handle(.setSelection(snapshot.selection))
        XCTAssertEqual(engine.state, snapshot)
        try keys("dP", &engine)
        XCTAssertEqual(engine.state.text, "🇺🇸\r\n\r\n👩🏽‍💻")
        XCTAssertFalse(engine.state.text.contains("\n\n"))
    }

    func testSnapshotDefaultsAndModeNormalizationRemainCompatible() {
        for mode in [EditorMode.normal, .insert] {
            let state = EditorState(
                text: "abc", selection: .init(anchor: 1, head: 2), mode: mode,
                visualSelectionKind: .line, activeCursor: 99, visualAnchor: 99
            )
            XCTAssertEqual(state.visualSelectionKind, .character)
            XCTAssertEqual(state.activeCursor, 2)
            XCTAssertNil(state.visualAnchor)
            XCTAssertNil(state.search)
        }
        let line = EditorState(
            text: "aa\nbb\n", mode: .visual, visualSelectionKind: .line,
            activeCursor: -99, visualAnchor: 99
        )
        XCTAssertEqual(line.selection, .init(anchor: 6, head: 0))
        XCTAssertEqual(line.activeCursor, 0)
        XCTAssertEqual(line.visualAnchor, 6)
    }

    func testCountedVisualRepeatKeepsAnchorAndCharacterDeleteUsesMatchCell() throws {
        for visual in ["v", "V"] {
            var engine = editor("a\na\na\na")
            try keys(visual, &engine)
            try search("a", &engine)
            try keys("2n", &engine)
            XCTAssertEqual(engine.state.activeCursor, 6)
            XCTAssertEqual(engine.state.visualAnchor, 0)
            XCTAssertEqual(engine.state.selection.range, 0..<7)
            try keys("2N", &engine)
            XCTAssertEqual(engine.state.activeCursor, 2)
            XCTAssertEqual(engine.state.selection.range, visual == "V" ? 0..<4 : 0..<3)
            try keys("d", &engine)
            XCTAssertEqual(engine.state.text, visual == "V" ? "a\na" : "\na\na")
            try keys("u", &engine)
            XCTAssertEqual(engine.state.text, "a\na\na\na")
        }
    }

    func testBackspaceOnEmptySearchCancelsAndRestoresCommittedSearch() throws {
        var engine = editor("cat dog cat")
        try search("cat", &engine)
        let committed = engine.state
        try keys("?", &engine)
        let update = try engine.handle(.key(.backspace, timestamp: 0))
        XCTAssertEqual(update.state, committed)
        XCTAssertTrue(update.effects.isEmpty)
        var fresh = editor("abc")
        try keys("/x", &fresh)
        _ = try fresh.handle(.key(.backspace, timestamp: 0))
        XCTAssertEqual(fresh.state.search?.isActive, true, "Deleting the last character leaves an empty field")
        _ = try fresh.handle(.key(.backspace, timestamp: 0))
        XCTAssertNil(fresh.state.search)
        XCTAssertEqual(fresh.state.cursor, 0)
    }

    func testLinePasteDoesNotMergeIndependentCRAndLFSeparators() throws {
        for (text, command, expected) in [
            ("foo\rbar\n\nend", "yy2jP", "foo\rbar\nfoo\r\n\nend"),
            ("\nfoo\rbar", "2yyGp", "\nfoo\rbar\r\n\nfoo"),
            ("a\r\nb", "jyyP", "a\r\nb\r\nb"),
            ("a\r\n\nend", "2jyykP", "a\r\nend\n\nend"),
            ("a\rX\n\nend", "2jyykP", "a\r\r\nX\n\nend"),
        ] {
            var engine = editor(text)
            try keys(command, &engine)
            XCTAssertEqual(engine.state.text, expected, command)
            try keys("u", &engine)
            XCTAssertEqual(engine.state.text, text)
        }
    }

    func testPastingEmptyLineOverTrailingEmptyLineExitsVisualWithoutUndoStep() throws {
        var engine = editor("a\n", at: 2)
        try keys("VyVp", &engine)
        XCTAssertEqual(engine.state.text, "a\n")
        XCTAssertEqual(engine.state.mode, .normal)
        XCTAssertEqual(engine.state.visualSelectionKind, .character)
        XCTAssertNil(engine.state.visualAnchor)
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "a\n")
    }

    func testCountedLineVisualEntryRetainsTheOriginalDesiredColumn() throws {
        var engine = editor("abcd\nx\nlast", at: 3)
        try keys("2Vj", &engine)
        XCTAssertEqual(engine.state.activeCursor, 10)
        XCTAssertEqual(engine.state.visualAnchor, 3)
        XCTAssertEqual(engine.state.selection.range, 0..<11)
    }
}
