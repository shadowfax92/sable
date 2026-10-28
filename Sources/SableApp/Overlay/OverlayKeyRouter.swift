import Foundation

/// Panel-level key routing, as a pure function of the overlay phase and the key.
/// `OverlayPanelController`'s local monitor applies the result. The review phase
/// passes everything through, because the native review editor owns its keys,
/// Escape included.
enum OverlayKeyRouter {
    enum Action: Equatable {
        /// Let the key reach the focused control (text fields, the editor, menus).
        case passThrough
        /// Consume silently: no beep, no effect.
        case swallow
        case moveNext
        case movePrevious
        case pick
        /// Escape in the instruction step: back to the picker, or cancel.
        case back
        case cancel
        case primaryAction
        /// Dismiss a finished (copied) interaction without cancelling anything.
        case closeLocally
    }

    struct Key: Equatable {
        var keyCode: UInt16
        /// `charactersIgnoringModifiers`, lowercased.
        var character: String?
        var control: Bool = false
        var command: Bool = false
    }

    private static let escape: UInt16 = 53
    private static let returnKey: UInt16 = 36
    private static let keypadEnter: UInt16 = 76
    private static let downArrow: UInt16 = 125
    private static let upArrow: UInt16 = 126

    static func action(for key: Key, in phase: OverlayModel.Phase) -> Action {
        let isEscape = key.keyCode == escape
        let isReturn = key.keyCode == returnKey || key.keyCode == keypadEnter
        switch phase {
        case .review:
            return .passThrough
        case .picking:
            if isEscape { return .cancel }
            if isReturn { return .pick }
            if key.keyCode == downArrow { return .moveNext }
            if key.keyCode == upArrow { return .movePrevious }
            if key.control, !key.command {
                // Overrides the field's native emacs bindings (⌃K kill-line) here only.
                switch key.character {
                case "j", "n": return .moveNext
                case "k", "p": return .movePrevious
                default: break
                }
            }
            return .passThrough
        case .input:
            return isEscape ? .back : .passThrough
        case .thinking:
            if isEscape { return .cancel }
            return key.command ? .passThrough : .swallow
        case .done:
            if isEscape || isReturn { return .closeLocally }
            return key.command ? .passThrough : .swallow
        case .failure, .error:
            if isEscape { return .cancel }
            if isReturn { return .primaryAction }
            return key.command ? .passThrough : .swallow
        }
    }
}
