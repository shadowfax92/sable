import XCTest
@testable import SableCore

final class HotkeyParserTests: XCTestCase {
    func testParsesModifiersAndKey() throws {
        let hotkey = try HotkeyParser.parse("ctrl+option+cmd+k")
        XCTAssertEqual(hotkey.key, "k")
        XCTAssertEqual(hotkey.modifiers, [.control, .option, .command])
    }

    func testParsesAliases() throws {
        let hotkey = try HotkeyParser.parse("control+alt+command+j")
        XCTAssertEqual(hotkey.key, "j")
        XCTAssertEqual(hotkey.modifiers, [.control, .option, .command])
    }

    func testRejectsMissingKey() {
        XCTAssertThrowsError(try HotkeyParser.parse("ctrl+option")) { error in
            XCTAssertEqual(error as? SableError, .invalidConfig("hotkey must contain exactly one non-modifier key"))
        }
    }
}
