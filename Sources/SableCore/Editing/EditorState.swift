import Foundation

/// Modal interpretation of command keys. Native/IME text insertion remains
/// owned by the NSTextView adapter; the core owns modal transitions and undo.
public enum EditorMode: String, Equatable, Sendable {
    case normal
    case insert
    case visual
}

/// Directed selection in extended grapheme-cluster offsets, never UTF-16 or
/// scalar offsets. head is the cursor; anchor preserves visual selection direction.
/// Ranges are half-open; the native adapter translates to/from NSRange at its edge.
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
    public var cursor: Int { selection.head }

    public init(
        text: String,
        selection: EditorSelection = EditorSelection(anchor: 0, head: 0),
        mode: EditorMode = .normal
    ) {
        self.text = text
        self.mode = mode
        let count = text.count
        let head = min(max(selection.head, 0), count)
        let anchor = mode == .normal ? head : min(max(selection.anchor, 0), count)
        self.selection = EditorSelection(anchor: anchor, head: head)
    }
}
