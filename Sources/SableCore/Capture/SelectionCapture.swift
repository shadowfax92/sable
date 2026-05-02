import AppKit
import ApplicationServices
import Foundation

public struct SelectionCapture {
    public struct Result {
        public let text: String
        public let clipboardSnapshot: ClipboardSnapshot?
    }

    public init() {}

    /// Captures selected text from the focused app, falling back to a temporary copy action.
    public func capture() async throws -> Result {
        if let text = accessibilitySelectedText(), !text.isEmpty {
            return Result(text: text, clipboardSnapshot: nil)
        }

        let snapshot = ClipboardSnapshot.capture()
        let beforeChangeCount = NSPasteboard.general.changeCount
        sendCopyShortcut()

        try await Task.sleep(nanoseconds: 150_000_000)

        guard NSPasteboard.general.changeCount != beforeChangeCount,
              let copied = NSPasteboard.general.string(forType: .string),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            snapshot.restore()
            throw SableError.noSelectedText
        }

        return Result(text: copied, clipboardSnapshot: snapshot)
    }

    private func accessibilitySelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused else {
            return nil
        }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else {
            return nil
        }

        return selected as? String
    }

    private func sendCopyShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
