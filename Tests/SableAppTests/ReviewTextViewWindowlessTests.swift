import AppKit
import SableCore
@testable import SableApp
import XCTest

/// Drives the real `ReviewTextView` (built exactly as the overlay builds it) with
/// the real adapter, session and engine, but with no window, posted keys or
/// pasteboard. Covers AppKit call ordering and TextKit geometry, which the fake
/// surface can't.
@MainActor
final class ReviewTextViewWindowlessTests: XCTestCase {
    private var deliveries: [ReviewDelivery] = []

    private func makeEditor(_ text: String) -> (ReviewSession, ReviewEditorAdapter, ReviewTextView) {
        deliveries = []
        let session = ReviewSession(
            interactionID: UUID(), text: text, target: ReviewTarget(),
            engine: EditorEngine(state: EditorState(text: text)), now: { 0 }
        ) { [unowned self] in self.deliveries.append($0) }
        let textView = ReviewEditorView.makeTextView()
        let adapter = ReviewEditorAdapter(session: session, surface: textView)
        textView.adapter = adapter
        adapter.applySnapshot()
        return (session, adapter, textView)
    }

    @discardableResult
    private func press(_ character: Character, _ modifiers: EditorModifiers = [], at time: TimeInterval,
                       _ adapter: ReviewEditorAdapter) -> ReviewEditorAdapter.KeyResolution {
        adapter.handleKey(.init(key: .character(character), modifiers: modifiers), timestamp: time)
    }

    private static let noReplacement = NSRange(location: NSNotFound, length: 0)

    func testOutOfBandEmojiInsertIsKept() {
        let (session, adapter, view) = makeEditor("hello")
        press("A", at: 1, adapter)

        view.insertText("😀", replacementRange: Self.noReplacement)

        XCTAssertEqual(view.string, "hello😀")
        XCTAssertEqual(session.state.text, "hello😀")
    }

    func testCompositionCommittedOutOfBandIsKeptAndDelivered() {
        let (session, adapter, view) = makeEditor("ab")
        press("i", at: 1, adapter)
        adapter.performNative {
            view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
        }
        XCTAssertTrue(view.hasMarkedText())

        view.unmarkText()
        XCTAssertEqual(view.string, "かab")
        XCTAssertEqual(session.state.text, "かab")

        adapter.handleKey(.init(key: .enter, modifiers: .command), timestamp: 2)
        XCTAssertEqual(deliveries.map(\.action), [.paste])
        XCTAssertEqual(deliveries.first?.text, "かab")
    }

    func testDisplayLineKFromTrailingEmptyLineMovesOneLine() {
        let (session, adapter, _) = makeEditor("line1\nline2\n")
        press("G", at: 1, adapter)
        XCTAssertEqual(session.state.cursor, 12)

        press("k", at: 2, adapter)

        XCTAssertEqual(session.state.cursor, 6, "k from the empty last line lands on line2, not line1")
    }

    func testCollapsedVisualSelectionDrawsBlockOnActiveCell() {
        let (session, adapter, view) = makeEditor("hello world")
        press("v", at: 1, adapter)
        view.setSelectedRange(NSRange(location: 7, length: 0)) // a click inside Visual

        XCTAssertEqual(session.state.mode, .visual)
        XCTAssertTrue(session.state.selection.isEmpty)
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 7, effectiveRange: nil))
    }

    func testVisualOnTrailingEmptyLineShowsBarCaret() {
        let (session, adapter, view) = makeEditor("line1\n")
        press("G", at: 1, adapter)
        press("v", at: 2, adapter)

        XCTAssertEqual(session.state.mode, .visual)
        XCTAssertNotEqual(view.insertionPointColor, NSColor.clear)
    }
}
