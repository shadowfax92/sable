import AppKit
import SableCore

/// The native text surface the review adapter drives. `ReviewTextView` is the
/// real implementation; headless tests use a fake, so the event protocol with the
/// engine can be verified without windows or key posting.
@MainActor
protocol ReviewTextSurface: AnyObject {
    var surfaceText: String { get }
    /// UTF-16 selection, as NSTextView reports it.
    var surfaceSelectedRange: NSRange { get }
    /// True while an input method is composing (marked text is showing).
    var surfaceHasMarkedText: Bool { get }
    func surfaceReplaceCharacters(in range: NSRange, with string: String)
    /// Selects and scrolls the range into view.
    func surfaceSetSelectedRange(_ range: NSRange)
    /// Scrolls the current selection into view without changing it.
    func surfaceRevealSelection()
    /// Updates caret style and other mode visuals after a snapshot is applied.
    func surfaceRender(_ state: EditorState)
    /// UTF-16 index one display (wrapped) line below or above `utf16Offset`, at
    /// `goalX` (set on first use and kept across consecutive moves). Returns nil
    /// when there is no other display line, or no layout is available.
    func surfaceDisplayLineTarget(from utf16Offset: Int, down: Bool, goalX: inout CGFloat?) -> Int?
}

/// Bridges AppKit text input and the editor engine for one review session,
/// following the contract in fast-rewrite/editor-report.md.
///
/// The engine is authoritative. Each AppKit event becomes exactly one of:
/// - a `.key` the engine handles (the adapter then renders the snapshot),
/// - a native transaction NSTextView performs, reported as ONE `.nativeUpdate`
///   in Insert mode (or a `.setSelection` elsewhere), or
/// - a separate selection change (mouse, ⌘A), reported as `.setSelection`.
///
/// Invariants that keep jk/jj and IME working:
/// - No `setSelection` is sent for a native edit's own selection change. It
///   travels inside the edit's `.nativeUpdate`; a second report would disarm the
///   chord.
/// - Selection callbacks are suppressed while a snapshot is applied, so there
///   is no feedback loop.
/// - `flushPendingInput` is sent before IME composition, paste/cut/drop and on
///   blur. Nothing reaches the engine while marked text is showing.
/// - Normal/Visual never let NSTextView mutate text (`allowsNativeTextChange`).
///
/// Vim search (permissions-vim/editor-ui-contracts.md): the query is typed into
/// the footer's `ReviewSearchField`, which talks to the session directly and
/// never reports to this document surface. While a search is active, every key
/// that still reaches the document (typed before the field took focus) goes to
/// the engine's key fallback, and a document selection change first cancels
/// the preview. The engine never sees `.setSelection` during an active search.
@MainActor
final class ReviewEditorAdapter {
    enum KeyResolution: Equatable {
        /// The key was fully handled; don't pass it to NSTextView.
        case consumed
        /// Run NSTextView's own handling inside `performNative`.
        case native
    }

    enum NativeEditKind { case paste, cut, drop }

    static let pasteHint = "i, then ⌘V to paste"
    static let cutHint = "d deletes; i, then ⌘X cuts"

    let session: ReviewSession
    private(set) weak var surface: ReviewTextSurface?
    private(set) var isApplyingSnapshot = false
    private var nativeDepth = 0
    private var displayGoalX: CGFloat?
    /// The last `session.revealRequest` this adapter honored.
    private var revealedRequest: Int

    init(session: ReviewSession, surface: ReviewTextSurface) {
        self.session = session
        self.surface = surface
        self.revealedRequest = session.revealRequest
    }

    /// Native text mutation is only legal in Insert mode. In Normal/Visual every
    /// edit must come from the engine, so a ⌘⌫ or a services insertion can't
    /// bypass it.
    var allowsNativeTextChange: Bool {
        isApplyingSnapshot || (session.state.mode == .insert && !session.isFinished)
    }

    // MARK: Keys

    func handleKey(_ translation: ReviewKeyTranslator.Translation?, timestamp: TimeInterval) -> KeyResolution {
        guard let surface else { return .native }
        if session.isFinished { return .consumed }
        // The input method owns every key while it is composing.
        if surface.surfaceHasMarkedText { return .native }
        guard let translation else {
            displayGoalX = nil
            return .native
        }
        if moveByDisplayLine(translation) { return .consumed }
        displayGoalX = nil

        let before = session.state
        let disposition = session.send(.key(translation.key, modifiers: translation.modifiers, timestamp: timestamp))
        let searchFeedback = ReviewSearchPresentation.feedback(
            afterKey: translation.key, modifiers: translation.modifiers, before: before, after: session.state
        )
        if searchFeedback != nil, session.state.search?.matchIndex != nil {
            session.requestSelectionReveal()
        }
        switch disposition {
        case .passToNative?:
            if session.state.mode != .insert, translation.modifiers == .command,
               case let .character(character) = translation.key, character == "v" || character == "x" {
                session.flashHint(character == "v" ? Self.pasteHint : Self.cutHint)
                return .consumed
            }
            return .native
        case .unsupported?:
            applySnapshot()
            session.flashHint(searchFeedback ?? Self.unsupportedHint(translation))
            return .consumed
        case .handled?, nil:
            applySnapshot()
            if let searchFeedback { session.flashHint(searchFeedback) }
            return .consumed
        }
    }

    /// Whether plain j/k (and ↓/↑) may move by wrapped display line, matching the
    /// owner's LazyVim `gj`/`gk` with `wrap`. Engine semantics must win whenever
    /// a display line would change the meaning:
    /// - a pending count or operator (`3j`, `dj`) uses logical lines,
    /// - Visual Line extends by whole logical lines,
    /// - an active search sends j/k to the query (engine key fallback).
    static func routesToDisplayLines(_ state: EditorState) -> Bool {
        state.mode != .insert && state.pendingCommand.isEmpty
            && state.search?.isActive != true
            && !(state.mode == .visual && state.visualSelectionKind == .line)
    }

    /// Moves by one display line through `.setSelection`. Every word and line
    /// operation stays with the engine's logical lines.
    private func moveByDisplayLine(_ translation: ReviewKeyTranslator.Translation) -> Bool {
        let state = session.state
        guard Self.routesToDisplayLines(state), translation.modifiers.isEmpty,
              let surface else { return false }
        let down: Bool
        switch translation.key {
        case .character("j"), .down: down = true
        case .character("k"), .up: down = false
        default: return false
        }
        let text = state.text
        let from = GraphemeRangeMapper.utf16Offset(forGrapheme: state.activeCursor, in: text)
        guard let targetOffset = surface.surfaceDisplayLineTarget(from: from, down: down, goalX: &displayGoalX) else {
            return false
        }
        let target = GraphemeRangeMapper.graphemeOffset(forUTF16: targetOffset, in: text)
        let selection = state.mode == .visual
            ? ReviewTextMath.visualSelection(anchorCell: state.visualAnchor ?? state.activeCursor, activeCell: target)
            : EditorSelection(anchor: target, head: target)
        let goal = displayGoalX
        session.send(.setSelection(selection))
        applySnapshot()
        displayGoalX = goal
        return true
    }

    // MARK: Native transactions

    /// Runs NSTextView's own handling, then reports the result once. Nested calls
    /// (a paste inside a key event) report only when the outermost one finishes.
    /// Nothing is reported while marked text is showing; the committing
    /// transaction reports instead.
    func performNative(flushFirst: Bool = false, _ body: () -> Void) {
        if flushFirst, nativeDepth == 0, surface?.surfaceHasMarkedText == false {
            session.send(.flushPendingInput)
        }
        nativeDepth += 1
        body()
        nativeDepth -= 1
        guard nativeDepth == 0, let surface, !surface.surfaceHasMarkedText else { return }
        reportNativeState(of: surface)
    }

    /// Paste, cut and drop are out-of-band native edits: allowed only in Insert,
    /// where the caller wraps them in `performNative(flushFirst: true)`. In
    /// Normal/Visual they show a hint instead.
    func allowsNativeEdit(_ kind: NativeEditKind) -> Bool {
        guard !session.isFinished else { return false }
        if session.state.mode == .insert { return true }
        switch kind {
        case .paste, .drop: session.flashHint(Self.pasteHint)
        case .cut: session.flashHint(Self.cutHint)
        }
        return false
    }

    /// NSTextView changed text outside any tracked transaction (the emoji viewer,
    /// dictation, an IME committing on click, Services). NSTextView moves the
    /// selection *before* didChangeText, so `selectionDidChange` normally reports
    /// the edit first. In that case this is a no-op, which avoids a duplicate
    /// report.
    func textDidChangeOutOfBand() {
        guard !isApplyingSnapshot, nativeDepth == 0, let surface, !surface.surfaceHasMarkedText,
              !ReviewTextMath.identical(surface.surfaceText, session.state.text) else { return }
        reportNativeState(of: surface)
    }

    func selectionDidChange(stillSelecting: Bool) {
        guard !isApplyingSnapshot, nativeDepth == 0, !stillSelecting, !session.isFinished,
              let surface, !surface.surfaceHasMarkedText else { return }
        displayGoalX = nil
        // Native text ahead of the engine means this callback is the selection half
        // of an untracked native edit. Report the edit itself (one nativeUpdate in
        // Insert). Applying the stale snapshot here would write the old text back
        // over NSTextView's in-progress edit and lose the user's input.
        if !ReviewTextMath.identical(surface.surfaceText, session.state.text) {
            reportNativeState(of: surface)
            return
        }
        let selection = GraphemeRangeMapper.selection(for: surface.surfaceSelectedRange, in: surface.surfaceText)
        // During an active search even an unchanged click counts: it abandons the
        // preview (see endSearchPreview) and then places the cursor.
        guard selection != session.state.selection || session.state.search?.isActive == true else { return }
        endSearchPreview()
        session.send(.setSelection(selection))
        applySnapshot()
    }

    /// A document selection change while the query field is open abandons the
    /// preview, like Esc. Cancelling first means the selection lands on the
    /// restored pre-search state rather than racing the preview.
    private func endSearchPreview() {
        guard session.state.search?.isActive == true else { return }
        session.send(.cancelSearch)
    }

    /// Called just before an input method starts composing.
    func willBeginComposition() {
        session.send(.flushPendingInput)
    }

    /// Blur: the panel resigned key, or the editor lost first responder. Disarms
    /// the chord and clears any unfinished command; the text never changes.
    func focusDidResign() {
        guard !session.isFinished, surface?.surfaceHasMarkedText == false else { return }
        session.send(.flushPendingInput)
    }

    // MARK: Rendering

    /// Makes the native view match the engine snapshot: minimal text replacement,
    /// then selection, then mode visuals. Skipped mid-transaction or while
    /// composing, where the native view is legitimately ahead of the engine.
    func applySnapshot() {
        guard let surface, nativeDepth == 0, !surface.surfaceHasMarkedText else { return }
        let state = session.state
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        if let change = ReviewTextMath.minimalReplacement(from: surface.surfaceText, to: state.text) {
            surface.surfaceReplaceCharacters(in: change.range, with: change.replacement)
        }
        let range = Self.displayRange(for: state)
        let revealRequested = session.revealRequest != revealedRequest
        revealedRequest = session.revealRequest
        if surface.surfaceSelectedRange != range {
            surface.surfaceSetSelectedRange(range)
        } else if revealRequested {
            surface.surfaceRevealSelection()
        }
        surface.surfaceRender(state)
    }

    /// Normal mode shows a caret at the cursor cell (drawn as a block); Insert and
    /// Visual render the engine's selection verbatim.
    static func displayRange(for state: EditorState) -> NSRange {
        if state.mode == .normal {
            return NSRange(location: GraphemeRangeMapper.utf16Offset(forGrapheme: state.cursor, in: state.text), length: 0)
        }
        return GraphemeRangeMapper.nsRange(for: state.selection, in: state.text)
    }

    private func reportNativeState(of surface: ReviewTextSurface) {
        let text = surface.surfaceText
        let selection = GraphemeRangeMapper.selection(for: surface.surfaceSelectedRange, in: text)
        if session.state.mode == .insert {
            session.send(.nativeUpdate(text: text, selection: selection))
        } else if selection != session.state.selection {
            // e.g. ⌘A, which the engine passes to NSTextView outside Insert.
            endSearchPreview()
            session.send(.setSelection(selection))
        }
        applySnapshot()
    }

    static func unsupportedHint(_ translation: ReviewKeyTranslator.Translation) -> String {
        var label = ""
        if translation.modifiers.contains(.control) { label += "⌃" }
        if translation.modifiers.contains(.option) { label += "⌥" }
        switch translation.key {
        case let .character(character): label += String(character)
        case .tab: label += "⇥"
        case .backspace: label += "⌫"
        case .deleteForward: label += "⌦"
        case .enter: label += "⏎"
        default: label += "That key"
        }
        return "\(label) isn't supported here"
    }
}
