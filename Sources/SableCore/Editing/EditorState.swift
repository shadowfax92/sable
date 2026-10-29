import Foundation

/// Modal interpretation of command keys. Native/IME text insertion remains
/// owned by the NSTextView adapter; the core owns modal transitions and undo.
public enum EditorMode: String, Equatable, Sendable {
    case normal
    case insert
    case visual
}

/// Visual Line uses logical document lines, independent of native text wrapping.
public enum EditorVisualSelectionKind: String, Equatable, Sendable {
    case character
    case line
}

public enum EditorSearchDirection: String, Equatable, Sendable {
    case forward
    case backward

    var reversed: Self { self == .forward ? .backward : .forward }
}

/// Engine-owned search feedback. Ranges use document Character offsets, and the
/// optional index is 1-based in document order, independent of search direction.
/// Inactive feedback describes the committed query; active feedback is a preview.
public struct EditorSearchState: Equatable, Sendable {
    public let isActive: Bool
    public let query: String
    public let direction: EditorSearchDirection
    public let match: Range<Int>?
    public let matchIndex: Int?
    public let matchCount: Int
    public let didWrap: Bool
    public var hasNoMatch: Bool { !query.isEmpty && matchCount == 0 }

    public init(
        isActive: Bool, query: String, direction: EditorSearchDirection,
        match: Range<Int>? = nil, matchIndex: Int? = nil,
        matchCount: Int = 0, didWrap: Bool = false
    ) {
        self.isActive = isActive
        self.query = query
        self.direction = direction
        self.match = match
        self.matchIndex = matchIndex
        self.matchCount = matchCount
        self.didWrap = didWrap
    }
}

/// Directed selection in extended grapheme-cluster offsets, never UTF-16 or
/// scalar offsets. head is the cursor; anchor preserves visual selection direction.
/// Ranges are half-open; the native adapter translates to/from NSRange at its edge.
/// In Visual, head is a selection boundary: forward selections place it just
/// after the active cell. The engine owns inclusive Vim-cell interpretation.
public struct EditorSelection: Equatable, Sendable {
    public let anchor: Int
    public let head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
    public var isEmpty: Bool { anchor == head }
}

/// The single authoritative document snapshot shared with the native editor.
/// Construction clamps offsets to Character boundaries; normal mode has a
/// collapsed selection. Engine internals retain pending chords, registers and undo.
public struct EditorState: Equatable, Sendable {
    public let text: String
    public let selection: EditorSelection
    public let mode: EditorMode
    /// Engine-derived showcmd metadata, empty when the modal parser is idle.
    /// The adapter may route plain j/k to display lines only while this is empty;
    /// counts/operators stay in the engine and retain logical-line semantics.
    public let pendingCommand: String
    public let visualSelectionKind: EditorVisualSelectionKind
    /// Actual active cell, rather than the half-open boundary in cursor/head.
    /// A line selection can include a newline far beyond its active caret.
    public let activeCursor: Int
    /// Original Visual anchor cell. Publishing it preserves a trailing empty
    /// anchor line even when its half-open selection has no bytes to select.
    public let visualAnchor: Int?
    public let search: EditorSearchState?
    public var cursor: Int { selection.head }

    public init(
        text: String,
        selection: EditorSelection = EditorSelection(anchor: 0, head: 0),
        mode: EditorMode = .normal,
        pendingCommand: String = "",
        visualSelectionKind: EditorVisualSelectionKind = .character,
        activeCursor: Int? = nil,
        visualAnchor: Int? = nil,
        search: EditorSearchState? = nil
    ) {
        self.text = text
        self.mode = mode
        self.pendingCommand = pendingCommand
        self.search = search
        let count = text.count
        let head = min(max(selection.head, 0), count)
        let anchor = mode == .normal ? head : min(max(selection.anchor, 0), count)
        self.visualSelectionKind = mode == .visual ? visualSelectionKind : .character
        if mode == .visual {
            let active = min(max(activeCursor ?? (head > anchor ? head - 1 : head), 0), count)
            let origin = min(max(visualAnchor ?? (head >= anchor ? anchor : max(0, anchor - 1)), 0), count)
            if visualSelectionKind == .line {
                let buffer = EditorBuffer(text)
                let first = buffer.line(at: origin)
                let last = buffer.line(at: active)
                let lower = buffer.starts[min(first, last)]
                let upperRow = max(first, last)
                let upper = upperRow + 1 < buffer.starts.count ? buffer.starts[upperRow + 1] : count
                self.selection = last >= first
                    ? .init(anchor: lower, head: upper) : .init(anchor: upper, head: lower)
                self.activeCursor = buffer.normalCursor(active)
                self.visualAnchor = buffer.normalCursor(origin)
            } else {
                self.selection = .init(anchor: anchor, head: head)
                self.activeCursor = active
                self.visualAnchor = origin
            }
        } else {
            self.selection = .init(anchor: anchor, head: head)
            self.activeCursor = head
            self.visualAnchor = nil
        }
    }
}
