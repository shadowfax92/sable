import AppKit
import SableCore
import SwiftUI

/// The inline Vim command line for `/` and `?`, shown in the review footer while
/// `EditorState.search?.isActive` is true. It stays in the same key panel; there
/// is no separate window, and NSTextView's find bar stays off.
///
/// Ownership: the engine owns the query, matching and the document preview. The
/// field only owns native text entry (IME, dead keys, paste, emoji viewer,
/// dictation). It reports the complete field text as `.setSearchQuery` once
/// nothing is composing, and maps ⏎ / ⌘⏎ / esc to accept and cancel. Those events
/// go straight to the `ReviewSession`, never through the document surface, so
/// query typing can't become a document `nativeUpdate`. `ReviewEditorView`
/// re-applies the resulting snapshot (selection on the match, scrolled into view)
/// on the same SwiftUI pass.
///
/// Focus flow:
/// ```
/// `/` in document ─▶ engine: search active ─▶ field appears ─▶ makeFirstResponder(field)
///   (keys typed before the handoff reach the engine's key fallback; the field is
///    seeded from search.query at focus time, caret at the end)
/// ⏎ / ⌘⏎ / esc in field ─▶ engine: search inactive ─▶ field removed ─▶ document refocused
/// ```
/// Focus only moves inside a panel that is already key, so a search never
/// re-keys the panel or activates Sable.
struct ReviewSearchField: NSViewRepresentable {
    @ObservedObject var session: ReviewSession
    /// `OverlayModel.focusNonce`. While search is active, a key regain focuses the
    /// field rather than the document.
    var focusNonce: Int = 0

    func makeCoordinator() -> ReviewSearchFieldController {
        ReviewSearchFieldController(session: session)
    }

    func makeNSView(context: Context) -> ReviewSearchTextField {
        let field = ReviewSearchTextField.make()
        field.delegate = context.coordinator
        field.stringValue = session.state.search?.query ?? ""
        context.coordinator.focusNonce = focusNonce
        ReviewSearchFieldController.focusWhenPanelIsKey(field, session: session)
        return field
    }

    func updateNSView(_ field: ReviewSearchTextField, context: Context) {
        context.coordinator.session = session
        // While editing, the field is the source of truth for the query and the
        // engine mirrors it. Otherwise (before focus arrives) it mirrors the engine.
        if field.currentEditor() == nil, let query = session.state.search?.query,
           !ReviewTextMath.identical(field.stringValue, query) {
            field.stringValue = query
        }
        if context.coordinator.focusNonce != focusNonce {
            context.coordinator.focusNonce = focusNonce
            ReviewSearchFieldController.focusWhenPanelIsKey(field, session: session)
        }
    }
}

/// Routes the search field's editing events to the review session. Separate
/// from the view so headless tests can drive the real delegate methods with a
/// real field editor and the real engine, without a window.
@MainActor
final class ReviewSearchFieldController: NSObject, NSTextFieldDelegate {
    var session: ReviewSession
    var focusNonce: Int?

    init(session: ReviewSession) {
        self.session = session
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        sendQuery(from: editor)
    }

    /// Sends the complete field text. Nothing is sent while an input method is
    /// composing; the committing change sends the final text instead. A partial
    /// composition is not a query the user typed, and previewing it would jump
    /// the document around.
    func sendQuery(from editor: NSTextView) {
        guard !editor.hasMarkedText(), let search = session.state.search, search.isActive,
              !ReviewTextMath.identical(search.query, editor.string) else { return }
        session.send(.setSearchQuery(editor.string))
    }

    /// Key bindings the field editor would otherwise run natively. The input
    /// method sees ⏎ and esc first while composing, so these only fire for
    /// committed text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            accept(textView)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            cancel()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Vim: backspace on an empty command line leaves it.
            guard textView.string.isEmpty else { return false }
            cancel()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
             #selector(NSResponder.insertTabIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Keep focus in the field, and keep the query on a single line.
            return true
        default:
            return false
        }
    }

    /// ⏎ or ⌘⏎: commit any composition, sync the final query, then accept. This
    /// never delivers. Copy and paste-back exist only outside search.
    func accept(_ editor: NSTextView) {
        if editor.hasMarkedText() { editor.unmarkText() }
        sendQuery(from: editor)
        guard session.state.search?.isActive == true else { return }
        session.send(.acceptSearch)
        if let message = ReviewSearchPresentation.jumpMessage(session.state.search) {
            session.flashHint(message)
        }
    }

    /// esc: restores the pre-search selection and mode. The review stays open.
    func cancel() {
        guard session.state.search?.isActive == true else { return }
        session.send(.cancelSearch)
    }

    /// Makes the field first responder, but only inside a panel that is already
    /// key and only while the search is still active. It is deferred because the
    /// field has no window until SwiftUI attaches it.
    static func focusWhenPanelIsKey(_ field: ReviewSearchTextField, session: ReviewSession) {
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window, window.isKeyWindow,
                  session.state.search?.isActive == true, field.currentEditor() == nil else { return }
            field.stringValue = session.state.search?.query ?? ""
            guard window.makeFirstResponder(field), let editor = field.currentEditor() else { return }
            // NSTextField selects everything on focus. A command line keeps the caret
            // at the end, so typing continues a query that the engine's key fallback
            // already started.
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }
}

/// Borderless single-line field whose cell supplies a dedicated field editor.
final class ReviewSearchTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { ReviewSearchFieldCell.self }
        set {}
    }

    static func make() -> ReviewSearchTextField {
        let field = ReviewSearchTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = .labelColor
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search")
        return field
    }

    /// ⌘⏎ accepts the search. The document editor's own ⌘⏎ (paste-back) only
    /// claims the key while it is first responder, so it can't deliver from here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let editor = currentEditor() as? NSTextView, window?.firstResponder === editor,
              let controller = delegate as? ReviewSearchFieldController else {
            return super.performKeyEquivalent(with: event)
        }
        controller.accept(editor)
        return true
    }
}

/// Supplies the search field's own field editor instead of the panel's shared
/// one. The query is matched literally, so substitutions such as smart quotes
/// would make it differ from what was typed. A private editor also keeps those
/// settings from leaking into the picker's search field.
final class ReviewSearchFieldCell: NSTextFieldCell {
    private lazy var searchEditor = Self.makeFieldEditor()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        searchEditor
    }

    static func makeFieldEditor() -> NSTextView {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.insertionPointColor = OverlayTheme.insertCaretNS
        return editor
    }
}
