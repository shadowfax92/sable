import SableCore
import SwiftUI

/// Drives the floating popup. The coordinator mutates `phase` as a run moves from
/// awaiting input → thinking → done/error, and the view reacts. Mode metadata is
/// duplicated here (name/symbol/requiresInput) so the view stays decoupled from
/// `AppCoordinator`.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
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
    /// Bumped on every present/reconfigure so the view re-asserts text focus even
    /// when the panel (and its hosting view) is reused across runs.
    @Published var focusNonce = 0

    /// Fires when the user commits (Enter for input modes, or immediately for
    /// instant modes). Carries the typed instruction (may be empty).
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onPickMode: ((UUID) -> Void)?

    func configure(mode: SableMode, selectedText: String, modes: [SableMode]) {
        modeName = mode.name
        modeSymbol = mode.symbol
        requiresInput = mode.requiresInput
        activeModeID = mode.id
        self.selectedText = selectedText
        self.modes = modes
        input = ""
        phase = .input
        focusNonce += 1
    }
}
