import SableCore
import SwiftUI

enum OverlayFocusField: Hashable {
    case picker
    case input
}

/// Renders the floating panel: one compact view per phase inside a shared
/// glass surface. Keys are routed by `OverlayPanelController`'s monitor; this
/// view only owns text-field focus.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var focusedField: OverlayFocusField?

    var body: some View {
        content
            .opacity(isDimmed ? 0.55 : 1)
            .padding(OverlayTheme.Metric.padding)
            .frame(width: OverlayTheme.Metric.width, alignment: .leading)
            .background(OverlaySurface())
            .clipShape(RoundedRectangle(cornerRadius: OverlayTheme.Metric.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OverlayTheme.Metric.corner, style: .continuous)
                    .stroke(OverlayTheme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
            .padding(OverlayTheme.Metric.shadowMargin)
            .onAppear { syncFocus() }
            .onChange(of: model.phase) { _ in syncFocus() }
            .onChange(of: model.focusNonce) { _ in syncFocus() }
    }

    /// Running and review dim while the panel isn't key (the user clicked away).
    private var isDimmed: Bool {
        guard !model.isPanelKey else { return false }
        return model.phase == .thinking || model.phase == .review
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .picking:
            PickerContent(model: model, focus: $focusedField)
        case .input:
            InstructionContent(model: model, focus: $focusedField)
        case .thinking:
            RunningContent(model: model)
        case .review:
            if let session = model.reviewSession {
                ReviewContent(model: model, session: session)
            }
        case let .done(text):
            CopiedContent(text: text)
        case .failure, .error:
            if let failure = model.currentFailure {
                FailureContent(failure: failure, onPrimary: { model.performFailureAction() })
            }
        }
    }

    private func syncFocus() {
        let target: OverlayFocusField?
        switch model.phase {
        case .picking: target = .picker
        case .input: target = .input
        default: target = nil
        }
        guard let target else {
            focusedField = nil
            return
        }
        // Deferred so the assertion lands after the panel has become key on first show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            switch (target, model.phase) {
            case (.picker, .picking), (.input, .input):
                focusedField = target
            default:
                break
            }
        }
    }
}
