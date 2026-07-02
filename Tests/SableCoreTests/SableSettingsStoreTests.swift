import XCTest
@testable import SableCore

final class SableSettingsStoreTests: XCTestCase {
    func testLoadSeedsStandardSettingsAndPersists() throws {
        let url = try temporaryFile()
        let store = SableSettingsStore(url: url)

        let loaded = try store.load()

        XCTAssertEqual(loaded.modes.count, SableSettings.defaultModes.count)
        XCTAssertNotNil(loaded.defaultMode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "seed should be written so mode ids stay stable")
    }

    func testSeededModeIDsStayStableAcrossLoads() throws {
        let url = try temporaryFile()
        let store = SableSettingsStore(url: url)

        let first = try store.load()
        let second = try store.load()

        XCTAssertEqual(first.modes.map(\.id), second.modes.map(\.id))
    }

    func testRoundTripsCustomSettings() throws {
        let url = try temporaryFile()
        let store = SableSettingsStore(url: url)
        let mode = SableMode(
            name: "Translate",
            symbol: "globe",
            instruction: "Translate to French.",
            runtimeID: .codex,
            model: "gpt-5.5",
            requiresInput: true
        )
        let settings = SableSettings(
            modes: [mode],
            runtimePaths: RuntimeSettings(claudePath: "/bin/claude", codexPath: "/bin/codex"),
            cwd: "~/work",
            timeoutSeconds: 90,
            defaultModeID: mode.id
        )

        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
    }

    func testDefaultModeFallsBackToFirstWhenIDMissing() {
        let settings = SableSettings(modes: SableSettings.defaultModes, defaultModeID: UUID())
        XCTAssertEqual(settings.defaultMode, settings.modes.first)
    }

    func testRoundTripsMoreThanSixModes() throws {
        let url = try temporaryFile()
        let store = SableSettingsStore(url: url)
        let modes = (0..<12).map {
            SableMode(name: "Mode \($0)", symbol: "sparkles", instruction: "Rewrite \($0).")
        }
        let settings = SableSettings(modes: modes, defaultModeID: modes[7].id)

        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
    }

    func testModeSearchBlankQueryPreservesOrder() {
        let modes = [
            SableMode(name: "Tweet Dax", symbol: "quote.bubble", instruction: "", model: "sonnet"),
            SableMode(name: "Translate", symbol: "globe", instruction: "", runtimeID: .codex, model: "gpt-5.3-codex"),
        ]

        XCTAssertEqual(ModeSearch.filter(modes, query: ""), modes)
        XCTAssertEqual(ModeSearch.filter(modes, query: "   "), modes)
    }

    func testModeSearchMatchesNameSymbolRuntimeAndModel() {
        let tweet = SableMode(name: "Tweet Dax", symbol: "quote.bubble", instruction: "", model: "sonnet")
        let translate = SableMode(
            name: "Translate",
            symbol: "globe",
            instruction: "",
            runtimeID: .codex,
            model: "gpt-5.3-codex"
        )
        let modes = [tweet, translate]

        XCTAssertEqual(ModeSearch.filter(modes, query: "tweet"), [tweet])
        XCTAssertEqual(ModeSearch.filter(modes, query: "globe"), [translate])
        XCTAssertEqual(ModeSearch.filter(modes, query: "codex"), [translate])
        XCTAssertEqual(ModeSearch.filter(modes, query: "SONNET"), [tweet])
    }

    func testModeSearchRequiresEveryQueryToken() {
        let tweet = SableMode(name: "Tweet Dax", symbol: "quote.bubble", instruction: "", model: "sonnet")
        let newsletter = SableMode(name: "Tweet Newsletter", symbol: "envelope", instruction: "", model: "opus")

        XCTAssertEqual(ModeSearch.filter([tweet, newsletter], query: "tweet sonnet"), [tweet])
        XCTAssertEqual(ModeSearch.filter([tweet, newsletter], query: "tweet haiku"), [])
    }

    private func temporaryFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }
}
