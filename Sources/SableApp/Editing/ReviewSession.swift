import Foundation
import SableCore

/// Where an accepted review result would go. Supplied by the interaction owner,
/// which captured the source app before the overlay took key focus. The overlay
/// only uses it for hints; it never activates apps or posts key events.
struct ReviewTarget: Equatable {
    /// Localized name of the captured source app, for "paste into <App>" hints.
    var sourceAppName: String?
    /// False when the source is Sable itself or unknown. Cmd-Enter then still
    /// produces a `.paste` delivery; the interaction owner falls back to copying
    /// and reports that outcome.
    var canPasteBack: Bool

    init(sourceAppName: String? = nil, canPasteBack: Bool = false) {
        self.sourceAppName = sourceAppName
        self.canPasteBack = canPasteBack
    }
}

/// The user's final decision about a reviewed result. Payloads carry the edited
/// buffer, never the original generation, so History and the clipboard see what
/// the user accepted (or what they discarded, so it stays recoverable). The
/// interaction owner executes it; the overlay never writes to NSPasteboard.
struct ReviewDelivery: Equatable {
    enum Action: Equatable {
        /// Normal-mode Enter: put `text` on the clipboard and close.
        case copy
        /// Cmd-Enter: put `text` on the clipboard and paste into the source app
        /// when that can be done safely.
        case paste
        /// Normal-mode Escape: close and restore the pre-interaction clipboard.
        case discard
    }

    /// Correlates with the interaction that produced the result. The owner drops
    /// deliveries for any interaction other than the current one.
    let interactionID: UUID
    let action: Action
    let text: String
}

/// UI-side owner of exactly one review session: the editor engine, its latest
/// snapshot, and the one-shot delivery of the result.
///
/// Data flow: the native adapter (`ReviewEditorView`) translates AppKit events
/// into `EditorEvent`s and calls `send`. The session applies the returned
/// snapshot first, then turns engine effects into a `ReviewDelivery`. The engine
/// stays authoritative for text, selection, mode, undo and registers. The only
/// policy layered on top is the edited-buffer discard guard (ux-design R4).
@MainActor
final class ReviewSession: ObservableObject {
    /// Window in which a second clean Normal-mode Escape confirms discarding edits.
    static let discardConfirmationWindow: TimeInterval = 1.5

    let interactionID: UUID
    /// The generated result as it arrived, used to tell whether the user edited it.
    let originalText: String
    let target: ReviewTarget

    @Published private(set) var state: EditorState
    /// True after a clean Escape on an edited buffer. The hint bar shows
    /// "esc again to discard edits" until the next event disarms it or it expires.
    @Published private(set) var isDiscardArmed = false
    /// Set once a delivery has been emitted. Later events are ignored, so key
    /// repeat or a late callback can't paste or copy twice.
    @Published private(set) var isFinished = false
    /// Short-lived footer note, e.g. "i, then ⌘V to paste" or an unsupported
    /// key. Session-scoped, so it can never leak into a later interaction.
    @Published private(set) var hint: String?

    private var engine: any EditorHandling
    private let deliver: (ReviewDelivery) -> Void
    private let now: () -> TimeInterval
    private var discardArmedAt: TimeInterval?
    private var hintToken = 0

    /// - Parameters:
    ///   - engine: Owned exclusively by this session. Injected so tests and the
    ///     pre-merge skeleton can use a fake instead of `EditorEngine`.
    ///   - deliver: Receives at most one delivery. `OverlayModel` routes it to
    ///     the interaction owner only while this session is still current.
    ///   - now: Monotonic seconds for the discard guard (mirrors the engine's
    ///     monotonic key timestamps).
    init(
        interactionID: UUID,
        text: String,
        target: ReviewTarget,
        engine: any EditorHandling,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        deliver: @escaping (ReviewDelivery) -> Void
    ) {
        self.interactionID = interactionID
        self.originalText = text
        self.target = target
        self.engine = engine
        self.state = engine.state
        self.now = now
        self.deliver = deliver
    }

    var isEdited: Bool { state.text != originalText }

    /// Sends one event to the engine and applies its update. Returns the
    /// disposition so the native adapter knows whether to let NSTextView handle
    /// the key. Returns nil when the session has finished, or when the engine
    /// failed (the skeleton engine throws): state is left untouched and the
    /// adapter should consume the key rather than insert it.
    @discardableResult
    func send(_ event: EditorEvent) -> EditorEventDisposition? {
        guard !isFinished else { return nil }
        let update: EditorUpdate
        do {
            update = try engine.handle(event)
        } catch {
            return nil
        }
        // Apply state before effects, so the delivered text includes any native
        // Insert text the engine just accepted. Skip identical snapshots so a
        // flush mid-composition does not trigger a redundant SwiftUI pass.
        if state != update.state { state = update.state }
        if update.effects.isEmpty {
            disarmDiscard()
        }
        for effect in update.effects where !isFinished {
            perform(effect)
        }
        return update.disposition
    }

    /// Shows `text` in the footer, then clears it unless a newer hint replaced it.
    func flashHint(_ text: String, for duration: TimeInterval = 1.4) {
        hintToken += 1
        let token = hintToken
        hint = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.hintToken == token else { return }
            self.hint = nil
        }
    }

    private func perform(_ effect: EditorEffect) {
        switch effect {
        case let .copyAndClose(text):
            finish(.copy, text: text)
        case let .pasteAndClose(text):
            finish(.paste, text: text)
        case .cancel:
            requestDiscard()
        }
    }

    /// A vim user's Escape is reflexive, so repeated Escape out of Insert must not
    /// silently drop edits. An unedited result discards at once.
    private func requestDiscard() {
        let timestamp = now()
        if !isEdited {
            finish(.discard, text: state.text)
        } else if let armedAt = discardArmedAt, timestamp - armedAt <= Self.discardConfirmationWindow {
            finish(.discard, text: state.text)
        } else {
            discardArmedAt = timestamp
            isDiscardArmed = true
        }
    }

    private func disarmDiscard() {
        discardArmedAt = nil
        if isDiscardArmed { isDiscardArmed = false }
    }

    private func finish(_ action: ReviewDelivery.Action, text: String) {
        disarmDiscard()
        isFinished = true
        deliver(ReviewDelivery(interactionID: interactionID, action: action, text: text))
    }
}
