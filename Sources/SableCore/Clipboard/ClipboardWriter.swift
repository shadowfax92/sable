import AppKit
import Foundation

public struct ClipboardWriter {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Returns the ownership receipt, rather than reading changeCount afterward:
    /// a user copy racing the write must never become our paste permission.
    /// A failed write remains recoverable in History.
    @discardableResult
    public func write(_ text: String) -> Int? {
        let ownership = pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string) ? ownership : nil
    }
}
