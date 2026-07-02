import KeyboardShortcuts
import SableCore
import SwiftUI

private let modeSymbolChoices = [
    "wand.and.stars", "text.badge.checkmark", "scissors", "sparkles",
    "globe", "text.append", "list.bullet", "quote.bubble",
    "textformat", "lightbulb", "bolt", "envelope",
]

struct ModesPane: View {
    @EnvironmentObject private var model: MainWindowModel
    @State private var expandedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    PaneHeader(
                        title: "Modes",
                        subtitle: "Reusable transformations. Search them from the picker or assign direct shortcuts."
                    )
                    Spacer()
                    Button(action: addMode) {
                        Label("Create mode", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                ForEach($model.settings.modes) { $mode in
                    ModeCard(
                        mode: $mode,
                        options: model.modelOptions(for: mode.runtimeID, current: mode.model),
                        isExpanded: expandedID == mode.id,
                        isDefault: model.settings.defaultModeID == mode.id,
                        canDelete: model.settings.modes.count > 1,
                        onToggle: { toggle(mode.id) },
                        onSetDefault: { model.settings.defaultModeID = mode.id },
                        onDelete: { delete(mode.id) }
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addMode() {
        let mode = SableMode(name: "New Mode", symbol: "wand.and.stars", instruction: "", requiresInput: false)
        model.settings.modes.append(mode)
        expandedID = mode.id
    }

    private func delete(_ id: UUID) {
        model.settings.modes.removeAll { $0.id == id }
        if model.settings.defaultModeID == id {
            model.settings.defaultModeID = model.settings.modes.first?.id
        }
        if expandedID == id { expandedID = nil }
    }

    private func toggle(_ id: UUID) {
        expandedID = expandedID == id ? nil : id
    }
}

private struct ModeCard: View {
    @Binding var mode: SableMode
    let options: [RuntimeModelOption]
    let isExpanded: Bool
    let isDefault: Bool
    let canDelete: Bool
    let onToggle: () -> Void
    let onSetDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: isExpanded ? 16 : 0) {
                header
                if isExpanded {
                    Divider().overlay(Theme.Palette.separator)
                    editor
                }
            }
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.name.isEmpty ? "Untitled mode" : mode.name)
                            .font(.system(size: 14, weight: .semibold))
                        if isDefault {
                            Text("DEFAULT")
                                .font(.system(size: 9, weight: .bold))
                                .kerning(0.5)
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(RuntimeDefinitions.definition(for: mode.runtimeID).displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.Palette.chip)
                    .clipShape(Capsule())

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let kind = mode.requiresInput ? "Asks for instruction" : "Runs instantly"
        let label = options.first { $0.id == mode.model }?.label ?? mode.model
        return "\(kind) · \(label)"
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                symbolPicker
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Name")
                    TextField("Mode name", text: $mode.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Instruction")
                MultilineField(
                    text: $mode.instruction,
                    placeholder: "Describe what this mode should do to the selected text…"
                )
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Harness")
                    RuntimePicker(runtime: $mode.runtimeID, model: $mode.model)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Model")
                    ModelPicker(options: options, model: $mode.model)
                }
            }

            FieldRow(
                title: "Ask for an instruction",
                help: "Show a text field in the popup and wait for ⏎ before running."
            ) {
                Toggle("", isOn: $mode.requiresInput).labelsHidden()
            }

            FieldRow(title: "Shortcut", help: "Optional direct shortcut for this mode.") {
                HotkeyRecorder(name: .mode(mode.id))
            }

            Divider().overlay(Theme.Palette.separator)

            HStack {
                Button(action: onSetDefault) {
                    Label(isDefault ? "Initial picker mode" : "Set as initial", systemImage: isDefault ? "star.fill" : "star")
                }
                .controlSize(.small)
                .disabled(isDefault)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(!canDelete)
            }
        }
    }

    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Icon")
            Menu {
                ForEach(modeSymbolChoices, id: \.self) { symbol in
                    Button { mode.symbol = symbol } label: {
                        Label(symbol, systemImage: symbol)
                    }
                }
            } label: {
                Image(systemName: mode.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 28)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 52)
            .padding(.horizontal, 4)
            .background(Theme.Palette.code)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.Palette.codeStroke, lineWidth: 1)
            )
        }
    }
}

/// TextEditor with a placeholder overlay; Enter inserts a newline (it isn't a submit).
struct MultilineField: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 90

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .frame(minHeight: minHeight)
        }
        .background(Theme.Palette.code)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous)
                .stroke(Theme.Palette.codeStroke, lineWidth: 1)
        )
    }
}
