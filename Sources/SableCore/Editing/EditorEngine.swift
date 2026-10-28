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
    /// Update mouse/programmatic selection without changing text or undo history.
    /// A nonempty Normal selection enters Visual; offsets are half-open graphemes.
    case setSelection(EditorSelection)
    /// Disarm chord recognition before IME, paste, blur or delivery. Text is never
    /// withheld: j goes through native insertion and only a verified jk/jj rolls back.
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
/// Normal/Visual Enter copies the whole buffer; Cmd-Enter pastes. Insert Enter
/// is native; jk/jj leave Insert. Escape exits Insert/Visual or clears a pending
/// command before a clean Normal Escape cancels.
public protocol EditorHandling {
    var state: EditorState { get }
    mutating func handle(_ event: EditorEvent) throws -> EditorUpdate
}

/// Compatibility error retained from the skeleton; unsupported keys now return
/// a disposition without throwing or mutating native text.
public enum EditorError: Error, Equatable, Sendable {
    case notImplemented
}

/// Deterministic session-local Vim subset. The adapter owns native insertion/IME,
/// reports each completed transaction, and renders handled snapshots. Insert undo
/// groups span entry through Escape, including changes reported by nativeUpdate.
public struct EditorEngine: EditorHandling {
    public private(set) var state: EditorState
    // Matches the owner's verified Neovim timeoutlen=800; one value serves
    // recognition and any adapter timeout without changing native j insertion.
    public static let insertChordTimeout: TimeInterval = 0.8

    private struct Chord {
        let before: EditorState
        let timestamp: TimeInterval
        // Native j temporarily invalidates redo; a completed escape chord is
        // not a lasting edit, so rollback restores this branch along with text.
        let redoBefore: [EditorState]
        var confirmed = false
    }
    private struct Register {
        var text: String
        var linewise: Bool
    }
    private var chord: Chord?
    private var register: Register?
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var insertStart: EditorState?
    private var desiredColumn: Int?
    private var count = ""
    private var motionCount = ""
    private var pendingOperator: Character?
    private var prefix: Character?
    // Counts are deliberately bounded; this is a small review editor, not a Vim VM.
    private static let maximumCount = 9_999

    public init(state: EditorState) {
        // Snapshots may carry showcmd for rendering, but constructing a session
        // always starts a fresh parser; metadata cannot restore hidden operators.
        self.state = EditorState(text: state.text, selection: state.selection, mode: state.mode)
        if state.mode == .normal { setNormalCursor(state.cursor) }
        if state.mode == .insert { insertStart = self.state }
    }

    public mutating func handle(_ event: EditorEvent) throws -> EditorUpdate {
        switch event {
        case .flushPendingInput:
            chord = nil
            clearCommand()
            return update()
        case .setSelection(let selection):
            chord = nil
            clearCommand()
            desiredColumn = nil
            let mode: EditorMode = state.mode == .normal && !selection.isEmpty ? .visual : state.mode
            state = EditorState(text: state.text, selection: selection, mode: mode)
            if mode == .normal { setNormalCursor(state.cursor) }
            return update()
        case .nativeUpdate(let text, let selection):
            guard state.mode == .insert else { clearCommand(); return update(.unsupported) }
            let next = EditorState(text: text, selection: selection, mode: .insert)
            if var candidate = chord, !candidate.confirmed {
                let before = EditorBuffer(candidate.before.text)
                let expected = before.replacing(candidate.before.selection.range, with: "j")
                let cursor = candidate.before.selection.range.lowerBound + 1
                if next.text == expected, next.selection == EditorSelection(anchor: cursor, head: cursor) {
                    candidate.confirmed = true
                    chord = candidate
                } else { chord = nil }
            } else { chord = nil }
            if next.text != state.text {
                if insertStart == nil { insertStart = state }
                redoStack.removeAll()
            }
            desiredColumn = nil
            state = next
            return update()
        case .key(let key, let modifiers, let timestamp):
            return handleKey(key, modifiers: modifiers, timestamp: timestamp)
        }
    }

    /// Publish parser metadata at the common event boundary, including rejected
    /// keys, native transactions and history traversal. Neither UI nor stored
    /// undo snapshots become another source of truth for the pending command.
    private mutating func update(_ disposition: EditorEventDisposition = .handled, effects: [EditorEffect] = []) -> EditorUpdate {
        if state.pendingCommand != pendingCommand {
            state = EditorState(
                text: state.text, selection: state.selection, mode: state.mode,
                pendingCommand: pendingCommand
            )
        }
        return EditorUpdate(state: state, effects: effects, disposition: disposition)
    }

    private mutating func handleKey(_ key: EditorKey, modifiers: EditorModifiers, timestamp: TimeInterval) -> EditorUpdate {
        if key == .enter, modifiers.contains(.command) {
            chord = nil
            clearCommand()
            finishInsert()
            return update(effects: [.pasteAndClose(state.text)])
        }
        if key == .escape {
            let hadPendingCommand = !pendingCommand.isEmpty
            chord = nil
            clearCommand()
            desiredColumn = nil
            if state.mode == .insert { leaveInsert(); return update() }
            if state.mode == .visual { setNormalCursor(activeCursor); return update() }
            if hadPendingCommand { return update() }
            return update(effects: [.cancel])
        }
        if case .character(let character) = key,
           (modifiers == .command && character == "z") ||
           (modifiers == [.command, .shift] && (character == "z" || character == "Z")) ||
           (modifiers == .control && character == "r" && state.mode != .insert) {
            chord = nil
            let redo = modifiers.contains(.shift) || modifiers == .control
            let repeats = commandCount
            clearCommand()
            history(redo: redo, count: repeats)
            return update()
        }
        if state.mode == .insert {
            if modifiers.isEmpty, case .character(let character) = key {
                if let candidate = chord, candidate.confirmed, (character == "j" || character == "k"),
                   timestamp.isFinite, candidate.timestamp.isFinite,
                   timestamp >= candidate.timestamp, timestamp - candidate.timestamp <= Self.insertChordTimeout {
                    // The only native update since the first key was the exact j
                    // replacement. Restoring this snapshot cannot erase paste/IME.
                    state = candidate.before
                    redoStack = candidate.redoBefore
                    chord = nil
                    leaveInsert()
                    return update()
                }
                chord = character == "j" ? Chord(before: state, timestamp: timestamp, redoBefore: redoStack) : nil
            } else { chord = nil }
            return update(.passToNative)
        }
        chord = nil
        // Shift is already reflected in the semantic Character. Standard macOS
        // command shortcuts remain native; unsupported modal keys are consumed.
        if !modifiers.intersection([.command, .control, .option]).isEmpty {
            clearCommand()
            return update(modifiers.contains(.command) ? .passToNative : .unsupported)
        }
        if key == .enter {
            clearCommand()
            return update(effects: [.copyAndClose(state.text)])
        }
        let character: Character
        switch key {
        case .character(let value): character = value
        case .left: character = "h"
        case .right: character = "l"
        case .up: character = "k"
        case .down: character = "j"
        default: clearCommand(); return update(.unsupported)
        }
        return modal(character)
    }

    private var pendingCommand: String {
        count + (pendingOperator.map { String($0) } ?? "") + motionCount + (prefix.map { String($0) } ?? "")
    }

    private var commandCount: Int { max(1, Int(count) ?? 1) }
    private var totalCount: Int { min(Self.maximumCount, commandCount * max(1, Int(motionCount) ?? 1)) }
    private mutating func clearCommand() { count = ""; motionCount = ""; pendingOperator = nil; prefix = nil }

    private mutating func modal(_ key: Character) -> EditorUpdate {
        let digits = pendingOperator == nil ? count : motionCount
        if key.isASCII, let digit = key.wholeNumberValue, digit > 0 || !digits.isEmpty {
            let next = String(min(Self.maximumCount, (Int(digits) ?? 0) * 10 + digit))
            if pendingOperator == nil { count = next } else { motionCount = next }
            return update()
        }
        let buffer = EditorBuffer(state.text)
        let cursor = activeCursor
        let repeats = totalCount
        if let prefix {
            self.prefix = nil
            if prefix == "i", key == "w", let operation = pendingOperator {
                let range = buffer.innerWord(cursor)
                clearCommand()
                operate(operation, range: range, linewise: false)
                return update()
            }
            if prefix == "g", key == "g" {
                let row = min(buffer.starts.count - 1, repeats - 1)
                let target = buffer.firstNonblank(row)
                if let operation = pendingOperator { lineOperation(operation, from: buffer.line(at: cursor), through: row) }
                else { move(to: target) }
                clearCommand()
                return update()
            }
            clearCommand()
            return update(.unsupported)
        }
        if let operation = pendingOperator {
            if key == operation {
                let row = buffer.line(at: cursor)
                lineOperation(operation, from: row, through: min(buffer.starts.count - 1, row + repeats - 1))
            } else if key == "i", operation == "c" || operation == "d" || operation == "y" {
                prefix = "i"
                return update()
            } else if key == "g" { prefix = "g"; return update() }
            else if key == "j" || key == "k" || key == "G" {
                let row = buffer.line(at: cursor)
                let target: Int
                if key == "G" {
                    target = count.isEmpty && motionCount.isEmpty
                        ? buffer.starts.count - 1 : min(buffer.starts.count - 1, repeats - 1)
                } else {
                    target = min(buffer.starts.count - 1, max(0, row + (key == "j" ? repeats : -repeats)))
                }
                lineOperation(operation, from: row, through: target)
            } else if let target = motion(key, count: repeats, buffer: buffer, cursor: cursor) {
                var end = target
                if key == "l" {
                    // Navigation stops on the last cell; an exclusive operator
                    // endpoint may reach the following insertion boundary.
                    end = min(buffer.ends[buffer.line(at: cursor)], cursor + repeats)
                } else if key == "w", operation == "c", cursor == buffer.ends[buffer.line(at: cursor)] {
                    end = cursor
                } else if key == "w", operation == "c", cursor < buffer.count, buffer.category(at: cursor) != 0 {
                    end = min(buffer.count, buffer.changeWordEnd(cursor, count: repeats) + 1)
                } else if key == "e" || key == "$" { end = min(buffer.count, target + (target < buffer.ends[buffer.line(at: target)] ? 1 : 0)) }
                // A single word operator from text or trailing spaces stops
                // before the newline. Empty-line and longer counted motions may
                // intentionally consume separators and span logical lines.
                if key == "w", repeats == 1, cursor < buffer.ends[buffer.line(at: cursor)],
                   buffer.line(at: end) > buffer.line(at: cursor) {
                    end = buffer.ends[buffer.line(at: cursor)]
                }
                operate(operation, range: min(cursor, end)..<max(cursor, end), linewise: false)
            } else { clearCommand(); return update(.unsupported) }
            clearCommand()
            return update()
        }
        if key == "g" { prefix = "g"; return update() }
        if key == "G" {
            let row = count.isEmpty ? buffer.starts.count - 1 : min(buffer.starts.count - 1, repeats - 1)
            move(to: buffer.firstNonblank(row)); clearCommand(); return update()
        }
        if let target = motion(key, count: repeats, buffer: buffer, cursor: cursor) {
            move(to: target, vertical: key == "j" || key == "k")
            clearCommand()
            return update()
        }
        if state.mode == .visual {
            switch key {
            case "v": setNormalCursor(cursor)
            case "y", "d", "x", "c": operate(key == "x" ? "d" : key, range: state.selection.range, linewise: false)
            case "p", "P": paste(before: key == "P", count: repeats)
            default: clearCommand(); return update(.unsupported)
            }
            clearCommand()
            return update()
        }
        switch key {
        case "d", "c", "y": pendingOperator = key; return update()
        case "v": selectVisual(anchor: cursor, cursor: cursor)
        case "i": enterInsert(at: cursor)
        case "a": enterInsert(at: min(buffer.ends[buffer.line(at: cursor)], cursor + 1))
        case "I": enterInsert(at: buffer.firstNonblank(buffer.line(at: cursor)))
        case "A": enterInsert(at: buffer.ends[buffer.line(at: cursor)])
        case "o", "O":
            let row = buffer.line(at: cursor)
            let position = key == "o" ? buffer.ends[row] : buffer.starts[row]
            enterInsert(at: position)
            let insertionCursor = position + (key == "o" ? 1 : 0)
            state = EditorState(
                text: buffer.replacing(position..<position, with: buffer.lineSeparator(row)),
                selection: .init(anchor: insertionCursor, head: insertionCursor), mode: .insert
            )
            redoStack.removeAll()
        case "x": operate("d", range: cursor..<min(buffer.ends[buffer.line(at: cursor)], cursor + repeats), linewise: false)
        case "D", "C":
            let lastRow = min(buffer.starts.count - 1, buffer.line(at: cursor) + repeats - 1)
            operate(key == "D" ? "d" : "c", range: cursor..<buffer.ends[lastRow], linewise: false)
        case "p", "P": paste(before: key == "P", count: repeats)
        case "u": history(redo: false, count: repeats)
        default: clearCommand(); return update(.unsupported)
        }
        desiredColumn = nil
        clearCommand()
        return update()
    }

    private func motion(_ key: Character, count: Int, buffer: EditorBuffer, cursor: Int) -> Int? {
        let row = buffer.line(at: cursor)
        switch key {
        case "h": return max(buffer.starts[row], cursor - count)
        case "l": return min(max(buffer.starts[row], buffer.ends[row] - 1), cursor + count)
        case "j", "k":
            let target = min(buffer.starts.count - 1, max(0, row + (key == "j" ? count : -count)))
            let column = desiredColumn ?? (cursor - buffer.starts[row])
            return min(buffer.starts[target] + column, max(buffer.starts[target], buffer.ends[target] - 1))
        case "w": return buffer.wordForward(cursor, count: count)
        case "b": return buffer.wordBackward(cursor, count: count)
        case "e": return buffer.wordEnd(cursor, count: count)
        case "0": return buffer.starts[row]
        case "^": return buffer.firstNonblank(row)
        case "$":
            let target = min(buffer.starts.count - 1, row + count - 1)
            return max(buffer.starts[target], buffer.ends[target] - 1)
        default: return nil
        }
    }

    /// Visual selections are native half-open ranges with inclusive Vim cells.
    /// Forward head is one boundary after the active cell; reverse head is before
    /// it. Keeping this conversion here prevents the UI reimplementing motions.
    private var activeCursor: Int {
        state.mode == .visual && state.selection.head > state.selection.anchor ? state.cursor - 1 : state.cursor
    }

    private mutating func selectVisual(anchor: Int, cursor: Int) {
        let end = min(EditorBuffer(state.text).count, max(anchor, cursor) + 1)
        let selection = cursor >= anchor
            ? EditorSelection(anchor: anchor, head: end)
            : EditorSelection(anchor: min(anchor + 1, state.text.count), head: cursor)
        state = EditorState(text: state.text, selection: selection, mode: .visual)
    }

    private mutating func move(to position: Int, vertical: Bool = false) {
        let buffer = EditorBuffer(state.text)
        if vertical {
            if desiredColumn == nil { desiredColumn = activeCursor - buffer.starts[buffer.line(at: activeCursor)] }
        } else { desiredColumn = nil }
        let position = buffer.normalCursor(position)
        if state.mode == .visual {
            let anchor = state.selection.head >= state.selection.anchor ? state.selection.anchor : max(0, state.selection.anchor - 1)
            selectVisual(anchor: anchor, cursor: position)
        } else { setNormalCursor(position) }
    }

    private mutating func setNormalCursor(_ position: Int) {
        let cursor = EditorBuffer(state.text).normalCursor(position)
        state = EditorState(text: state.text, selection: .init(anchor: cursor, head: cursor), mode: .normal)
    }

    private mutating func enterInsert(at position: Int) {
        insertStart = state
        desiredColumn = nil
        state = EditorState(text: state.text, selection: .init(anchor: position, head: position), mode: .insert)
    }

    /// Native updates join the insert entry checkpoint, so cw + replacement is
    /// one undo operation. Command-Z closes that group before traversing history;
    /// subsequent native typing starts a new group and invalidates the redo branch.
    private mutating func finishInsert() {
        if let before = insertStart, before.text != state.text {
            undoStack.append(before)
            redoStack.removeAll()
        }
        insertStart = nil
    }

    private mutating func leaveInsert() {
        finishInsert()
        let buffer = EditorBuffer(state.text)
        let row = buffer.line(at: state.cursor)
        setNormalCursor(max(buffer.starts[row], state.cursor - 1))
    }

    private mutating func history(redo: Bool, count: Int) {
        let mode = state.mode == .insert ? EditorMode.insert : .normal
        finishInsert()
        desiredColumn = nil
        for _ in 0..<count {
            let target = redo ? redoStack.popLast() : undoStack.popLast()
            guard let target else { break }
            if redo { undoStack.append(state) } else { redoStack.append(state) }
            state = EditorState(text: target.text, selection: target.selection, mode: mode)
            if mode == .normal { setNormalCursor(state.cursor) }
        }
        insertStart = mode == .insert ? state : nil
    }

    private mutating func lineOperation(_ operation: Character, from first: Int, through last: Int) {
        let buffer = EditorBuffer(state.text)
        let lower = min(first, last)
        let upper = max(first, last)
        let start = buffer.starts[lower]
        let end = upper + 1 < buffer.starts.count ? buffer.starts[upper + 1] : buffer.count
        let contents = buffer.text(in: start..<buffer.ends[upper]) + "\n"
        if operation == "y" {
            register = Register(text: contents, linewise: true)
            setNormalCursor(activeCursor)
            return
        }
        // The last line lacks a following newline, so remove its preceding
        // separator while retaining a canonical newline-terminated yank register.
        let deletionStart = operation != "c" && upper == buffer.starts.count - 1 && lower > 0 ? start - 1 : start
        let deletionEnd = operation == "c" ? buffer.ends[upper] : end
        operate(operation, range: deletionStart..<deletionEnd, linewise: true)
        register = Register(text: contents, linewise: true)
        if operation != "c" {
            let result = EditorBuffer(state.text)
            setNormalCursor(result.firstNonblank(min(lower, result.starts.count - 1)))
        }
    }

    private mutating func operate(_ operation: Character, range: Range<Int>, linewise: Bool) {
        let buffer = EditorBuffer(state.text)
        if operation == "c" { insertStart = state }
        if !range.isEmpty {
            register = Register(text: buffer.text(in: range), linewise: linewise)
            if operation != "y" {
                if operation != "c" { undoStack.append(state) }
                redoStack.removeAll()
                state = EditorState(
                    text: buffer.replacing(range, with: ""),
                    selection: .init(anchor: range.lowerBound, head: range.lowerBound),
                    mode: operation == "c" ? .insert : .normal
                )
            }
        }
        desiredColumn = nil
        if operation == "c" {
            state = EditorState(text: state.text, selection: .init(anchor: range.lowerBound, head: range.lowerBound), mode: .insert)
        } else { setNormalCursor(operation == "y" ? range.lowerBound : state.cursor) }
    }

    private mutating func paste(before: Bool, count: Int) {
        guard let register else { return }
        let buffer = EditorBuffer(state.text)
        let contents = String(repeating: register.text, count: count)
        let cursor = activeCursor
        let row = buffer.line(at: cursor)
        var range: Range<Int>
        var insertion = contents
        var target: Int
        if state.mode == .visual {
            range = state.selection.range
            target = range.lowerBound + max(0, contents.count - 1)
        } else if register.linewise {
            let start = before ? buffer.starts[row] : (row + 1 < buffer.starts.count ? buffer.starts[row + 1] : buffer.count)
            range = start..<start
            if !before && row + 1 == buffer.starts.count {
                // Append a separator, then omit the register's final separator;
                // this retains exactly one newly pasted logical line at EOF.
                insertion = "\n" + String(contents.dropLast())
                target = start + 1
            } else { target = start }
        } else {
            let start = before ? cursor : min(buffer.ends[row], cursor + 1)
            range = start..<start
            target = start + max(0, contents.count - 1)
        }
        guard !insertion.isEmpty || !range.isEmpty else { return }
        undoStack.append(state)
        redoStack.removeAll()
        state = EditorState(text: buffer.replacing(range, with: insertion), selection: .init(anchor: target, head: target), mode: .normal)
        setNormalCursor(target)
        desiredColumn = nil
    }
}
