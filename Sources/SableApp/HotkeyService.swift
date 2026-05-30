import AppKit
import Foundation
import KeyboardShortcuts
import SableCore

extension KeyboardShortcuts.Name {
    /// Bare popup hotkey: opens the popup with the default mode selected.
    static let sablePopup = Self("sablePopup")

    /// Per-mode hotkey. Keyed by the mode id so a mode keeps its shortcut across
    /// renames and relaunches.
    static func mode(_ id: UUID) -> Self {
        Self("sable.mode.\(id.uuidString)")
    }
}

/// Owns global hotkey registration. The bare popup shortcut is registered once;
/// per-mode shortcuts are registered lazily as modes appear. Each handler looks
/// the mode up by id at fire time (via the callback), so deleting or editing a
/// mode never leaves a stale closure pointing at old data.
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

    /// Gives the quick popup a working shortcut (⌃⌥⌘Space) on first launch only, so
    /// Sable is usable immediately. Guarded by a one-time flag so a user who
    /// deliberately clears it won't have it reappear.
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

    /// Ensures every mode has a fire handler. Safe to call repeatedly — each id's
    /// handler is installed at most once.
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
