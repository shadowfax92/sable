import AppKit
import Foundation

public struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    public static func capture(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let copied = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        return ClipboardSnapshot(items: copied)
    }

    /// Restores a previously captured pasteboard state after a cancelled or failed run.
    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let restoredItems = items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
