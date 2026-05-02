import AppKit
import Foundation
import KeyboardShortcuts
import SableCore

extension KeyboardShortcuts.Name {
    static let quickFix = Self("quickFix")
    static let askClaude = Self("askClaude")
}

@MainActor
final class HotkeyService {
    var onQuickFix: (() -> Void)?
    var onAskClaude: (() -> Void)?

    init() {
        KeyboardShortcuts.onKeyUp(for: .quickFix) { [weak self] in
            Task { @MainActor in self?.onQuickFix?() }
        }
        KeyboardShortcuts.onKeyUp(for: .askClaude) { [weak self] in
            Task { @MainActor in self?.onAskClaude?() }
        }
    }

    /// Applies YAML-defined shortcuts without re-registering duplicate event handlers.
    func configure(with config: AppConfig) throws {
        let quickFix = try keyboardShortcut(from: config.hotkeys.quickFix)
        let ask = try keyboardShortcut(from: config.hotkeys.ask)

        KeyboardShortcuts.setShortcut(quickFix, for: .quickFix)
        KeyboardShortcuts.setShortcut(ask, for: .askClaude)
    }

    private func keyboardShortcut(from value: String) throws -> KeyboardShortcuts.Shortcut {
        let parsed = try HotkeyParser.parse(value)
        let key = try key(from: parsed.key)

        var modifiers = NSEvent.ModifierFlags()
        if parsed.modifiers.contains(.command) { modifiers.insert(.command) }
        if parsed.modifiers.contains(.control) { modifiers.insert(.control) }
        if parsed.modifiers.contains(.option) { modifiers.insert(.option) }
        if parsed.modifiers.contains(.shift) { modifiers.insert(.shift) }

        return KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
    }

    private func key(from value: String) throws -> KeyboardShortcuts.Key {
        switch value {
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        case "0": return .zero
        case "1": return .one
        case "2": return .two
        case "3": return .three
        case "4": return .four
        case "5": return .five
        case "6": return .six
        case "7": return .seven
        case "8": return .eight
        case "9": return .nine
        case "space": return .space
        case "return", "enter": return .return
        case "escape", "esc": return .escape
        default:
            throw SableError.invalidConfig("unsupported hotkey key '\(value)'")
        }
    }
}
