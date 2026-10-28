import AppKit
import Foundation

public struct ClipboardWriter {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Delivery must know whether the clipboard accepted the final buffer before
    /// it posts any paste key. A failed write remains recoverable in History.
    @discardableResult
    public func write(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
