import SableCore
import SwiftUI

/// The review phase: mode header, the native Vim editor, and a footer with the
/// mode pill, pending command and per-mode hints. During a `/` or `?` search the
/// footer becomes Vim's command line (`ReviewSearchField`). Delivery goes through
/// the session (`onReviewDelivery`); nothing here touches the clipboard.
struct ReviewContent: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var session: ReviewSession
    @State private var editorHeight = Self.minimumHeight

    /// Three lines plus insets.
    static let minimumHeight = OverlayTheme.Metric.editorLineHeight * 3 + OverlayTheme.Metric.editorInset * 2

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ModeHeader(symbol: model.modeSymbol, name: model.modeName)
            ReviewEditorView(
                session: session,
                focusNonce: model.focusNonce,
                onContentHeightChange: { height in
                    // Deferred: the report can arrive during a SwiftUI update pass.
                    DispatchQueue.main.async { resize(toContent: height) }
                }
            )
            .frame(height: editorHeight)
            .background(OverlayTheme.editorSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OverlayTheme.hairline, lineWidth: 1)
            )
            ReviewFooter(session: session, isPanelKey: model.isPanelKey, focusNonce: model.focusNonce)
        }
    }

    /// Grows the editor with its text up to the screen-derived cap, then scrolls.
    /// An explicit layout request re-fits the panel, keeping its top edge fixed.
    private func resize(toContent height: CGFloat) {
        let clamped = min(max(height, Self.minimumHeight), max(model.reviewMaxEditorHeight, Self.minimumHeight))
        guard abs(clamped - editorHeight) > 0.5 else { return }
        editorHeight = clamped
        model.requestLayout()
    }
}

private struct ReviewFooter: View {
    @ObservedObject var session: ReviewSession
    let isPanelKey: Bool
    let focusNonce: Int

    var body: some View {
        HStack(spacing: 10) {
            ModePill(state: session.state)
            if let search = session.state.search, search.isActive {
                ReviewSearchBar(session: session, search: search, focusNonce: focusNonce)
                HintRow(hints: OverlayHints.search(search, isPanelKey: isPanelKey))
            } else {
                hintsAndShowcmd
            }
        }
    }

    @ViewBuilder private var hintsAndShowcmd: some View {
        if let hint = session.hint {
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(OverlayTheme.textTertiary)
                .lineLimit(1)
        } else if !session.state.pendingCommand.isEmpty {
            Text(session.state.pendingCommand)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(OverlayTheme.textSecondary)
        }
        Spacer(minLength: 8)
        if session.isDiscardArmed && isPanelKey {
            Text("esc again to discard edits")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OverlayTheme.warn)
        } else {
            // The ⌘⏎ hint names the destination; it is hidden when there is no
            // safe one (⌘⏎ still delivers, and interaction copies and reports).
            HintRow(hints: OverlayHints.review(
                mode: session.state.mode, target: session.target, isPanelKey: isPanelKey
            ))
        }
    }
}

/// `/query▏  2/5`: the prompt from the search direction, the native query field,
/// and the engine's live match status. A no-match status takes the warn tint.
private struct ReviewSearchBar: View {
    @ObservedObject var session: ReviewSession
    let search: EditorSearchState
    let focusNonce: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(ReviewSearchPresentation.prompt(search))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(OverlayTheme.textSecondary)
            ReviewSearchField(session: session, focusNonce: focusNonce)
                .frame(minWidth: 60, maxWidth: .infinity)
            if let status = ReviewSearchPresentation.status(search) {
                Text(status.text)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(status.isWarning ? OverlayTheme.warn : OverlayTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

private struct ModePill: View {
    let label: String
    let mode: EditorMode

    init(state: EditorState) {
        mode = state.mode
        label = Self.label(for: state)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(mode == .visual ? OverlayTheme.accentFill : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel("\(label.capitalized) mode")
    }

    static func label(for state: EditorState) -> String {
        switch state.mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return state.visualSelectionKind == .line ? "VISUAL LINE" : "VISUAL"
        }
    }

    private var foreground: Color {
        switch mode {
        case .normal: return OverlayTheme.textSecondary
        case .insert: return Color.black.opacity(0.82)
        case .visual: return OverlayTheme.accentInk
        }
    }

    private var background: Color {
        switch mode {
        case .normal: return OverlayTheme.chip
        case .insert: return OverlayTheme.accentFill
        case .visual: return Color.clear
        }
    }
}
