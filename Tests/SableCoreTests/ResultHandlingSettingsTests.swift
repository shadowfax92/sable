import XCTest
@testable import SableCore

final class ResultHandlingSettingsTests: XCTestCase {
    func testLegacyJSONDefaultsToReviewWithoutScreenshotsAndKeepsModes() throws {
        let id = UUID()
        let json = """
        {"modes":[{"id":"\(id)","name":"Email","instruction":"Keep","runtimeID":"claude","model":"sonnet"}],
        "cwd":"~","timeoutSeconds":120,"defaultModeID":"\(id)"}
        """
        let settings = try JSONDecoder().decode(SableSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.resultHandling, .review)
        XCTAssertFalse(settings.attachesScreenshotsForCLI)
        XCTAssertNil(settings.modes[0].resultHandling)
        XCTAssertEqual(settings.resultHandling(for: settings.modes[0]), .review)
        XCTAssertEqual(settings.modes[0].id, id)
        XCTAssertEqual(settings.generation, GenerationSelection(provider: .legacyCLI))
    }

    func testModeOverrideRoundTripsAndResolves() throws {
        let instant = SableMode(name: "Fix", instruction: "Fix", resultHandling: .quickCopy)
        let inherited = SableMode(name: "Ask", instruction: "", requiresInput: true)
        let settings = SableSettings(
            modes: [instant, inherited], resultHandling: .review, attachesScreenshotsForCLI: true
        )

        let data = try JSONEncoder().encode(settings)
        let loaded = try JSONDecoder().decode(SableSettings.self, from: data)

        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.resultHandling(for: loaded.modes[0]), .quickCopy)
        XCTAssertEqual(loaded.resultHandling(for: loaded.modes[1]), .review)
        XCTAssertTrue(loaded.attachesScreenshotsForCLI)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"resultHandling\":null"))
    }

    func testUnknownOrMistypedPreferencesFallBackInsteadOfDroppingSettings() throws {
        let id = UUID()
        let json = """
        {"modes":[{"id":"\(id)","name":"Tweet","instruction":"Keep me","resultHandling":"futureValue"}],
        "resultHandling":"somethingNew","attachesScreenshotsForCLI":"yes"}
        """
        let settings = try JSONDecoder().decode(SableSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.modes[0].id, id)
        XCTAssertEqual(settings.modes[0].instruction, "Keep me")
        XCTAssertNil(settings.modes[0].resultHandling)
        XCTAssertEqual(settings.resultHandling, .review)
        XCTAssertFalse(settings.attachesScreenshotsForCLI)
    }
}
