import SableCore
import SwiftUI

/// Model menu for ChatGPT, fed by the account catalog the coordinator loads.
/// Used for the app-wide choice in Settings and a mode's override in Modes.
/// Only a plan-enabled connection can pick a model; otherwise the menu is
/// disabled and the caption says why. A stored slug is never changed here.
struct ChatGPTModelPicker: View {
    @EnvironmentObject private var model: MainWindowModel
    @Binding var selection: String?
    let defaultTitle: String

    var body: some View {
        let connection = ChatGPTConnectionPresentation(
            status: model.connectionStatus,
            activity: model.connectionActivity,
            issue: model.connectionIssue
        )
        let catalog = model.modelCatalog(for: .chatGPT)

        LabeledContent {
            HStack(spacing: 6) {
                Picker("Model", selection: $selection) {
                    ForEach(ModelMenuEntry.entries(catalog: catalog, selected: selection, defaultTitle: defaultTitle)) { entry in
                        Text(entry.title).tag(entry.slug)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!connection.canChooseModel)

                if catalog == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.onRefreshModels?(.chatGPT)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload models")
                    .disabled(!connection.canChooseModel)
                }
            }
        } label: {
            Text("Model")
            caption(connection: connection, catalog: catalog)
        }
        // Three ways the menu can become loadable while it's on screen: it
        // appears, the connection gains plan usage, or the coordinator resets the
        // catalog to `.idle` in a later main-actor turn (account change, cache
        // invalidation). `requestModelCatalogIfNeeded` sends only while idle, so
        // loading and failed catalogs wait for an explicit ↻.
        .onAppear { requestCatalog(connection) }
        .onChange(of: connection.canChooseModel) { _ in requestCatalog(connection) }
        .onChange(of: catalog == .idle) { _ in requestCatalog(connection) }
    }

    @ViewBuilder
    private func caption(connection: ChatGPTConnectionPresentation, catalog: ModelCatalogState) -> some View {
        if !connection.canChooseModel {
            Text(connection.phase == .usageSharingOff ? "Enable usage sharing to choose a model" : "Sign in to choose a model")
        } else if case .failed(let message) = catalog {
            Text("Couldn't load models. \(message)")
                .foregroundStyle(Theme.Palette.warn)
        } else {
            HStack(spacing: 4) {
                Text("Using ChatGPT plan ·")
                Link("Manage usage", destination: ChatGPTLinks.manageUsage)
            }
        }
    }

    private func requestCatalog(_ connection: ChatGPTConnectionPresentation) {
        if connection.canChooseModel { model.requestModelCatalogIfNeeded(.chatGPT) }
    }
}

/// OpenRouter model slug. Empty stores nil, which uses Sable's default model.
struct OpenRouterModelField: View {
    @Binding var selection: String?

    var body: some View {
        LabeledContent {
            TextField(
                "Model",
                text: Binding(
                    get: { selection ?? "" },
                    set: { value in
                        let slug = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        selection = slug.isEmpty ? nil : slug
                    }
                ),
                prompt: Text(DirectGenerationModelCatalog.defaultOpenRouterModel)
            )
            .labelsHidden()
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 240)
        } label: {
            Text("Model")
            Text("Billed to your OpenRouter account.")
        }
    }
}
