import Foundation
import SableCore
@testable import SableApp
import XCTest

final class GraphemeRangeMapperTests: XCTestCase {
    // e + combining acute (2 UTF-16), woman technologist with skin tone (7), flag (4), CRLF (2).
    private let text = "e\u{301}👩🏽‍💻🇺🇸\r\nx"

    func testGraphemeToUTF16Boundaries() {
        XCTAssertEqual(text.count, 5)
        XCTAssertEqual(GraphemeRangeMapper.utf16Offset(forGrapheme: 0, in: text), 0)
        XCTAssertEqual(GraphemeRangeMapper.utf16Offset(forGrapheme: 1, in: text), 2)
        XCTAssertEqual(GraphemeRangeMapper.utf16Offset(forGrapheme: 2, in: text), 9)
        XCTAssertEqual(GraphemeRangeMapper.utf16Offset(forGrapheme: 3, in: text), 13)
        XCTAssertEqual(GraphemeRangeMapper.utf16Offset(forGrapheme: 4, in: text), 15)
        XCTAssertEqual(GraphemeRangeMapper.utf16Offset(forGrapheme: 99, in: text), text.utf16.count)
        XCTAssertEqual(GraphemeRangeMapper.utf16Offset(forGrapheme: -3, in: text), 0)
    }

    func testUTF16InsideGraphemeRoundsDown() {
        XCTAssertEqual(GraphemeRangeMapper.graphemeOffset(forUTF16: 1, in: text), 0)
        XCTAssertEqual(GraphemeRangeMapper.graphemeOffset(forUTF16: 5, in: text), 1)
        XCTAssertEqual(GraphemeRangeMapper.graphemeOffset(forUTF16: 9, in: text), 2)
        XCTAssertEqual(GraphemeRangeMapper.graphemeOffset(forUTF16: 14, in: text), 3)
        XCTAssertEqual(GraphemeRangeMapper.graphemeOffset(forUTF16: 1_000, in: text), text.count)
    }

    func testRangeRoundTripPreservesDirection() {
        let forward = EditorSelection(anchor: 1, head: 3)
        let range = GraphemeRangeMapper.nsRange(for: forward, in: text)
        XCTAssertEqual(range, NSRange(location: 2, length: 11))
        XCTAssertEqual(GraphemeRangeMapper.selection(for: range, in: text), forward)

        let reverse = EditorSelection(anchor: 3, head: 1)
        XCTAssertEqual(GraphemeRangeMapper.nsRange(for: reverse, in: text), range)
        XCTAssertEqual(GraphemeRangeMapper.selection(for: range, in: text, headAtEnd: false), reverse)
    }
}
