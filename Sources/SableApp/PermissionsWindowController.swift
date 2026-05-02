import AppKit

final class PermissionsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sable Permissions"
        window.center()

        let view = NSStackView()
        view.orientation = .vertical
        view.spacing = 12
        view.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let label = NSTextField(labelWithString: "Sable needs Accessibility and Screen Recording permissions to capture selected text and screenshot context.")
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0

        let accessibilityButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
        let screenButton = NSButton(title: "Open Screen Recording Settings", target: nil, action: nil)

        view.addArrangedSubview(label)
        view.addArrangedSubview(accessibilityButton)
        view.addArrangedSubview(screenButton)
        window.contentView = view

        super.init(window: window)

        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility)
        screenButton.target = self
        screenButton.action = #selector(openScreenRecording)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func openAccessibility() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenRecording() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openSettings(_ raw: String) {
        guard let url = URL(string: raw) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
