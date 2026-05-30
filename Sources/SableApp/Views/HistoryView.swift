import AppKit
import SableCore
import SwiftUI

struct HistoryPane: View {
    @EnvironmentObject private var model: MainWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PaneHeader(title: "History", subtitle: "Every run Sable has made, newest first.")
                Spacer()
                Button(role: .destructive) {
                    model.onClearHistory?()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.large)
                .disabled(model.records.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider().overlay(Theme.Palette.separator)

            if model.records.isEmpty {
                EmptyHistory()
            } else {
                HStack(spacing: 0) {
                    HistoryList(records: model.records, selectedID: $model.selectedRecordID)
                        .frame(width: 300)
                    Divider().overlay(Theme.Palette.separator)
                    RunDetail(record: model.selectedRecord, onCopy: { model.copySelectedOutput() })
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct HistoryList: View {
    let records: [RunRecord]
    @Binding var selectedID: RunRecord.ID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(records) { record in
                    HistoryRow(record: record, isSelected: record.id == selectedID)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = record.id }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.sidebarBackground)
    }
}

private struct HistoryRow: View {
    let record: RunRecord
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: record.status.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(record.status.tint)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.instruction.isEmpty ? "(No instruction)" : record.instruction)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.time.string(from: record.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(record.status.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(record.status.tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metric.rowCorner, style: .continuous)
                .fill(isSelected ? Theme.Palette.rowSelected : Color.clear)
        )
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct EmptyHistory: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No runs yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Trigger a mode on some selected text to see it here.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RunDetail: View {
    let record: RunRecord?
    let onCopy: () -> Void

    var body: some View {
        Group {
            if let record {
                content(for: record)
            } else {
                EmptyDetail()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.windowBackground)
    }

    private func content(for record: RunRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(for: record)

                if let error = record.errorMessage, !error.isEmpty {
                    ErrorBanner(message: error)
                }

                section(title: "Selected text") {
                    CodeBlock(text: record.selectedText, minHeight: 110, placeholder: "Nothing captured")
                }

                section(title: "Output", accessory: {
                    Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                        .controlSize(.small)
                        .disabled((record.outputText ?? "").isEmpty)
                }) {
                    CodeBlock(text: record.outputText ?? "", minHeight: 150, placeholder: "No output")
                }

                if let path = record.screenshotPath {
                    ScreenshotFooter(path: path)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for record: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(record.instruction.isEmpty ? "(No instruction)" : record.instruction)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusChip(text: record.status.displayName, symbol: record.status.symbol, color: record.status.tint, busy: record.status.isBusy)
            }
            Text(Self.timestamp.string(from: record.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View, Accessory: View>(
        title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                accessory()
            }
            content()
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Pick a run")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.error)
            Text(message)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.Palette.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous))
    }
}

private struct ScreenshotFooter: View {
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 11))
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
    }
}
