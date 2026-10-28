import AppKit
import SableCore

/// Translates AppKit key events into the editor core's platform-neutral keys.
///
/// Command and Control shortcuts are identified by their unmodified key (⌘Z,
/// ⌃R). Plain and Option typing uses the character the layout actually produced,
/// so non-US layouts work. Shift stays in the modifier set because the engine
/// needs it for ⌘⇧Z, while ordinary capitals already arrive as the character.
/// Keys with no semantic meaning to the engine (function keys, Home/End, dead
/// keys) return nil, and the adapter lets NSTextView handle them natively.
enum ReviewKeyTranslator {
    struct Translation: Equatable {
        let key: EditorKey
        let modifiers: EditorModifiers
    }

    static func translate(_ event: NSEvent) -> Translation? {
        guard event.type == .keyDown else { return nil }
        return translate(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            flags: event.modifierFlags
        )
    }

    static func translate(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        flags: NSEvent.ModifierFlags
    ) -> Translation? {
        var modifiers: EditorModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        if let special = specialKey(keyCode) {
            return Translation(key: special, modifiers: modifiers)
        }
        let isShortcut = modifiers.contains(.command) || modifiers.contains(.control)
        guard let source = isShortcut ? charactersIgnoringModifiers : characters,
              source.count == 1, let character = source.first else { return nil }
        // AppKit encodes arrows, Home/End and F-keys as private-use scalars.
        if let scalar = character.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) {
            return nil
        }
        if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }
        return Translation(key: .character(character), modifiers: modifiers)
    }

    private static func specialKey(_ keyCode: UInt16) -> EditorKey? {
        switch keyCode {
        case 36, 76: return .enter
        case 53: return .escape
        case 51: return .backspace
        case 117: return .deleteForward
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 48: return .tab
        default: return nil
        }
    }
}
