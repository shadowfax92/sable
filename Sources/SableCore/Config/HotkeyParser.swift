import Foundation

public struct ParsedHotkey: Equatable {
    public let key: String
    public let modifiers: Set<Modifier>

    public enum Modifier: String, Equatable, Hashable {
        case command
        case control
        case option
        case shift
    }
}

public enum HotkeyParser {
    /// Parses user-facing hotkey strings from YAML into key and modifier components.
    public static func parse(_ value: String) throws -> ParsedHotkey {
        let parts = value
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var modifiers = Set<ParsedHotkey.Modifier>()
        var keys: [String] = []

        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers.insert(.command)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "opt", "option", "alt":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                keys.append(part)
            }
        }

        guard keys.count == 1 else {
            throw SableError.invalidConfig("hotkey must contain exactly one non-modifier key")
        }

        return ParsedHotkey(key: keys[0], modifiers: modifiers)
    }
}
