import Foundation

/// Platform-neutral command modifiers; no NSEvent crosses the core boundary.
public struct EditorModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = EditorModifiers(rawValue: 1 << 0)
    public static let control = EditorModifiers(rawValue: 1 << 1)
    public static let option = EditorModifiers(rawValue: 1 << 2)
    public static let shift = EditorModifiers(rawValue: 1 << 3)
}

/// Semantic keys sent only outside an active IME composition. Native text
/// transactions, including composed Unicode, arrive separately as nativeUpdate.
public enum EditorKey: Equatable, Sendable {
    case character(Character)
    case enter
    case escape
    case backspace
    case deleteForward
    case left
    case right
    case up
    case down
    case tab
}

/// Explicit inputs make chord timing deterministic: timestamps are monotonic
/// seconds supplied by the adapter, never wall-clock reads inside the engine.
public enum EditorEvent: Equatable, Sendable {
    case key(EditorKey, modifiers: EditorModifiers = [], timestamp: TimeInterval)
    /// The complete native transaction, not a second independently edited buffer.
    /// Apply only in Insert mode and preserve its grapheme-based selection.
    case nativeUpdate(text: String, selection: EditorSelection)
    /// Send before blur/delivery or when the chord timer expires. A pending
    /// Insert-mode j must become literal text rather than being silently dropped.
    case flushPendingInput
}

/// The interaction coordinator executes delivery effects against its captured
/// source app and clipboard snapshot. The editor never touches the system clipboard.
public enum EditorEffect: Equatable, Sendable {
    case copyAndClose(String)
    case pasteAndClose(String)
    case cancel
}

/// handled consumes the event; passToNative permits normal NSTextView handling
/// (including Insert Enter/newline and macOS shortcuts). unsupported also consumes
/// the event: unimplemented Normal/Visual commands must never insert literal text.
public enum EditorEventDisposition: Equatable, Sendable {
    case handled
    case passToNative
    case unsupported
}

/// A complete post-event snapshot and requested effects. The adapter applies
/// state before executing effects so pending Insert text survives a delivery key.
public struct EditorUpdate: Equatable, Sendable {
    public let state: EditorState
    public let effects: [EditorEffect]
    public let disposition: EditorEventDisposition

    public init(state: EditorState, effects: [EditorEffect] = [], disposition: EditorEventDisposition) {
        self.state = state
        self.effects = effects
        self.disposition = disposition
    }
}

/// One engine per review session, exclusively owned by its UI adapter. handle
/// atomically updates state and returns effects; undo/registers are session-local.
/// Normal Enter copies; Cmd-Enter pastes; Insert Enter inserts a newline; jk/jj
/// leave Insert; Escape exits Insert/Visual before Normal Escape cancels.
public protocol EditorHandling {
    var state: EditorState { get }
    mutating func handle(_ event: EditorEvent) throws -> EditorUpdate
}

/// Explicit failure keeps the skeleton from claiming any key was implemented.
public enum EditorError: Error, Equatable, Sendable {
    case notImplemented
}

/// Compiling engine seam for the editor piece. No key handling or delivery runs
/// until that piece replaces the throwing implementation.
public struct EditorEngine: EditorHandling {
    public private(set) var state: EditorState

    public init(state: EditorState) { self.state = state }

    public mutating func handle(_ event: EditorEvent) throws -> EditorUpdate {
        throw EditorError.notImplemented
    }
}
