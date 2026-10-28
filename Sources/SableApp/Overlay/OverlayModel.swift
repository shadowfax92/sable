import Foundation
import SableCore
import SwiftUI

/// Holds the floating popup state for mode picking, input, run progress and
/// result review.
///
/// Ownership: `AppCoordinator` (the interaction owner) drives phase changes and
/// receives user decisions through the `on…` callbacks. The overlay never touches
/// the clipboard, the source app or history.
///
/// Three things are explicit requests, never inferred from text edits:
/// - Focus: `focusNonce`. The view re-asserts first responder whenever it changes.
/// - Panel resize: `layoutRequest`. `OverlayPanelController` re-fits the panel.
/// - Session lifetime: `interactionID`. Every presentation mints or takes one,
///   and `invalidateSession()` ends it. A review session whose ID is no longer
///   current can't deliver anything.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case picking
        case input
        case thinking
        /// The completed result is open in `reviewSession`'s modal editor. Nothing
        /// has reached the clipboard; the only exit is `onReviewDelivery` (or
        /// closing the panel, which invalidates the session).
        case review
        case done(String)
        case error(String)
    }

    @Published var modeName: String = ""
    @Published var modeSymbol: String = "sparkles"
    @Published var requiresInput: Bool = true
    @Published var selectedText: String = ""
    @Published var input: String = ""
    @Published var phase: Phase = .input
    @Published var modes: [SableMode] = []
    @Published var activeModeID: UUID?
    @Published private var pickerState = ModePickerState()
    /// Forces focus back into the reused panel after each presentation. Bump it
    /// through `requestFocus()` whenever a phase needs a new first responder.
    @Published var focusNonce = 0
    /// Bumped by `requestLayout()` when content height changes for a reason the
    /// panel can't observe (a phase switch, the review editor growing).
    /// `OverlayPanelController` re-fits the panel on each change.
    @Published private(set) var layoutRequest = 0
    /// Correlates everything shown with one hotkey interaction. Nil once the
    /// panel has closed.
    @Published private(set) var interactionID: UUID?
    /// The single live review session, present only in `.review`.
    @Published private(set) var reviewSession: ReviewSession?

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onPickMode: ((UUID) -> Void)?
    var onShowPicker: (() -> Void)?
    /// Receives the final edited text when the user copies, pastes or discards
    /// a reviewed result. Called at most once per review session, and only while
    /// that session's interaction is current. The receiver owns clipboard
    /// writes, paste-back, history and closing the panel.
    var onReviewDelivery: ((ReviewDelivery) -> Void)?

    var pickerQuery: String {
        pickerState.query
    }

    var highlightedModeID: UUID? {
        pickerState.highlightedModeID
    }

    var visibleModes: [SableMode] {
        pickerState.visibleModes
    }

    func configurePicker(
        selectedText: String,
        modes: [SableMode],
        initialModeID: UUID?,
        interactionID: UUID = UUID()
    ) {
        beginSession(interactionID)
        modeName = "Choose mode"
        modeSymbol = "wand.and.stars"
        requiresInput = true
        activeModeID = nil
        self.selectedText = selectedText
        self.modes = modes
        input = ""
        var state = pickerState
        state.configure(modes: modes, initialModeID: initialModeID)
        pickerState = state
        phase = .picking
        requestFocus()
    }

    /// Shows a specific mode. A nil `interactionID` keeps the current interaction,
    /// as when switching modes from the picker. If none is live, as after
    /// `invalidateSession()` for a direct hotkey, a new one starts.
    func configure(
        mode: SableMode,
        selectedText: String,
        modes: [SableMode],
        interactionID: UUID? = nil
    ) {
        if let interactionID {
            beginSession(interactionID)
        } else if self.interactionID == nil {
            beginSession(UUID())
        }
        modeName = mode.name
        modeSymbol = mode.symbol
        requiresInput = mode.requiresInput
        activeModeID = mode.id
        self.selectedText = selectedText
        self.modes = modes
        pickerState = ModePickerState(modes: modes, highlightedModeID: mode.id)
        input = ""
        phase = .input
        requestFocus()
    }

    func showPicker() {
        guard !modes.isEmpty else { return }
        var state = pickerState
        state.configure(modes: modes, initialModeID: activeModeID)
        pickerState = state
        phase = .picking
        requestFocus()
    }

    /// Moves the current interaction into review with a freshly generated result.
    /// A previous session is discarded without delivering. The editor starts in
    /// Normal mode at the beginning of the text.
    ///
    /// - Parameter engine: Defaults to `EditorEngine`. Injected by tests, and
    ///   usable before the real engine lands.
    func presentReview(
        result: String,
        target: ReviewTarget = ReviewTarget(),
        engine: (any EditorHandling)? = nil
    ) {
        let id = interactionID ?? UUID()
        if interactionID == nil { beginSession(id) }
        let engine = engine ?? EditorEngine(state: EditorState(text: result))
        reviewSession = ReviewSession(
            interactionID: id,
            text: result,
            target: target,
            engine: engine
        ) { [weak self] delivery in
            self?.forwardReviewDelivery(delivery)
        }
        phase = .review
        requestFocus()
        requestLayout()
    }

    /// Ends the current interaction: drops the review session and clears the
    /// interaction ID, so nothing from it can deliver. The panel controller
    /// calls this whenever the panel closes.
    func invalidateSession() {
        reviewSession = nil
        interactionID = nil
    }

    func requestFocus() {
        focusNonce += 1
    }

    func requestLayout() {
        layoutRequest += 1
    }

    func setPickerQuery(_ query: String) {
        var state = pickerState
        state.setQuery(query)
        pickerState = state
    }

    func highlightMode(_ id: UUID) {
        var state = pickerState
        state.highlight(id)
        pickerState = state
    }

    func pickHighlightedMode() {
        guard let id = pickerState.selectedModeID else { return }
        onPickMode?(id)
    }

    func selectNextMode() {
        var state = pickerState
        state.selectNext()
        pickerState = state
    }

    func selectPreviousMode() {
        var state = pickerState
        state.selectPrevious()
        pickerState = state
    }

    private func beginSession(_ id: UUID) {
        reviewSession = nil
        interactionID = id
    }

    /// Drops deliveries from sessions that are no longer current: superseded by
    /// a newer interaction, or invalidated when the panel closed.
    private func forwardReviewDelivery(_ delivery: ReviewDelivery) {
        guard delivery.interactionID == interactionID,
              reviewSession?.interactionID == delivery.interactionID else { return }
        onReviewDelivery?(delivery)
    }
}
