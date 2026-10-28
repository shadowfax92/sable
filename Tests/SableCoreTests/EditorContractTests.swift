import XCTest
@testable import SableCore

final class EditorContractTests: XCTestCase {
    func testStateClampsToGraphemeOffsetsAndPreservesVisualDirection() {
        let text = "e\u{301}👩🏽‍💻🇺🇸"
        let state = EditorState(text: text, selection: EditorSelection(anchor: 99, head: -1), mode: .visual)

        XCTAssertEqual(text.count, 3)
        XCTAssertEqual(state.text, text)
        XCTAssertEqual(state.selection, EditorSelection(anchor: 3, head: 0))
        XCTAssertEqual(state.selection.range, 0..<3)
        XCTAssertEqual(state.cursor, 0)
    }

    func testNormalStateCollapsesSelectionAtCursor() {
        let state = EditorState(text: "Hello", selection: EditorSelection(anchor: 0, head: 4))

        XCTAssertEqual(state.mode, .normal)
        XCTAssertEqual(state.selection, EditorSelection(anchor: 4, head: 4))
        XCTAssertTrue(state.selection.isEmpty)
    }

    func testInsertStateCanRepresentNativeSelection() {
        let state = EditorState(text: "Hello", selection: EditorSelection(anchor: 1, head: 3), mode: .insert)

        XCTAssertEqual(state.selection.range, 1..<3)
    }

    func testNormalEnterDeliversCurrentDocument() throws {
        let initial = EditorState(text: "Original")
        var engine = EditorEngine(state: initial)

        XCTAssertEqual(try engine.handle(.key(.enter, timestamp: 0)).effects, [.copyAndClose("Original")])
        XCTAssertEqual(engine.state, initial)
    }
}
