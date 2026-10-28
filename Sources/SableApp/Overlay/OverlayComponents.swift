import AppKit
import SwiftUI

/// Behind-window blur plus a contrast tint. It turns opaque under Reduce
/// Transparency. The blur stays `.active` because Sable is usually not the
/// active app while the panel is up (the panel is nonactivating).
struct OverlaySurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            OverlayTheme.panelOpaque
        } else {
            ZStack {
                VisualEffectBackground()
                OverlayTheme.panelTint
            }
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(OverlayTheme.hairline).frame(height: 1)
    }
}

/// "label ⌘X" pair used in every hint bar.
struct KeyHint: View {
    let text: String
    let cap: String

    var body: some View {
        HStack(spacing: 5) {
            Text(cap)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OverlayTheme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(OverlayTheme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OverlayTheme.textTertiary)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// Icon and name of the mode an interaction is using.
struct ModeHeader: View {
    let symbol: String
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OverlayTheme.accentInk)
                .frame(width: 18)
            Text(name.isEmpty ? "Untitled mode" : name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(OverlayTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// One or two dimmed lines of the captured selection. A character count is
/// added when the text is long enough to be truncated, so the user can tell the
/// whole selection was captured.
struct SelectionPreview: View {
    let text: String
    var lineLimit = 1

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        if text.isEmpty {
            Text("No text selected")
                .italic()
                .font(.system(size: 12))
                .foregroundStyle(OverlayTheme.textTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(collapsed)
                    .font(.system(size: 12))
                    .foregroundStyle(OverlayTheme.textSecondary)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if text.count > 120 {
                    Text("· \(Self.countFormatter.string(from: NSNumber(value: text.count)) ?? "\(text.count)") chars")
                        .font(.system(size: 11))
                        .foregroundStyle(OverlayTheme.textTertiary)
                        .fixedSize()
                }
            }
        }
    }

    private var collapsed: String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// Calm progress: a slowly breathing accent dot (static under Reduce Motion).
struct BreathingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(OverlayTheme.accentFill)
            .frame(width: 8, height: 8)
            .opacity(reduceMotion || !dimmed ? 1 : 0.35)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// NSHostingView that accepts the first click, so buttons in the non-key notice
/// pill work without making it key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
