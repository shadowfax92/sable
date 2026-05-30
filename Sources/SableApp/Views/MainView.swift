import KeyboardShortcuts
import SableCore
import SwiftUI

/// App shell: a Superwhisper-style left nav rail and a routed content area.
struct MainView: View {
    @EnvironmentObject private var model: MainWindowModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider().overlay(Theme.Palette.separator)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Palette.windowBackground)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Theme.Palette.windowBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .home: HomePane()
        case .modes: ModesPane()
        case .history: HistoryPane()
        case .settings: SettingsPane()
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            brand
                .padding(.top, 30)
                .padding(.bottom, 16)
                .padding(.horizontal, 12)

            ForEach(NavSection.allCases) { section in
                NavRow(
                    section: section,
                    isSelected: model.section == section,
                    action: { model.section = section }
                )
            }

            Spacer()

            if !model.accessibilityOK {
                permissionsNote
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: Theme.Metric.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.sidebarBackground)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("Sable")
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private var permissionsNote: some View {
        Button {
            model.section = .settings
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text("Accessibility needed")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.warn)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.Palette.warn.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }
}

private struct NavRow: View {
    let section: NavSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.Palette.rowSelected : (hovering ? Theme.Palette.chip : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Home

private struct HomePane: View {
    @EnvironmentObject private var model: MainWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(
                    title: "Welcome to Sable",
                    subtitle: "Select text anywhere, press a mode's shortcut, and let the agent rewrite it."
                )

                statusCard
                getStartedCard
                howItWorksCard
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(text: "Status")
                    Spacer()
                    let visual = RunVisual.from(model.currentRun)
                    StatusChip(text: model.currentRun, symbol: visual.symbol, color: visual.color, busy: visual.busy)
                }
                Divider().overlay(Theme.Palette.separator)
                HStack(spacing: 10) {
                    healthChip(ok: model.accessibilityOK, label: "Accessibility")
                    healthChip(ok: model.screenRecordingOK, label: "Screen Recording")
                    Spacer()
                    if let mode = model.settings.defaultMode {
                        HStack(spacing: 6) {
                            Image(systemName: mode.symbol).font(.system(size: 11, weight: .medium))
                            Text("Default: \(mode.name)").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func healthChip(ok: Bool, label: String) -> some View {
        StatusChip(
            text: label,
            symbol: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            color: ok ? Theme.Palette.ok : Theme.Palette.warn
        )
    }

    private var getStartedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Get started")
                    .padding(.bottom, 6)
                GetStartedRow(symbol: "wand.and.stars", title: "Create or edit a mode", detail: "Tune the instruction, model, and shortcut.") {
                    model.section = .modes
                }
                Divider().overlay(Theme.Palette.separator)
                GetStartedRow(symbol: "keyboard", title: "Set your shortcuts", detail: "Pick a hotkey for each mode and the quick popup.") {
                    model.section = .settings
                }
                Divider().overlay(Theme.Palette.separator)
                GetStartedRow(symbol: "lock.shield", title: "Grant permissions", detail: "Accessibility lets Sable read your selection.") {
                    model.section = .settings
                }
            }
        }
    }

    private var howItWorksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "How it works")
                howRow(number: "1", text: "Select text in any app.")
                howRow(number: "2", text: "Press a mode's shortcut, or the quick popup shortcut.")
                howRow(number: "3", text: "Type an optional instruction, then press ⏎.")
                howRow(number: "4", text: "The rewrite lands on your clipboard — paste it back.")
            }
        }
    }

    private func howRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GetStartedRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovering ? Theme.Palette.chip : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
