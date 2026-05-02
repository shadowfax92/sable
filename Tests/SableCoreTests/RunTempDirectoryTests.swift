import XCTest
@testable import SableCore

final class RunTempDirectoryTests: XCTestCase {
    func testCreatesAndDeletesRunDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let run = try RunTempDirectory(baseDirectory: base)

        XCTAssertTrue(FileManager.default.fileExists(atPath: run.url.path))
        XCTAssertTrue(run.screenshotURL.path.hasSuffix("screenshot.png"))

        try run.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.url.path))
    }
}
