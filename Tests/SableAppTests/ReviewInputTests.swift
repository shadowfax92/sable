import AppKit
import SableCore
@testable import SableApp
import XCTest

final class ReviewKeyTranslatorTests: XCTestCase {
    /// Builds an unposted key event; nothing is sent to any window or app.
    private func event(_ keyCode: UInt16, _ characters: String, ignoring: String? = nil,
                       _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    func testSpecialKeysAndShortcuts() throws {
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(53, "\u{1b}"))?.key, .escape)
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(36, "\r", [.command])),
                       .init(key: .enter, modifiers: .command))
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(6, "z", [.command])),
                       .init(key: .character("z"), modifiers: .command))
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(6, "Z", ignoring: "Z", [.command, .shift])),
                       .init(key: .character("Z"), modifiers: [.command, .shift]))
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(15, "\u{12}", ignoring: "r", [.control])),
                       .init(key: .character("r"), modifiers: .control))
    }

    func testTypingUsesProducedCharacterAndLeavesNonSemanticKeysNative() throws {
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(38, "j"))?.key, .character("j"))
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(38, "J", [.shift])),
                       .init(key: .character("J"), modifiers: .shift))
        XCTAssertEqual(ReviewKeyTranslator.translate(try event(0, "å", ignoring: "a", [.option]))?.key,
                       .character("å"))
        XCTAssertNil(ReviewKeyTranslator.translate(try event(14, "", ignoring: "e", [.option])), "dead key")
        XCTAssertNil(ReviewKeyTranslator.translate(try event(115, "\u{F729}")), "Home")
    }
}

final class ReviewTextMathTests: XCTestCase {
    func testMinimalReplacementTouchesOnlyTheChangedSpan() throws {
        let change = try XCTUnwrap(ReviewTextMath.minimalReplacement(from: "hello world", to: "hello brave world"))
        XCTAssertEqual(change.range, NSRange(location: 6, length: 0))
        XCTAssertEqual(change.replacement, "brave ")
        XCTAssertNil(ReviewTextMath.minimalReplacement(from: "same", to: "same"))
    }

    func testReplacementRespectsGraphemesAndExactScalars() throws {
        let emoji = try XCTUnwrap(ReviewTextMath.minimalReplacement(from: "a😀b", to: "a😁b"))
        XCTAssertEqual(emoji.range, NSRange(location: 1, length: 2), "never splits a surrogate pair")
        XCTAssertEqual(emoji.replacement, "😁")

        let decomposed = try XCTUnwrap(ReviewTextMath.minimalReplacement(from: "caf\u{E9}", to: "cafe\u{301}"))
        XCTAssertEqual(decomposed.range, NSRange(location: 3, length: 1))
        XCTAssertEqual(decomposed.replacement, "e\u{301}")
    }

    func testVisualActiveCellMovesKeepAnchorCell() {
        let forward = EditorSelection(anchor: 2, head: 3) // v on cell 2
        XCTAssertEqual(ReviewTextMath.activeCell(of: forward), 2)
        XCTAssertEqual(ReviewTextMath.visualSelection(forward, movingActiveCellTo: 6), EditorSelection(anchor: 2, head: 7))
        XCTAssertEqual(ReviewTextMath.visualSelection(forward, movingActiveCellTo: 0), EditorSelection(anchor: 3, head: 0))

        let reverse = EditorSelection(anchor: 6, head: 1) // anchor cell 5, active cell 1
        XCTAssertEqual(ReviewTextMath.activeCell(of: reverse), 1)
        XCTAssertEqual(ReviewTextMath.visualSelection(reverse, movingActiveCellTo: 8), EditorSelection(anchor: 5, head: 9))
    }
}
