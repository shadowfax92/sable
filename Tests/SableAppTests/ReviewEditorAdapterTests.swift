import AppKit
import SableCore
@testable import SableApp
import XCTest

/// Drives the real `EditorEngine` through the adapter with a fake native surface.
/// The fake echoes selection callbacks the way NSTextView does, so these tests
/// cover the duplicate-selection and snapshot-feedback rules without windows.
@MainActor
final class ReviewEditorAdapterTests: XCTestCase {
    private var deliveries: [ReviewDelivery] = []

    private func makeEditor(_ text: String) -> (ReviewSession, ReviewEditorAdapter, FakeSurface) {
        deliveries = []
        let session = ReviewSession(
            interactionID: UUID(), text: text, target: ReviewTarget(),
            engine: EditorEngine(state: EditorState(text: text)), now: { 0 }
        ) { [unowned self] in self.deliveries.append($0) }
        let surface = FakeSurface()
        let adapter = ReviewEditorAdapter(session: session, surface: surface)
        surface.adapter = adapter
        adapter.applySnapshot()
        return (session, adapter, surface)
    }

    private func key(_ character: Character, _ modifiers: EditorModifiers = []) -> ReviewKeyTranslator.Translation {
        ReviewKeyTranslator.Translation(key: .character(character), modifiers: modifiers)
    }

    /// Mirrors ReviewTextView.keyDown: native resolution runs inside performNative.
    private func press(
        _ translation: ReviewKeyTranslator.Translation,
        at time: TimeInterval,
        _ adapter: ReviewEditorAdapter,
        _ surface: FakeSurface,
        native: (() -> Void)? = nil
    ) {
        if adapter.handleKey(translation, timestamp: time) == .native {
            adapter.performNative {
                if let native {
                    native()
                } else if case let .character(character) = translation.key {
                    surface.typeNative(String(character))
                }
            }
        }
    }

    func testSnapshotRendersTextAndNormalCaretWithoutEchoingSelection() {
        let (session, _, surface) = makeEditor("Hello")

        XCTAssertEqual(surface.text, "Hello")
        XCTAssertEqual(surface.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(surface.renderedModes.last, .normal)
        XCTAssertEqual(session.state.mode, .normal)
    }

    func testFastJKRollsBackNativeJAndEntersNormal() {
        let (session, adapter, surface) = makeEditor("ab")
        press(key("i"), at: 1.0, adapter, surface)
        XCTAssertEqual(session.state.mode, .insert)

        press(key("j"), at: 2.0, adapter, surface)
        XCTAssertEqual(surface.text, "jab", "j is inserted natively at once, never withheld")
        press(key("k"), at: 2.5, adapter, surface)

        XCTAssertEqual(session.state.mode, .normal)
        XCTAssertEqual(surface.text, "ab")
        XCTAssertEqual(session.state.text, "ab")
    }

    func testOwnersChordWindowAcceptsSlowerJJButNotPastIt() {
        let (session, adapter, surface) = makeEditor("ab")
        press(key("i"), at: 1.0, adapter, surface)
        press(key("j"), at: 2.0, adapter, surface)
        press(key("j"), at: 2.75, adapter, surface)
        XCTAssertEqual(session.state.mode, .normal, "0.75 s is inside the owner's 0.8 s timeoutlen")
        XCTAssertEqual(surface.text, "ab")

        press(key("i"), at: 3.0, adapter, surface)
        press(key("j"), at: 4.0, adapter, surface)
        press(key("k"), at: 4.9, adapter, surface)
        XCTAssertEqual(session.state.mode, .insert)
        XCTAssertEqual(surface.text, "jkab")
    }

    func testSeparateSelectionChangeDisarmsChordButNativeEditSelectionDoesNot() {
        let (session, adapter, surface) = makeEditor("ab")
        press(key("i"), at: 1.0, adapter, surface)
        press(key("j"), at: 2.0, adapter, surface)
        // A mouse click between j and k is a genuinely separate selection change.
        surface.userSelects(NSRange(location: 3, length: 0))
        press(key("k"), at: 2.1, adapter, surface)

        XCTAssertEqual(session.state.mode, .insert)
        XCTAssertEqual(surface.text, "jabk")
        XCTAssertEqual(session.state.text, "jabk")
    }

    func testNormalModeBlocksNativeMutationAndPasteWithHint() {
        let (session, adapter, surface) = makeEditor("Hello")

        XCTAssertFalse(adapter.allowsNativeTextChange)
        XCTAssertFalse(adapter.allowsNativeEdit(.paste))
        XCTAssertEqual(session.hint, ReviewEditorAdapter.pasteHint)

        XCTAssertEqual(adapter.handleKey(key("v", .command), timestamp: 1), .consumed)
        XCTAssertEqual(surface.text, "Hello")
    }

    func testInsertPasteFlushesThenReportsOneNativeUpdate() {
        let (session, adapter, surface) = makeEditor("ab")
        press(key("i"), at: 1.0, adapter, surface)
        press(key("j"), at: 2.0, adapter, surface)

        XCTAssertTrue(adapter.allowsNativeEdit(.paste))
        adapter.performNative(flushFirst: true) { surface.typeNative("PASTE") }
        // The flush disarmed the chord, so a quick k is literal text.
        press(key("k"), at: 2.1, adapter, surface)

        XCTAssertEqual(session.state.text, "jPASTEkab")
        XCTAssertEqual(session.state.mode, .insert)
    }

    func testComposingIMEBypassesEngineThenCommitsOnce() {
        let (session, adapter, surface) = makeEditor("ab")
        press(key("i"), at: 1.0, adapter, surface)

        surface.markedText = true
        XCTAssertEqual(adapter.handleKey(key("k"), timestamp: 2), .native)
        adapter.performNative { surface.typeNative("か") }
        XCTAssertEqual(session.state.text, "ab", "nothing reaches the engine while composing")

        adapter.performNative {
            surface.markedText = false
            surface.text = "かab"
            surface.selectedRange = NSRange(location: 1, length: 0)
        }
        XCTAssertEqual(session.state.text, "かab")
        XCTAssertEqual(session.state.mode, .insert)
    }

    func testNormalEnterDeliversEditedTextAndFinishes() {
        let (session, adapter, surface) = makeEditor("ab")
        press(key("x"), at: 1.0, adapter, surface)
        XCTAssertEqual(surface.text, "b")

        press(ReviewKeyTranslator.Translation(key: .enter, modifiers: []), at: 2.0, adapter, surface)

        XCTAssertEqual(deliveries.map(\.action), [.copy])
        XCTAssertEqual(deliveries.first?.text, "b")
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(adapter.handleKey(key("x"), timestamp: 3), .consumed)
    }

    func testCommandEnterFromInsertPastesFinalText() {
        let (_, adapter, surface) = makeEditor("ab")
        press(key("A"), at: 1.0, adapter, surface)
        press(key("!"), at: 2.0, adapter, surface)
        press(ReviewKeyTranslator.Translation(key: .enter, modifiers: .command), at: 3.0, adapter, surface)

        XCTAssertEqual(deliveries.map(\.action), [.paste])
        XCTAssertEqual(deliveries.first?.text, "ab!")
    }

    func testPlainJUsesDisplayLineOnlyWithoutPendingCount() {
        let (session, adapter, surface) = makeEditor("hello world\nsecond line")
        surface.displayTarget = { _, down in down ? 6 : nil }

        press(key("j"), at: 1.0, adapter, surface)
        XCTAssertEqual(session.state.cursor, 6)
        XCTAssertEqual(surface.displayQueries, 1)

        press(key("2"), at: 2.0, adapter, surface)
        XCTAssertEqual(session.state.pendingCommand, "2")
        press(key("j"), at: 2.1, adapter, surface)
        XCTAssertEqual(surface.displayQueries, 1, "a counted j stays with the engine's logical lines")
        XCTAssertEqual(session.state.pendingCommand, "")
        XCTAssertGreaterThan(session.state.cursor, 11)
    }

    func testVisualDisplayMoveKeepsAnchorCell() {
        let (session, adapter, surface) = makeEditor("abcdef")
        surface.displayTarget = { _, down in down ? 4 : nil }
        press(key("v"), at: 1.0, adapter, surface)
        XCTAssertEqual(session.state.selection, EditorSelection(anchor: 0, head: 1))

        press(key("j"), at: 2.0, adapter, surface)

        XCTAssertEqual(session.state.mode, .visual)
        XCTAssertEqual(session.state.selection, EditorSelection(anchor: 0, head: 5))
    }
}

/// In-memory stand-in for ReviewTextView that calls back into the adapter on
/// every selection change, as NSTextView's setSelectedRanges override does.
@MainActor
final class FakeSurface: ReviewTextSurface {
    weak var adapter: ReviewEditorAdapter?
    var text = ""
    var selectedRange = NSRange(location: 0, length: 0)
    var markedText = false
    var renderedModes: [EditorMode] = []
    var displayTarget: ((Int, Bool) -> Int?)?
    private(set) var displayQueries = 0

    var surfaceText: String { text }
    var surfaceSelectedRange: NSRange { selectedRange }
    var surfaceHasMarkedText: Bool { markedText }

    func surfaceReplaceCharacters(in range: NSRange, with string: String) {
        text = (text as NSString).replacingCharacters(in: range, with: string)
    }

    func surfaceSetSelectedRange(_ range: NSRange) {
        selectedRange = range
        adapter?.selectionDidChange(stillSelecting: false)
    }

    func surfaceRender(_ state: EditorState) {
        renderedModes.append(state.mode)
    }

    func surfaceDisplayLineTarget(from utf16Offset: Int, down: Bool, goalX: inout CGFloat?) -> Int? {
        displayQueries += 1
        goalX = goalX ?? 10
        return displayTarget?(utf16Offset, down)
    }

    /// Native typing: replace the selection, move the caret, echo the selection
    /// callback (which the adapter must ignore mid-transaction).
    func typeNative(_ string: String) {
        text = (text as NSString).replacingCharacters(in: selectedRange, with: string)
        selectedRange = NSRange(location: selectedRange.location + (string as NSString).length, length: 0)
        adapter?.selectionDidChange(stillSelecting: false)
    }

    func userSelects(_ range: NSRange) {
        selectedRange = range
        adapter?.selectionDidChange(stillSelecting: false)
    }
}
