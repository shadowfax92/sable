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
    @Published var pickerQuery: String = "" {
        didSet { syncHighlightedMode() }
    }
    @Published var highlightedModeID: UUID?
    /// Forces focus back into the reused panel after each presentation.
    @Published var focusNonce = 0

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onPickMode: ((UUID) -> Void)?

    var visibleModes: [SableMode] {
        ModeSearch.filter(modes, query: pickerQuery)
    }

    func configurePicker(selectedText: String, modes: [SableMode], initialModeID: UUID?) {
        modeName = "Choose mode"
        modeSymbol = "wand.and.stars"
        requiresInput = true
        activeModeID = nil
        self.selectedText = selectedText
        self.modes = modes
        input = ""
        pickerQuery = ""
        phase = .picking
        syncHighlightedMode(preferredID: initialModeID)
        focusNonce += 1
    }

    func configure(mode: SableMode, selectedText: String, modes: [SableMode]) {
        modeName = mode.name
        modeSymbol = mode.symbol
        requiresInput = mode.requiresInput
        activeModeID = mode.id
        highlightedModeID = mode.id
        self.selectedText = selectedText
        self.modes = modes
        input = ""
        phase = .input
        focusNonce += 1
    }

    func showPicker() {
        guard !modes.isEmpty else { return }
        pickerQuery = ""
        phase = .picking
        syncHighlightedMode(preferredID: activeModeID)
        focusNonce += 1
    }

    func pickHighlightedMode() {
        guard let id = highlightedModeID ?? visibleModes.first?.id else { return }
        onPickMode?(id)
    }

    func selectNextMode() {
        moveHighlight(by: 1)
    }

    func selectPreviousMode() {
        moveHighlight(by: -1)
    }

    private func syncHighlightedMode(preferredID: UUID? = nil) {
        let visibleModes = self.visibleModes
        guard !visibleModes.isEmpty else {
            highlightedModeID = nil
            return
        }

        if let preferredID, visibleModes.contains(where: { $0.id == preferredID }) {
            highlightedModeID = preferredID
            return
        }

        if let highlightedModeID, visibleModes.contains(where: { $0.id == highlightedModeID }) {
            return
        }

        highlightedModeID = visibleModes.first?.id
    }

    private func moveHighlight(by offset: Int) {
        let visibleModes = self.visibleModes
        guard !visibleModes.isEmpty else {
            highlightedModeID = nil
            return
        }

        let currentIndex = highlightedModeID.flatMap { id in
            visibleModes.firstIndex { $0.id == id }
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + visibleModes.count) % visibleModes.count
        highlightedModeID = visibleModes[nextIndex].id
    }
}
