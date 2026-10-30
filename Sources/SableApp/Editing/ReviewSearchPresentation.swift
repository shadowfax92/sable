import Foundation
import SableCore

/// Footer text for Vim search, derived only from the engine's `EditorSearchState`.
///
/// The engine owns the query, matching, direction, wrap and match counts. This
/// type only turns that state into the inline command-line status (`2/5`,
/// `no match`) and the short flash after a jump (`/deadline  2/5 wrapped`). It
/// never inspects the document text, so it can't drift from the engine's
/// literal or smartcase rules.
enum ReviewSearchPresentation {
    /// `/` or `?`, the command-line prefix for the search direction.
    static func prompt(_ search: EditorSearchState) -> String {
        search.direction == .forward ? "/" : "?"
    }

    /// Live status next to the query while the search is active. Returns nil
    /// for an empty query, which has nothing to report yet.
    static func status(_ search: EditorSearchState) -> (text: String, isWarning: Bool)? {
        if search.hasNoMatch { return ("no match", true) }
        guard !search.query.isEmpty, let index = search.matchIndex else { return nil }
        return ("\(index)/\(search.matchCount)" + (search.didWrap ? " wrapped" : ""), false)
    }

    /// The flash after a committed jump: accept, `n`/`N`, or their counted forms.
    /// Vim leaves the pattern on the command line after a search; this does the
    /// same for 1.4 s, then the hints come back.
    static func jumpMessage(_ search: EditorSearchState?) -> String? {
        guard let search, !search.query.isEmpty else { return nil }
        if search.hasNoMatch { return "not found: \(search.query)" }
        guard let status = status(search) else { return nil }
        return "\(prompt(search))\(search.query)  \(status.text)"
    }

    static let noPreviousSearch = "no previous search"

    /// Feedback for a key the document view sent to the engine, or nil when the
    /// key wasn't a search jump. Two cases count as a jump:
    /// - The engine's key fallback accepting an active search with ⏎ or ⌘⏎ (keys
    ///   typed before the inline field took focus).
    /// - A Normal/Visual `n` or `N`, optionally counted. Operator-pending `dn` is
    ///   not a search motion in this editor, so it's excluded.
    static func feedback(
        afterKey key: EditorKey,
        modifiers: EditorModifiers,
        before: EditorState,
        after: EditorState
    ) -> String? {
        guard before.mode != .insert else { return nil }
        if before.search?.isActive == true {
            guard key == .enter, after.search?.isActive != true else { return nil }
            return jumpMessage(after.search)
        }
        guard case let .character(character) = key, character == "n" || character == "N",
              modifiers.subtracting(.shift).isEmpty,
              before.pendingCommand.allSatisfy(\.isNumber) else { return nil }
        guard let search = after.search else { return noPreviousSearch }
        return jumpMessage(search)
    }
}
