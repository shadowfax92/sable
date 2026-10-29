import AppKit
@testable import SableApp
import XCTest

/// The Edit menu names AppKit's standard undo/redo actions through
/// ReviewTextView's @objc methods. They must stay the exact one-argument
/// selectors NSWindow handles, or Undo/Redo would stop reaching other text fields.
final class MainMenuSelectorTests: XCTestCase {
    func testUndoRedoSelectorsMatchAppKitWindowActions() {
        let undo = #selector(ReviewTextView.undo(_:))
        let redo = #selector(ReviewTextView.redo(_:))

        XCTAssertEqual(NSStringFromSelector(undo), "undo:")
        XCTAssertEqual(NSStringFromSelector(redo), "redo:")
        XCTAssertTrue(NSWindow.instancesRespond(to: undo))
        XCTAssertTrue(NSWindow.instancesRespond(to: redo))
    }
}
