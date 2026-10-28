import AppKit
import SableCore
import SwiftUI

/// History tab: every run newest first, beside the selected run's Original and
/// Result. Records are pushed in by the coordinator; this view never edits them.
/// Status styling comes from the shared `RunStatus` tint/symbol mapping, so new
/// statuses only need that one mapping.
struct HistoryPane: View {
    @EnvironmentObject private var model: MainWindowModel
    @State private var confirmsClear = false

    var body: some View {
        if model.records.isEmpty {
            EmptyHistory()
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $model.selectedRecordID) {
                        ForEach(model.records) { record in
                            HistoryRow(record: record).tag(record.id)
                        }
                    }
                    .listStyle(.sidebar)

                    Divider()
                    HStack {
                        Text(model.records.count == 1 ? "1 run" : "\(model.records.count) runs")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear…") { confirmsClear = true }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(width: 260)

                Divider()

                RunDetail(record: model.selectedRecord) { model.copySelectedOutput() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmsClear) {
                Button("Clear History", role: .destructive) { model.onClearHistory?() }
            } message: {
                Text("Every saved original and result is removed. This can't be undone.")
            }
        }
    }
}

extension RunRecord {
    /// A one-line label for lists and headers: the start of what was rewritten.
    var listTitle: String {
        let firstLine = selectedText
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? "No text captured" : firstLine
    }

    /// "Fix Grammar · ChatGPT · gpt-5", from whichever metadata the run
    /// recorded. Records from before this metadata existed have none, and
    /// that's fine: the line just disappears.
    var originLine: String? {
        let parts = [modeName, provider?.shortTitle, model].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct HistoryRow: View {
    let record: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.listTitle)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: record.status.symbol)
                    .foregroundStyle(record.status.tint)
                if let modeName = record.modeName, !modeName.isEmpty {
                    Text(modeName).lineLimit(1)
                    Text("·")
                }
                Text(record.status.displayName)
                Text("·")
                Text(record.createdAt, style: .time)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyHistory: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No runs yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select text in any app and run a mode. Each original and result is kept here.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RunDetail: View {
    let record: RunRecord?
    let onCopy: () -> Void

    var body: some View {
        if let record {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(for: record)

                    if let error = record.errorMessage, !error.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.Palette.error)
                            Text(error)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12.5))
                    }

                    if !record.instruction.isEmpty {
                        DisclosureGroup("Instruction") {
                            TextPanel(text: record.instruction, placeholder: "")
                                .padding(.top, 6)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }

                    section("Original") {
                        TextPanel(text: record.selectedText, placeholder: "Nothing captured")
                    }

                    section("Result", accessory: {
                        Button("Copy result", action: onCopy)
                            .controlSize(.small)
                            .disabled((record.outputText ?? "").isEmpty)
                    }) {
                        TextPanel(text: record.outputText ?? "", placeholder: "No result")
                    }

                    if let path = record.screenshotPath {
                        HStack(spacing: 8) {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                            Text(path)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a run")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(for record: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.listTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 8) {
                StatusChip(
                    text: record.status.displayName,
                    symbol: record.status.symbol,
                    color: record.status.tint,
                    busy: record.status.isBusy
                )
                Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let origin = record.originLine {
                Text(origin)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func section<Content: View, Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
    }
}
