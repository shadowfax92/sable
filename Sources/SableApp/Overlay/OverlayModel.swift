import SableCore
import SwiftUI

/// Holds the floating popup state for mode picking, input, and run progress.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case picking
        case input
        case thinking
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
    /// Forces focus back into the reused panel after each presentation.
    @Published var focusNonce = 0

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onPickMode: ((UUID) -> Void)?
    var onShowPicker: (() -> Void)?

    var pickerQuery: String {
        pickerState.query
    }

    var highlightedModeID: UUID? {
        pickerState.highlightedModeID
    }

    var visibleModes: [SableMode] {
        pickerState.visibleModes
    }

    func configurePicker(selectedText: String, modes: [SableMode], initialModeID: UUID?) {
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
        focusNonce += 1
    }

    func configure(mode: SableMode, selectedText: String, modes: [SableMode]) {
        modeName = mode.name
        modeSymbol = mode.symbol
        requiresInput = mode.requiresInput
        activeModeID = mode.id
        self.selectedText = selectedText
        self.modes = modes
        pickerState = ModePickerState(modes: modes, highlightedModeID: mode.id)
        input = ""
        phase = .input
        focusNonce += 1
    }

    func showPicker() {
        guard !modes.isEmpty else { return }
        var state = pickerState
        state.configure(modes: modes, initialModeID: activeModeID)
        pickerState = state
        phase = .picking
        focusNonce += 1
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
}
