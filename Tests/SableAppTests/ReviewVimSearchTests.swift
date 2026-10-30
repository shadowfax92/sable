import AppKit
import SableCore
@testable import SableApp
import XCTest

/// Vim search and Visual Line through the real native stack, with no window:
/// keys run through `ReviewKeyTranslator`, then the adapter, then the real
/// `EditorEngine`, rendered into a real TextKit 1 `ReviewTextView`. Nothing
/// posts events, keys a panel or touches the general pasteboard.
@MainActor
final class ReviewVimSearchTests: XCTestCase {
    private var deliveries: [ReviewDelivery] = []
    private static let noReplacement = NSRange(location: NSNotFound, length: 0)
    /// A single logical line long enough to wrap several times at the editor width.
    private static let wrappedLine = String(repeating: "word ", count: 60) + "end"

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

    /// Mirrors `ReviewTextView.keyDown`: the translator, then the adapter, then
    /// NSTextView's own insertion only when the engine passes the key to native.
    /// Shift is set the way AppKit reports `V`, `N`, `G` and `?`.
    private func type(_ keys: String, at time: TimeInterval = 1, _ adapter: ReviewEditorAdapter, _ view: ReviewTextView) {
        for (offset, character) in keys.enumerated() {
            let shifted = character.isUppercase || character == "?"
            let translation = ReviewKeyTranslator.translate(
                keyCode: 0, characters: String(character), charactersIgnoringModifiers: String(character),
                flags: shifted ? .shift : []
            )
            if adapter.handleKey(translation, timestamp: time + Double(offset) * 0.1) == .native {
                adapter.performNative { view.insertText(String(character), replacementRange: Self.noReplacement) }
            }
        }
    }

    private func press(_ key: EditorKey, _ adapter: ReviewEditorAdapter,
                       modifiers: EditorModifiers = [], at time: TimeInterval = 5) {
        _ = adapter.handleKey(.init(key: key, modifiers: modifiers), timestamp: time)
    }

    // MARK: Search through the document key path (engine key fallback)

    func testSlashQueryKeysNeverEditDocumentAndEnterJumpsWithoutDelivery() {
        let text = "alpha beta\nbeta gamma"
        let (session, adapter, view) = makeEditor(text)

        type("/bet", adapter, view)
        XCTAssertEqual(session.state.search?.isActive, true)
        XCTAssertEqual(session.state.search?.query, "bet")
        XCTAssertEqual(view.string, text, "query keys never reach the document")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0), "the preview caret sits on the first match")

        press(.enter, adapter)
        XCTAssertEqual(session.state.search?.isActive, false)
        XCTAssertEqual(session.state.mode, .normal)
        XCTAssertEqual(session.state.activeCursor, 6)
        XCTAssertTrue(deliveries.isEmpty, "search ⏎ accepts; it never copies")
        XCTAssertFalse(session.isFinished)
        XCTAssertEqual(session.hint, "/bet  1/2")

        press(.enter, adapter, at: 6)
        XCTAssertEqual(deliveries, [ReviewDelivery(interactionID: session.interactionID, action: .copy, text: text)],
                       "outside search, ⏎ copies the whole buffer again")
    }

    func testCommandEnterDuringSearchAcceptsInsteadOfPasting() {
        let (session, adapter, view) = makeEditor("alpha beta\nbeta gamma")
        type("/gam", adapter, view)

        press(.enter, adapter, modifiers: .command)
        XCTAssertTrue(deliveries.isEmpty)
        XCTAssertEqual(session.state.search?.isActive, false)
        XCTAssertEqual(session.state.activeCursor, 16)

        press(.enter, adapter, modifiers: .command, at: 6)
        XCTAssertEqual(deliveries.map(\.action), [.paste], "outside search, ⌘⏎ delivers again")
    }

    func testEscapeCancelsPreviewWithoutArmingDiscard() {
        let (session, adapter, view) = makeEditor("alpha beta gamma")
        type("x", adapter, view) // an edited buffer, so a cancel would arm the discard guard
        type("/gam", adapter, view)
        XCTAssertEqual(session.state.activeCursor, 10)

        press(.escape, adapter)
        XCTAssertNil(session.state.search, "nothing was committed, so there is no search to report")
        XCTAssertEqual(session.state.activeCursor, 0, "the pre-search caret is restored")
        XCTAssertFalse(session.isDiscardArmed, "esc leaves search, it doesn't start a discard")
        XCTAssertTrue(deliveries.isEmpty)

        press(.escape, adapter, at: 6)
        XCTAssertTrue(session.isDiscardArmed, "the next Normal esc is the ordinary discard guard")
    }

    func testRepeatSearchMovesWrapsAndScrollsResultIntoView() throws {
        var lines = (0..<60).map { "line \($0)" }
        lines[2] = "needle early"
        lines[55] = "needle late"
        let (session, adapter, view) = makeEditor(lines.joined(separator: "\n"))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: OverlayTheme.Metric.width, height: 90))
        scrollView.documentView = view
        let layoutManager = try XCTUnwrap(view.layoutManager)
        layoutManager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        view.sizeToFit()

        /// The caret's line in document-view coordinates, and whether it is fully visible.
        func caretLineIsVisible() -> Bool {
            let glyph = layoutManager.glyphIndexForCharacter(at: view.selectedRange().location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            return scrollView.contentView.bounds.contains(NSRect(x: 0, y: line.minY, width: 1, height: line.height))
        }

        type("/needle", adapter, view)
        press(.enter, adapter)
        let early = session.state.activeCursor
        XCTAssertEqual(session.hint, "/needle  1/2")
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 1)

        type("n", at: 6, adapter, view)
        XCTAssertGreaterThan(session.state.activeCursor, early)
        XCTAssertEqual(session.hint, "/needle  2/2")
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 500, "line 55 is far below the 90 pt viewport")
        XCTAssertTrue(caretLineIsVisible(), "n scrolls the result into view")

        type("n", at: 7, adapter, view)
        XCTAssertEqual(session.state.activeCursor, early)
        XCTAssertEqual(session.hint, "/needle  1/2 wrapped")
        XCTAssertTrue(caretLineIsVisible(), "wrapping scrolls back up to the first match")

        type("N", at: 8, adapter, view)
        XCTAssertEqual(session.hint, "/needle  2/2 wrapped", "N reverses and wraps back to the last match")
    }

    /// A 60-line review in a 90 pt viewport, laid out so scrolling is real.
    private func makeScrollingEditor(needleLines: [Int]) throws
        -> (ReviewSession, ReviewEditorAdapter, ReviewTextView, NSScrollView, () -> Bool) {
        var lines = (0..<60).map { "line \($0)" }
        for index in needleLines { lines[index] = "needle \(index)" }
        let (session, adapter, view) = makeEditor(lines.joined(separator: "\n"))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: OverlayTheme.Metric.width, height: 90))
        scrollView.documentView = view
        let layoutManager = try XCTUnwrap(view.layoutManager)
        layoutManager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        view.sizeToFit()
        let caretLineIsVisible = {
            let glyph = layoutManager.glyphIndexForCharacter(at: view.selectedRange().location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            return scrollView.contentView.bounds.contains(NSRect(x: 0, y: line.minY, width: 1, height: line.height))
        }
        return (session, adapter, view, scrollView, caretLineIsVisible)
    }

    /// The user scrolls the review with the wheel; NSTextView keeps its caret.
    private func scrollAway(_ scrollView: NSScrollView, to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    }

    // F1 (vetted review): a jump that lands on the range already selected, such
    // as a sole match wrapping to itself, must still reveal it after a manual scroll.
    func testSoleMatchRepeatRevealsResultEvenWhenRangeIsUnchanged() throws {
        let (session, adapter, view, scrollView, caretLineIsVisible) = try makeScrollingEditor(needleLines: [55])
        type("/needle", adapter, view)
        press(.enter, adapter)
        let match = session.state.activeCursor
        XCTAssertTrue(caretLineIsVisible())

        scrollAway(scrollView, to: 0)
        XCTAssertFalse(caretLineIsVisible())
        type("n", at: 6, adapter, view)
        XCTAssertEqual(session.state.activeCursor, match, "a sole match wraps to itself")
        XCTAssertEqual(session.hint, "/needle  1/1 wrapped")
        XCTAssertTrue(caretLineIsVisible(), "n reveals the match even though the selection didn't change")

        scrollAway(scrollView, to: 0)
        type("N", at: 7, adapter, view)
        XCTAssertEqual(session.state.activeCursor, match)
        XCTAssertTrue(caretLineIsVisible(), "N reveals it in reverse too")
        XCTAssertTrue(deliveries.isEmpty)
    }

    func testCountedFullCycleRevealsResultEvenWhenRangeIsUnchanged() throws {
        let (session, adapter, view, scrollView, caretLineIsVisible) = try makeScrollingEditor(needleLines: [2, 55])
        type("/needle", adapter, view)
        press(.enter, adapter)
        type("n", at: 6, adapter, view)
        let late = session.state.activeCursor
        XCTAssertEqual(session.hint, "/needle  2/2")

        scrollAway(scrollView, to: 0)
        XCTAssertFalse(caretLineIsVisible())
        type("2n", at: 7, adapter, view)
        XCTAssertEqual(session.state.activeCursor, late, "2n over two matches comes back to the same one")
        XCTAssertTrue(caretLineIsVisible())
    }

    func testFieldAcceptRevealsResultAfterManualScroll() throws {
        let (session, adapter, view, scrollView, caretLineIsVisible) = try makeScrollingEditor(needleLines: [55])
        type("/", adapter, view)
        let controller = ReviewSearchFieldController(session: session)
        let editor = ReviewSearchFieldCell.makeFieldEditor()
        editor.string = "needle"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification, object: ReviewSearchTextField.make(),
            userInfo: ["NSFieldEditor": editor]
        ))
        adapter.applySnapshot() // ReviewEditorView.updateNSView on the SwiftUI pass
        XCTAssertTrue(caretLineIsVisible(), "the preview itself scrolls to the match")

        scrollAway(scrollView, to: 0)
        controller.accept(editor)
        adapter.applySnapshot()
        XCTAssertEqual(session.state.search?.isActive, false)
        XCTAssertTrue(caretLineIsVisible(), "⏎ in the field reveals the accepted match")
        XCTAssertTrue(deliveries.isEmpty)
    }

    func testUnrelatedSnapshotRefreshKeepsTheUsersScroll() throws {
        let (session, adapter, view, scrollView, _) = try makeScrollingEditor(needleLines: [55])
        type("/needle", adapter, view)
        press(.enter, adapter)

        scrollAway(scrollView, to: 0)
        adapter.applySnapshot() // an ordinary SwiftUI refresh
        session.send(.flushPendingInput)
        adapter.applySnapshot()
        type("x", at: 6, adapter, view) // an edit at the cursor is not a search jump
        adapter.applySnapshot()
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 0.5,
                       "only an explicit search jump overrides the user's scroll")
    }

    func testRepeatWithoutCommittedSearchExplainsInsteadOfUnsupported() {
        let (session, adapter, view) = makeEditor("abc")
        type("n", adapter, view)
        XCTAssertEqual(session.hint, ReviewSearchPresentation.noPreviousSearch)
        XCTAssertEqual(session.state.activeCursor, 0)
    }

    func testActiveSearchSendsJKToTheQueryNotDisplayLines() {
        let text = Self.wrappedLine + "\nsecond"
        let (session, adapter, view) = makeEditor(text)
        type("/", adapter, view)
        type("jk", at: 2, adapter, view)

        XCTAssertEqual(session.state.search?.query, "jk")
        XCTAssertEqual(session.state.search?.hasNoMatch, true)
        XCTAssertEqual(session.state.activeCursor, 0, "no match keeps the opening caret")
        XCTAssertEqual(view.string, text)
    }

    func testClickInDocumentDuringSearchCancelsPreviewThenPlacesCursor() {
        let (session, adapter, view) = makeEditor("alpha beta gamma")
        type("/gam", adapter, view)

        view.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertNil(session.state.search, "the uncommitted preview is abandoned, as with esc")
        XCTAssertEqual(session.state.mode, .normal)
        XCTAssertEqual(session.state.activeCursor, 2)
        XCTAssertEqual(view.string, "alpha beta gamma")
    }

    func testSearchPreviewMarksCurrentMatchOnlyWhileActive() throws {
        let (_, adapter, view) = makeEditor("alpha beta\nbeta gamma")
        let layoutManager = try XCTUnwrap(view.layoutManager)
        type("/bet", adapter, view)
        XCTAssertNotNil(layoutManager.temporaryAttribute(.underlineStyle, atCharacterIndex: 8, effectiveRange: nil))
        XCTAssertNil(layoutManager.temporaryAttribute(.underlineStyle, atCharacterIndex: 11, effectiveRange: nil),
                     "only the current match is marked")

        press(.enter, adapter)
        XCTAssertNil(layoutManager.temporaryAttribute(.underlineStyle, atCharacterIndex: 8, effectiveRange: nil))
    }

    func testInsertChordAndIMEStillWorkAfterASearch() {
        let (session, adapter, view) = makeEditor("ab cd")
        type("/cd", adapter, view)
        press(.enter, adapter)

        type("i", at: 10, adapter, view)
        type("jk", at: 11, adapter, view)
        XCTAssertEqual(session.state.mode, .normal, "jk inside 0.8 s still leaves Insert")
        XCTAssertEqual(view.string, "ab cd")

        type("i", at: 20, adapter, view)
        adapter.performNative {
            view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
        }
        view.unmarkText()
        XCTAssertEqual(session.state.text, view.string)
        XCTAssertTrue(view.string.contains("か"))
    }

    // MARK: Visual Line

    func testVisualLineUsesLogicalLinesWhereNormalJUsesDisplayLines() {
        let text = Self.wrappedLine + "\nsecond\nthird"
        let (session, adapter, view) = makeEditor(text)

        type("j", adapter, view)
        XCTAssertGreaterThan(session.state.activeCursor, 0)
        XCTAssertLessThan(session.state.activeCursor, Self.wrappedLine.count, "plain Normal j moves one wrapped display line")

        type("ggVj", at: 2, adapter, view)
        XCTAssertEqual(session.state.visualSelectionKind, .line)
        XCTAssertEqual(ModePill.label(for: session.state), "VISUAL LINE")
        let secondEnd = Self.wrappedLine.count + "\nsecond\n".count
        XCTAssertEqual(session.state.selection, EditorSelection(anchor: 0, head: secondEnd),
                       "Visual Line j extends by a whole logical line, not a display line")

        type("d", at: 3, adapter, view)
        XCTAssertEqual(view.string, "third")
        XCTAssertEqual(session.state.mode, .normal)

        type("u", at: 4, adapter, view)
        XCTAssertEqual(view.string, text)
    }

    func testVisualLineBandCoversWrappedBlankAndTrailingEmptyLines() throws {
        let text = Self.wrappedLine + "\n\nlast\n"
        let (session, adapter, view) = makeEditor(text)
        type("VG", adapter, view)
        XCTAssertEqual(session.state.activeCursor, text.count, "the active cell is the empty line after the final newline")

        let rects = view.lineBandRects()
        let layoutManager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        XCTAssertGreaterThanOrEqual(rects.count, 5, "≥2 wrapped fragments + blank + last + trailing empty line")
        for rect in rects {
            XCTAssertEqual(rect.width, container.size.width, "every band is full width, even on short lines")
        }
        for (upper, lower) in zip(rects, rects.dropFirst()) {
            XCTAssertEqual(lower.minY, upper.maxY, accuracy: 0.5, "no line inside the selection is skipped")
        }
        XCTAssertEqual(rects.last?.minY ?? -1, layoutManager.extraLineFragmentRect.minY + view.textContainerOrigin.y,
                       accuracy: 0.5)
        XCTAssertEqual(view.selectedTextAttributes[.backgroundColor] as? NSColor, NSColor.clear,
                       "the band replaces the native highlight so alpha never doubles")

        press(.escape, adapter)
        XCTAssertTrue(view.lineBandRects().isEmpty)
        XCTAssertEqual(view.selectedTextAttributes[.backgroundColor] as? NSColor, OverlayTheme.selectionNS)
    }

    func testVisualLineCaretSitsOnEngineActiveCellNotTheSelectionEdge() throws {
        let (session, adapter, view) = makeEditor("abc\ndef\n")
        type("jlV", adapter, view)
        XCTAssertEqual(session.state.selection, EditorSelection(anchor: 4, head: 8))
        XCTAssertEqual(session.state.activeCursor, 5)

        let layoutManager = try XCTUnwrap(view.layoutManager)
        XCTAssertNotNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil))
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 4, effectiveRange: nil))
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 6, effectiveRange: nil))
    }

    func testCharacterVisualStillMovesByDisplayLine() {
        let (session, adapter, view) = makeEditor(Self.wrappedLine + "\nsecond")
        type("vj", adapter, view)
        XCTAssertEqual(session.state.visualSelectionKind, .character)
        XCTAssertLessThan(session.state.activeCursor, Self.wrappedLine.count)
        XCTAssertEqual(session.state.visualAnchor, 0)
    }
}

/// The footer's search field, driven through its real `NSTextFieldDelegate`
/// methods with its real dedicated field editor. Without a window AppKit
/// can't route events to it, so the tests invoke the same callbacks AppKit would.
@MainActor
final class ReviewSearchFieldTests: XCTestCase {
    private var deliveries: [ReviewDelivery] = []
    private let field = ReviewSearchTextField.make()

    private func makeSearching(_ text: String) -> (ReviewSession, ReviewSearchFieldController, NSTextView) {
        deliveries = []
        let session = ReviewSession(
            interactionID: UUID(), text: text, target: ReviewTarget(),
            engine: EditorEngine(state: EditorState(text: text)), now: { 0 }
        ) { [unowned self] in self.deliveries.append($0) }
        session.send(.key(.character("/"), timestamp: 1))
        let controller = ReviewSearchFieldController(session: session)
        let editor = ReviewSearchFieldCell.makeFieldEditor()
        return (session, controller, editor)
    }

    private func didChange(_ controller: ReviewSearchFieldController, _ editor: NSTextView) {
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification, object: field, userInfo: ["NSFieldEditor": editor]
        ))
    }

    private func command(_ selector: Selector, _ controller: ReviewSearchFieldController, _ editor: NSTextView) -> Bool {
        controller.control(field, textView: editor, doCommandBy: selector)
    }

    func testDedicatedFieldEditorKeepsQueryLiteral() {
        let editor = ReviewSearchFieldCell().fieldEditor(for: field)
        XCTAssertEqual(editor?.isFieldEditor, true)
        XCTAssertEqual(editor?.isAutomaticQuoteSubstitutionEnabled, false)
        XCTAssertEqual(editor?.isAutomaticTextReplacementEnabled, false)
        XCTAssertEqual(editor?.isAutomaticSpellingCorrectionEnabled, false)
        XCTAssertTrue(field.cell is ReviewSearchFieldCell, "the field uses its own editor, not the panel's shared one")
    }

    func testCompositionIsNotPreviewedUntilCommitted() {
        let (session, controller, editor) = makeSearching("かな and かき")
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        didChange(controller, editor)
        XCTAssertEqual(session.state.search?.query, "", "marked text is not a query yet")
        XCTAssertEqual(session.state.activeCursor, 0)

        editor.unmarkText()
        didChange(controller, editor)
        XCTAssertEqual(session.state.search?.query, "か")
        XCTAssertEqual(session.state.search?.matchCount, 2)
        XCTAssertEqual(session.state.text, "かな and かき", "the query never edits the document")
    }

    func testPasteSendsTheCompleteFieldText() throws {
        let (session, controller, editor) = makeSearching("one two three")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sable-search-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("two th", forType: .string)
        editor.string = "x"
        editor.setSelectedRange(NSRange(location: 0, length: 1))

        XCTAssertTrue(editor.readSelection(from: pasteboard))
        didChange(controller, editor)

        XCTAssertEqual(session.state.search?.query, "two th", "one full replacement, not per-character edits")
        XCTAssertEqual(session.state.activeCursor, 4)
        XCTAssertEqual(session.state.text, "one two three")
    }

    func testReturnAcceptsWithoutDeliveringAndFlashesResult() {
        let (session, controller, editor) = makeSearching("one two three two")
        editor.string = "two"
        didChange(controller, editor)

        XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:)), controller, editor))
        XCTAssertEqual(session.state.search?.isActive, false)
        XCTAssertEqual(session.state.activeCursor, 4)
        XCTAssertTrue(deliveries.isEmpty)
        XCTAssertFalse(session.isFinished)
        XCTAssertEqual(session.hint, "/two  1/2")
    }

    func testCommandReturnCommitsCompositionThenAccepts() {
        let (session, controller, editor) = makeSearching("ab かな")
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        controller.accept(editor) // what ⌘⏎ in the field calls

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(session.state.search?.isActive, false)
        XCTAssertEqual(session.state.search?.query, "か")
        XCTAssertEqual(session.state.activeCursor, 3)
        XCTAssertTrue(deliveries.isEmpty)
    }

    func testEscapeAndBackspaceOnEmptyCancelWithoutDiscarding() {
        let (session, controller, editor) = makeSearching("one two")
        editor.string = "two"
        didChange(controller, editor)
        XCTAssertEqual(session.state.activeCursor, 4)

        XCTAssertTrue(command(#selector(NSResponder.cancelOperation(_:)), controller, editor))
        XCTAssertNil(session.state.search)
        XCTAssertEqual(session.state.activeCursor, 0)
        XCTAssertTrue(deliveries.isEmpty)
        XCTAssertFalse(session.isDiscardArmed)

        session.send(.key(.character("/"), timestamp: 2))
        editor.string = "t"
        XCTAssertFalse(command(#selector(NSResponder.deleteBackward(_:)), controller, editor),
                       "a nonempty query deletes natively")
        editor.string = ""
        XCTAssertTrue(command(#selector(NSResponder.deleteBackward(_:)), controller, editor))
        XCTAssertNil(session.state.search, "backspace on an empty command line leaves it")
    }

    func testTabAndLineBreaksStayInTheSingleLineField() {
        let (session, controller, editor) = makeSearching("one")
        for selector in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
                         #selector(NSResponder.insertLineBreak(_:)),
                         #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))] {
            XCTAssertTrue(command(selector, controller, editor))
        }
        XCTAssertEqual(session.state.search?.isActive, true)
        XCTAssertFalse(command(#selector(NSResponder.moveLeft(_:)), controller, editor), "editing keys stay native")
    }
}

/// Footer text derived from engine search state.
@MainActor
final class ReviewSearchPresentationTests: XCTestCase {
    func testStatusAndHintsFollowEngineResult() {
        let found = EditorSearchState(isActive: true, query: "two", direction: .forward,
                                      match: 4..<7, matchIndex: 2, matchCount: 3, didWrap: true)
        XCTAssertEqual(ReviewSearchPresentation.status(found)?.text, "2/3 wrapped")
        XCTAssertEqual(OverlayHints.search(found, isPanelKey: true).map(\.cap), ["⏎", "esc"])

        let missing = EditorSearchState(isActive: true, query: "zzz", direction: .backward)
        XCTAssertEqual(ReviewSearchPresentation.prompt(missing), "?")
        XCTAssertEqual(ReviewSearchPresentation.status(missing)?.isWarning, true)
        XCTAssertEqual(ReviewSearchPresentation.jumpMessage(missing), "not found: zzz")
        XCTAssertEqual(OverlayHints.search(missing, isPanelKey: true).map(\.cap), ["esc"], "no ⏎ jump without a match")

        let empty = EditorSearchState(isActive: true, query: "", direction: .forward)
        XCTAssertNil(ReviewSearchPresentation.status(empty))
        XCTAssertEqual(OverlayHints.search(empty, isPanelKey: false), [OverlayHint(text: "click to review")])
    }

    func testModeLabelNamesVisualLine() {
        XCTAssertEqual(ModePill.label(for: EditorState(text: "a\nb", selection: .init(anchor: 0, head: 2),
                                                       mode: .visual, visualSelectionKind: .line)), "VISUAL LINE")
        XCTAssertEqual(ModePill.label(for: EditorState(text: "ab", selection: .init(anchor: 0, head: 1),
                                                       mode: .visual)), "VISUAL")
    }
}
