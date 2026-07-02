import AppKit
import Foundation
import KeyboardShortcuts
import SableCore

extension KeyboardShortcuts.Name {
    /// Configurable global shortcut that opens the mode picker.
    static let sablePopup = Self("sablePopup")

    /// Optional direct shortcut for one stable mode id.
    static func mode(_ id: UUID) -> Self {
        Self("sable.mode.\(id.uuidString)")
    }
}

/// Registers global shortcuts and dispatches them back to the coordinator.
@MainActor
final class HotkeyService {
    var onOpenPopup: (() -> Void)?
    var onTriggerMode: ((UUID) -> Void)?

    private var registeredModeNames = Set<String>()

    init() {
        KeyboardShortcuts.onKeyUp(for: .sablePopup) { [weak self] in
            Task { @MainActor in self?.onOpenPopup?() }
        }
    }

    /// Seeds the picker shortcut once so clearing it later stays respected.
    func seedDefaultsIfNeeded() {
        let key = "sable.didSeedShortcuts.v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        if KeyboardShortcuts.getShortcut(for: .sablePopup) == nil {
            KeyboardShortcuts.setShortcut(
                .init(.space, modifiers: [.command, .option, .control]),
                for: .sablePopup
            )
        }
    }

    /// Installs direct mode shortcut handlers once per stable mode id.
    func syncModeHotkeys(_ modes: [SableMode]) {
        for mode in modes {
            let name = KeyboardShortcuts.Name.mode(mode.id)
            guard registeredModeNames.insert(name.rawValue).inserted else {
                continue
            }
            let id = mode.id
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                Task { @MainActor in self?.onTriggerMode?(id) }
            }
        }
    }
}
