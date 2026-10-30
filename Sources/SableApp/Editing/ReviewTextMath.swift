import Foundation
import SableCore

/// Pure helpers for keeping NSTextView and the editor engine in step.
enum ReviewTextMath {
    /// The smallest replacement that turns `old` into `new`, as a UTF-16 range of
    /// `old` plus the replacement string. Returns nil when they are already
    /// identical. Boundaries fall on grapheme clusters, and equality is exact
    /// (scalar for scalar, not canonical equivalence), so a decomposed "é" is
    /// never treated as unchanged against a precomposed one. Replacing only the
    /// changed span keeps the scroll position and attributes elsewhere intact.
    static func minimalReplacement(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        guard !identical(old, new) else { return nil }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var prefix = 0
        while prefix < oldCharacters.count, prefix < newCharacters.count,
              identical(oldCharacters[prefix], newCharacters[prefix]) {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldCharacters.count - prefix, suffix < newCharacters.count - prefix,
              identical(oldCharacters[oldCharacters.count - 1 - suffix], newCharacters[newCharacters.count - 1 - suffix]) {
            suffix += 1
        }
        let location = utf16Length(oldCharacters[0..<prefix])
        let length = utf16Length(oldCharacters[prefix..<(oldCharacters.count - suffix)])
        let replacement = String(newCharacters[prefix..<(newCharacters.count - suffix)])
        return (NSRange(location: location, length: length), replacement)
    }

    /// Exact text equality, not Swift's canonical-equivalence `==`.
    static func identical(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    /// Encodes a characterwise Visual selection between two inclusive cells the
    /// way the engine does: forward selections put `head` after the active cell,
    /// reverse selections put it before. The cells come from the engine's own
    /// `visualAnchor`/`activeCursor`, so the UI never re-derives them from the
    /// half-open range (which can't express a line selection's caret).
    static func visualSelection(anchorCell: Int, activeCell target: Int) -> EditorSelection {
        if target >= anchorCell {
            return EditorSelection(anchor: anchorCell, head: target + 1)
        }
        return EditorSelection(anchor: anchorCell + 1, head: target)
    }

    private static func identical(_ lhs: Character, _ rhs: Character) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    private static func utf16Length(_ characters: ArraySlice<Character>) -> Int {
        characters.reduce(0) { $0 + $1.utf16.count }
    }
}
