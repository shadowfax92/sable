import AppKit
import XCTest
@testable import SableCore

final class ClipboardSnapshotTests: XCTestCase {
    func testRestoresStringPasteboardItem() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("changed", forType: .string)

        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testClipboardWriterWritesPlainText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        ClipboardWriter(pasteboard: pasteboard).write("replacement")
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }
}
