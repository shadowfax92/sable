import AppKit
import SableCore

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onReloadConfig: (() -> Void)?
    var onShowPermissions: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onCopyOutput: ((RunRecord) -> Void)?

    private let configLabel = NSTextField(labelWithString: "Config: unknown")
    private let permissionsLabel = NSTextField(labelWithString: "Permissions: unknown")
    private let currentRunLabel = NSTextField(labelWithString: "Current: idle")
    private let tableView = NSTableView()
    private let instructionLabel = NSTextField(labelWithString: "")
    private let selectedTextView = NSTextView()
    private let outputTextView = NSTextView()
    private let screenshotLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy Output", target: nil, action: nil)
    private var records: [RunRecord] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sable"
        window.center()

        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the operational dashboard where Sable shows config, permissions, current run, and history.
    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setStatus(config: String, permissions: String, currentRun: String) {
        configLabel.stringValue = "Config: \(config)"
        permissionsLabel.stringValue = "Permissions: \(permissions)"
        currentRunLabel.stringValue = "Current: \(currentRun)"
    }

    func setRecords(_ records: [RunRecord]) {
        let selectedID = selectedRecord()?.id
        self.records = records
        tableView.reloadData()

        if let selectedID, let index = records.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !records.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            updateDetails(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row), let identifier = tableColumn?.identifier else {
            return nil
        }

        let record = records[row]
        let value: String
        switch identifier.rawValue {
        case "status":
            value = record.status.displayName
        case "time":
            value = Self.timeFormatter.string(from: record.createdAt)
        default:
            value = record.instruction.isEmpty ? "(No instruction)" : record.instruction
        }

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetails(selectedRecord())
    }

    private func buildContent() {
        guard let window else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Sable")
        title.font = .systemFont(ofSize: 24, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "Capture selected text, send it to Claude, and copy the edited result.")
        subtitle.textColor = .secondaryLabelColor

        for label in [configLabel, permissionsLabel, currentRunLabel, screenshotLabel, errorLabel] {
            label.lineBreakMode = .byTruncatingMiddle
        }

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        let reloadButton = NSButton(title: "Reload Config", target: self, action: #selector(reloadConfig))
        let permissionsButton = NSButton(title: "Check Permissions", target: self, action: #selector(showPermissions))
        let clearButton = NSButton(title: "Clear History", target: self, action: #selector(clearHistory))
        copyButton.target = self
        copyButton.action = #selector(copyOutput)
        actionRow.addArrangedSubview(reloadButton)
        actionRow.addArrangedSubview(permissionsButton)
        actionRow.addArrangedSubview(clearButton)
        actionRow.addArrangedSubview(copyButton)

        let statusStack = NSStackView(views: [title, subtitle, configLabel, permissionsLabel, currentRunLabel, actionRow])
        statusStack.orientation = .vertical
        statusStack.spacing = 5

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        configureTable()
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 390).isActive = true

        let detailStack = NSStackView()
        detailStack.orientation = .vertical
        detailStack.spacing = 8
        detailStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)

        instructionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        selectedTextView.isEditable = false
        outputTextView.isEditable = false
        selectedTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        detailStack.addArrangedSubview(instructionLabel)
        detailStack.addArrangedSubview(NSTextField(labelWithString: "Selected Text"))
        detailStack.addArrangedSubview(scrollView(for: selectedTextView, height: 150))
        detailStack.addArrangedSubview(NSTextField(labelWithString: "Output"))
        detailStack.addArrangedSubview(scrollView(for: outputTextView, height: 170))
        detailStack.addArrangedSubview(screenshotLabel)
        detailStack.addArrangedSubview(errorLabel)

        splitView.addArrangedSubview(tableScroll)
        splitView.addArrangedSubview(detailStack)

        root.addArrangedSubview(statusStack)
        root.addArrangedSubview(splitView)
        window.contentView = root

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 390),
        ])

        updateDetails(nil)
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true

        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "Status"
        statusColumn.width = 120

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.title = "Time"
        timeColumn.width = 120

        let instructionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("instruction"))
        instructionColumn.title = "Instruction"
        instructionColumn.width = 240

        tableView.addTableColumn(statusColumn)
        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(instructionColumn)
    }

    private func scrollView(for textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scrollView
    }

    private func selectedRecord() -> RunRecord? {
        let row = tableView.selectedRow
        guard records.indices.contains(row) else {
            return records.first
        }
        return records[row]
    }

    private func updateDetails(_ record: RunRecord?) {
        guard let record else {
            instructionLabel.stringValue = "No runs yet"
            selectedTextView.string = ""
            outputTextView.string = ""
            screenshotLabel.stringValue = "Screenshot: none"
            errorLabel.stringValue = ""
            copyButton.isEnabled = false
            return
        }

        instructionLabel.stringValue = "\(record.status.displayName): \(record.instruction)"
        selectedTextView.string = record.selectedText
        outputTextView.string = record.outputText ?? ""
        screenshotLabel.stringValue = "Screenshot: \(record.screenshotPath ?? "none")"
        errorLabel.stringValue = record.errorMessage.map { "Error: \($0)" } ?? ""
        copyButton.isEnabled = !(record.outputText ?? "").isEmpty
    }

    @objc private func reloadConfig() {
        onReloadConfig?()
    }

    @objc private func showPermissions() {
        onShowPermissions?()
    }

    @objc private func clearHistory() {
        onClearHistory?()
    }

    @objc private func copyOutput() {
        guard let record = selectedRecord() else {
            return
        }
        onCopyOutput?(record)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
