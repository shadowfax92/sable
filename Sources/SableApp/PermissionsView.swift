import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Themed permissions sheet. Polls the two TCC checks on a light cadence so the
/// rows flip to "Granted" moments after the user toggles Sable in System
/// Settings, without needing to reopen the window.
struct PermissionsView: View {
    @State private var accessibilityOK = AXIsProcessTrusted()
    @State private var screenRecordingOK = CGPreflightScreenCaptureAccess()

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.system(size: 18, weight: .semibold))
                Text("Sable needs Accessibility and Screen Recording to capture selected text and screenshot context.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Read the current text selection.",
                    symbol: "accessibility",
                    granted: accessibilityOK,
                    open: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
                )
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Capture a screenshot for context.",
                    symbol: "camera.viewfinder",
                    granted: screenRecordingOK,
                    open: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
                )
            }

            Text("After toggling Sable in System Settings, status updates here automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 460, height: 320, alignment: .topLeading)
        .background(Theme.Palette.windowBackground)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private func refresh() {
        accessibilityOK = AXIsProcessTrusted()
        screenRecordingOK = CGPreflightScreenCaptureAccess()
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.Palette.chip)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            statusPill

            Button(granted ? "Settings" : "Grant", action: open)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Theme.Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.cardCorner, style: .continuous)
                .stroke(Theme.Palette.cardStroke, lineWidth: 1)
        )
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(granted ? "Granted" : "Needed")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(granted ? Theme.Palette.ok : Theme.Palette.warn)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background((granted ? Theme.Palette.ok : Theme.Palette.warn).opacity(0.12))
        .clipShape(Capsule())
    }
}
