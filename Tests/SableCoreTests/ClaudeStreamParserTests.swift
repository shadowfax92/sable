import XCTest
@testable import SableCore

final class ClaudeStreamParserTests: XCTestCase {
    func testExtractsResultFromStreamJsonLine() throws {
        let stdout = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"result","result":"Corrected text.","is_error":false}

        """

        XCTAssertEqual(try ClaudeStreamParser.extractResultText(from: stdout), "Corrected text.")
    }

    func testExtractsTopLevelResultJson() throws {
        let stdout = #"{"result":"Corrected text.","is_error":false}"#
        XCTAssertEqual(try ClaudeStreamParser.extractResultText(from: stdout), "Corrected text.")
    }

    func testThrowsWhenResultIsMissing() {
        XCTAssertThrowsError(try ClaudeStreamParser.extractResultText(from: #"{"type":"system"}"#)) { error in
            XCTAssertEqual(error as? SableError, .claudeResultMissing)
        }
    }

    func testThrowsOnClaudeErrorResult() {
        let stdout = #"{"type":"result","is_error":true,"result":"Bad request"}"#
        XCTAssertThrowsError(try ClaudeStreamParser.extractResultText(from: stdout)) { error in
            XCTAssertEqual(error as? SableError, .claudeFailed("Bad request"))
        }
    }
}
