import KeyboardShortcuts
import SableCore
import SwiftUI

private let modeSymbolChoices = [
    "wand.and.stars", "text.badge.checkmark", "scissors", "sparkles",
    "globe", "text.append", "list.bullet", "quote.bubble",
    "textformat", "lightbulb", "bolt", "envelope",
]

/// Modes tab: the ordered mode list beside the selected mode's editor. List
/// order is the picker order. Every edit writes straight into
/// `model.settings.modes`, which autosaves; mode ids are never regenerated
/// because hotkeys and the initial-mode setting are keyed by them.
struct ModesPane: View {
    @EnvironmentObject private var model: MainWindowModel
    @State private var selectedID: UUID?
    @State private var pendingDeletion: SableMode?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(model.settings.modes) { mode in
                        ModeRow(mode: mode, isInitial: model.settings.defaultModeID == mode.id)
                            .tag(mode.id)
                    }
                    .onMove { model.settings.modes.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.sidebar)

                Divider()
                HStack(spacing: 2) {
                    Button(action: addMode) {
                        Image(systemName: "plus").frame(width: 22, height: 20)
                    }
                    .help("New mode")
                    Button {
                        pendingDeletion = selectedID.flatMap { model.settings.mode(withID: $0) }
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 20)
                    }
                    .help("Delete mode")
                    .disabled(selectedID == nil || model.settings.modes.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .frame(width: 220)

            Divider()

            Group {
                if let id = selectedID, let mode = binding(for: id) {
                    ModeDetail(mode: mode)
                        .id(id)
                } else {
                    Text("Select a mode")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedID == nil { selectedID = model.settings.defaultMode?.id }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { mode in
            Button("Delete", role: .destructive) { delete(mode.id) }
        } message: { _ in
            Text("Its instruction and shortcut are removed. This can't be undone.")
        }
    }

    /// Looks the mode up by id on every access. An index-based binding would
    /// write to the wrong mode, or crash, after a delete or reorder.
    private func binding(for id: UUID) -> Binding<SableMode>? {
        guard let initial = model.settings.mode(withID: id) else { return nil }
        return Binding(
            get: { model.settings.mode(withID: id) ?? initial },
            set: { updated in
                guard let index = model.settings.modes.firstIndex(where: { $0.id == id }) else { return }
                model.settings.modes[index] = updated
            }
        )
    }

    private func addMode() {
        let mode = SableMode(name: "New Mode", symbol: "wand.and.stars", instruction: "", requiresInput: false)
        model.settings.modes.append(mode)
        selectedID = mode.id
    }

    private func delete(_ id: UUID) {
        guard model.settings.modes.count > 1,
              let index = model.settings.modes.firstIndex(where: { $0.id == id }) else { return }
        model.settings.modes.remove(at: index)
        if model.settings.defaultModeID == id {
            model.settings.defaultModeID = model.settings.modes.first?.id
        }
        // A registered global shortcut keeps swallowing its key combo even after
        // the mode is gone, so release it with the mode.
        KeyboardShortcuts.reset(.mode(id))
        let neighbor = min(index, model.settings.modes.count - 1)
        selectedID = model.settings.modes[neighbor].id
    }
}

private struct ModeRow: View {
    let mode: SableMode
    let isInitial: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mode.symbol)
                .foregroundStyle(Theme.Accent.ink)
                .frame(width: 18)
            Text(mode.name.isEmpty ? "Untitled mode" : mode.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isInitial {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("The mode picker starts on this mode")
            }
        }
    }
}

/// Editor for one mode. Provider and model overrides sit behind a collapsed
/// disclosure because most modes inherit Settings. The legacy harness/model
/// pickers appear only when the mode actually resolves to the CLI, and direct
/// providers read `mode.generation.model`, never the CLI alias in `mode.model`.
private struct ModeDetail: View {
    @EnvironmentObject private var model: MainWindowModel
    @Binding var mode: SableMode
    @State private var showsProvider = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $mode.name)
                Picker("Icon", selection: $mode.symbol) {
                    ForEach(symbolChoices, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }
                Toggle(isOn: $mode.requiresInput) {
                    Text("Ask for an instruction")
                    Text("Shows a text field and waits for ⏎ before rewriting.")
                }
                LabeledContent("Shortcut") {
                    HotkeyRecorder(name: .mode(mode.id))
                }
                LabeledContent("Mode picker") {
                    if model.settings.defaultModeID == mode.id {
                        Text("Starts here").foregroundStyle(.secondary)
                    } else {
                        Button("Start here") { model.settings.defaultModeID = mode.id }
                    }
                }
            }

            Section("Instruction") {
                MultilineField(
                    text: $mode.instruction,
                    placeholder: "Describe what this mode should do to the selected text…"
                )
            }

            Section {
                Picker("After a rewrite", selection: $mode.resultHandling) {
                    Text("Use default (\(model.settings.resultHandling.title))").tag(ResultHandling?.none)
                    Divider()
                    ForEach(ResultHandling.allCases, id: \.self) { handling in
                        Text(handling.title).tag(ResultHandling?.some(handling))
                    }
                }
            }

            Section {
                DisclosureGroup("Provider & model", isExpanded: $showsProvider) {
                    providerRows
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Keeps a symbol that isn't in the curated list (from an older version or a
    /// hand-edited settings file) selectable instead of rendering a blank menu.
    private var symbolChoices: [String] {
        modeSymbolChoices.contains(mode.symbol) ? modeSymbolChoices : [mode.symbol] + modeSymbolChoices
    }

    @ViewBuilder
    private var providerRows: some View {
        let effective = model.settings.generationSelection(for: mode)

        Picker("Provider", selection: Binding(
            get: { ModeProviderChoice(mode) },
            set: { $0.apply(to: &mode) }
        )) {
            Text("Use default (\(model.settings.generation.provider.settingsTitle))")
                .tag(ModeProviderChoice.inherit)
            Divider()
            ForEach(GenerationProvider.settingsOrder, id: \.self) { provider in
                Text(provider.settingsTitle).tag(ModeProviderChoice.provider(provider))
            }
        }

        switch effective.provider {
        case .legacyCLI:
            LabeledContent("Harness") {
                RuntimePicker(runtime: $mode.runtimeID, model: $mode.model)
            }
            LabeledContent("Model") {
                ModelPicker(
                    options: model.modelOptions(for: mode.runtimeID, current: mode.model),
                    model: $mode.model
                )
            }
        case .chatGPT, .openRouter:
            if mode.generation == nil {
                Text("Uses the model chosen in Settings.")
                    .foregroundStyle(.secondary)
            } else if effective.provider == .chatGPT {
                ChatGPTModelPicker(selection: overrideModel, defaultTitle: "Account default")
            } else {
                OpenRouterModelField(selection: overrideModel)
            }
        }
    }

    /// The override's model. Only reachable while `mode.generation` is set.
    private var overrideModel: Binding<String?> {
        Binding(
            get: { mode.generation?.model },
            set: { mode.generation?.model = $0 }
        )
    }
}

extension ResultHandling {
    var title: String {
        switch self {
        case .review: return "Review in editor"
        case .quickCopy: return "Copy immediately"
        }
    }
}

/// TextEditor with a placeholder overlay; Enter inserts a newline (it isn't a submit).
struct MultilineField: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 110

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
        }
    }
}
