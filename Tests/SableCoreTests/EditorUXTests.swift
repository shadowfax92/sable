import XCTest
@testable import SableCore

/// Exercises the snapshot contract used by the native adapter to distinguish
/// plain display-line movement from an unfinished logical-line Vim command.
final class EditorUXTests: XCTestCase {
    private func editor(_ text: String = "zero\none\ntwo\nthree", mode: EditorMode = .normal) -> EditorEngine {
        EditorEngine(state: EditorState(text: text, mode: mode))
    }

    @discardableResult
    private func keys(_ input: String, _ engine: inout EditorEngine) throws -> EditorUpdate {
        var update = EditorUpdate(state: engine.state, disposition: .handled)
        for key in input {
            update = try engine.handle(.key(.character(key), timestamp: 0))
            XCTAssertEqual(update.state, engine.state)
        }
        return update
    }

    func testPendingCommandDefaultsAndShowsCountsOperatorsAndPrefixes() throws {
        XCTAssertEqual(EditorState(text: "").pendingCommand, "")
        for command in ["2", "23", "d", "2d", "d3", "2d3g", "ci", "di", "g", "3g"] {
            var engine = editor()
            for (offset, key) in command.enumerated() {
                let update = try engine.handle(.key(.character(key), timestamp: 0))
                XCTAssertEqual(update.state.pendingCommand, String(command.prefix(offset + 1)), command)
                XCTAssertEqual(engine.state.pendingCommand, update.state.pendingCommand)
                XCTAssertTrue(update.effects.isEmpty)
                XCTAssertEqual(update.state.text, "zero\none\ntwo\nthree")
            }
        }
        // A snapshot can carry metadata for a UI mock, but engine construction
        // starts a fresh parser rather than reviving a partially typed command.
        let snapshot = EditorState(text: "abc", pendingCommand: "d")
        XCTAssertEqual(snapshot.pendingCommand, "d")
        for mode in [EditorMode.normal, .visual, .insert] {
            let fresh = EditorEngine(state: EditorState(text: "abc", mode: mode, pendingCommand: "d"))
            XCTAssertEqual(fresh.state.pendingCommand, "")
        }
    }

    func testCompletedCommandsClearMetadataAndRetainLogicalLineCounts() throws {
        for command in ["2j", "2dd", "dw", "ciw", "gg", "2gg", "d2j"] {
            var engine = editor()
            try keys(command, &engine)
            XCTAssertEqual(engine.state.pendingCommand, "", command)
        }
        var engine = editor()
        try keys("3", &engine)
        XCTAssertEqual(engine.state.pendingCommand, "3")
        try keys("j", &engine)
        XCTAssertEqual(engine.state.cursor, 13)
        engine = editor()
        try keys("2dj", &engine)
        XCTAssertEqual(engine.state.text, "three")
        XCTAssertEqual(engine.state.pendingCommand, "")
    }

    func testEscapeClearsPendingBeforeASecondCleanEscapeCancels() throws {
        for command in ["2", "d", "2d3", "ci", "g", "d2g"] {
            var engine = editor()
            try keys(command, &engine)
            let before = engine.state
            let cleared = try engine.handle(.key(.escape, timestamp: 1))
            XCTAssertTrue(cleared.effects.isEmpty, command)
            XCTAssertEqual(cleared.disposition, .handled)
            XCTAssertEqual(cleared.state.pendingCommand, "")
            XCTAssertEqual(cleared.state.mode, .normal)
            XCTAssertEqual(cleared.state.text, before.text)
            XCTAssertEqual(cleared.state.selection, before.selection)
            XCTAssertEqual(try engine.handle(.key(.escape, timestamp: 2)).effects, [.cancel])
        }
        for mode in [EditorMode.insert, .visual] {
            var engine = editor(mode: mode)
            if mode == .visual { try keys("2", &engine) }
            XCTAssertTrue(try engine.handle(.key(.escape, timestamp: 0)).effects.isEmpty)
            XCTAssertEqual(engine.state.mode, .normal)
            XCTAssertEqual(engine.state.pendingCommand, "")
        }
    }

    func testMetadataClearsAcrossRejectedSequencesFlushSelectionAndHistory() throws {
        for command in ["d?", "g?", "ci?", "2!", "dgx"] {
            var engine = editor()
            XCTAssertEqual(try keys(command, &engine).disposition, .unsupported)
            XCTAssertEqual(engine.state.pendingCommand, "")
        }
        for event in [
            EditorEvent.flushPendingInput,
            .setSelection(.init(anchor: 0, head: 2)),
            .nativeUpdate(text: "ignored", selection: .init(anchor: 0, head: 0)),
        ] {
            var engine = editor()
            try keys("2d", &engine)
            XCTAssertFalse(engine.state.pendingCommand.isEmpty)
            let update = try engine.handle(event)
            XCTAssertEqual(update.state.pendingCommand, "")
            XCTAssertEqual(update.state, engine.state)
            XCTAssertEqual(update.state.text, "zero\none\ntwo\nthree")
        }
        var engine = editor("abc")
        try keys("xd", &engine)
        XCTAssertEqual(engine.state.pendingCommand, "d")
        _ = try engine.handle(.key(.character("z"), modifiers: .command, timestamp: 1))
        XCTAssertEqual(engine.state.text, "abc")
        XCTAssertEqual(engine.state.pendingCommand, "")
        _ = try engine.handle(.key(.character("r"), modifiers: .control, timestamp: 2))
        XCTAssertEqual(engine.state.text, "bc")
        XCTAssertEqual(engine.state.pendingCommand, "")
        try keys("ciw", &engine)
        _ = try engine.handle(.nativeUpdate(text: "new", selection: .init(anchor: 3, head: 3)))
        XCTAssertEqual(engine.state.pendingCommand, "")
        _ = try engine.handle(.key(.escape, timestamp: 3))
        try keys("u", &engine)
        XCTAssertEqual(engine.state.text, "bc")
        XCTAssertEqual(engine.state.pendingCommand, "")
    }

    func testEnterCopiesWholeBufferInNormalAndDirectedVisualSelection() throws {
        let text = "e\u{301}👩🏽‍💻\nwhole buffer"
        for selection in [EditorSelection(anchor: 0, head: 2), .init(anchor: 2, head: 0)] {
            var engine = editor(text)
            _ = try engine.handle(.setSelection(selection))
            try keys("2", &engine)
            let update = try engine.handle(.key(.enter, timestamp: 0))
            XCTAssertEqual(update.effects, [.copyAndClose(text)])
            XCTAssertEqual(update.disposition, .handled)
            XCTAssertEqual(update.state.pendingCommand, "")
            XCTAssertEqual(update.state.selection, selection)
            XCTAssertEqual(update.state.text, text)
            XCTAssertEqual(try engine.handle(.key(.enter, modifiers: .command, timestamp: 1)).effects, [.pasteAndClose(text)])
        }
        var normal = editor(text)
        XCTAssertEqual(try normal.handle(.key(.enter, timestamp: 0)).effects, [.copyAndClose(text)])
        var insert = editor(text, mode: .insert)
        let update = try insert.handle(.key(.enter, timestamp: 0))
        XCTAssertEqual(update.disposition, .passToNative)
        XCTAssertTrue(update.effects.isEmpty)
    }

    func testChordWindowMatchesVerifiedTimeoutAndFlushStillPreservesJ() throws {
        XCTAssertEqual(EditorEngine.insertChordTimeout, 0.8)
        for second: Character in ["j", "k"] {
            for elapsed in [0.5, 0.79, 0.8, 0.81] {
                var engine = editor("", mode: .insert)
                XCTAssertEqual(try engine.handle(.key(.character("j"), timestamp: 0)).disposition, .passToNative)
                _ = try engine.handle(.nativeUpdate(text: "j", selection: .init(anchor: 1, head: 1)))
                XCTAssertEqual(engine.state.pendingCommand, "", "Native chord candidate is not a modal command")
                let update = try engine.handle(.key(.character(second), timestamp: elapsed))
                XCTAssertEqual(update.disposition, elapsed <= 0.8 ? .handled : .passToNative)
                XCTAssertEqual(update.state.text, elapsed <= 0.8 ? "" : "j")
                XCTAssertEqual(update.state.mode, elapsed <= 0.8 ? .normal : .insert)
            }
        }
        var engine = editor("", mode: .insert)
        _ = try engine.handle(.key(.character("j"), timestamp: 0))
        _ = try engine.handle(.nativeUpdate(text: "j", selection: .init(anchor: 1, head: 1)))
        _ = try engine.handle(.flushPendingInput)
        XCTAssertEqual(try engine.handle(.key(.character("k"), timestamp: 0.5)).disposition, .passToNative)
        XCTAssertEqual(engine.state.text, "j")
    }

    func testYankRemainsLocalAndInsertURemainsNative() throws {
        var engine = editor("abc")
        XCTAssertTrue(try keys("yy", &engine).effects.isEmpty)
        XCTAssertTrue(try keys("p", &engine).effects.isEmpty)
        XCTAssertEqual(engine.state.text, "abc\nabc")
        try keys("vl", &engine)
        XCTAssertTrue(try keys("y", &engine).effects.isEmpty)
        try keys("i", &engine)
        let update = try keys("u", &engine)
        XCTAssertEqual(update.disposition, .passToNative)
        XCTAssertTrue(update.effects.isEmpty)
        XCTAssertEqual(update.state.text, "abc\nabc")
        XCTAssertEqual(update.state.mode, .insert)
        XCTAssertEqual(try engine.handle(.key(.character("r"), modifiers: .control, timestamp: 0)).disposition, .passToNative)
    }
}
