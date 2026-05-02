import AppKit

final class PromptPanelController: NSWindowController, NSTextFieldDelegate {
    private let textField = NSTextField()
    private var completion: ((String?) -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 76),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 76))

        textField.placeholderString = "Ask Sable"
        textField.font = .systemFont(ofSize: 16)
        textField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textField)
        panel.contentView = container

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        super.init(window: panel)
        textField.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Presents the custom instruction panel near the current mouse location.
    func showNearMouse(completion: @escaping (String?) -> Void) {
        self.completion = completion
        guard let window else {
            completion(nil)
            return
        }

        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x - 260, y: mouse.y + 12))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        textField.stringValue = ""
        window.makeFirstResponder(textField)
    }

    override func cancelOperation(_ sender: Any?) {
        closeWith(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let movement = notification.userInfo?["NSTextMovement"] as? Int else {
            return
        }

        if movement == NSReturnTextMovement {
            let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            closeWith(value.isEmpty ? nil : value)
        }
    }

    private func closeWith(_ value: String?) {
        window?.orderOut(nil)
        let current = completion
        completion = nil
        current?(value)
    }
}
