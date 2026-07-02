import XCTest
@testable import SableCore

final class ModePickerStateTests: XCTestCase {
    func testConfigureHighlightsInitialModeWhenVisible() {
        let modes = makeModes(["Fix Grammar", "Ask", "Tweet Dax"])
        var state = ModePickerState()

        state.configure(modes: modes, initialModeID: modes[2].id)

        XCTAssertEqual(state.visibleModes, modes)
        XCTAssertEqual(state.highlightedModeID, modes[2].id)
        XCTAssertEqual(state.selectedModeID, modes[2].id)
    }

    func testConfigureFallsBackToFirstModeWhenInitialMissing() {
        let modes = makeModes(["Fix Grammar", "Ask", "Tweet Dax"])
        var state = ModePickerState()

        state.configure(modes: modes, initialModeID: UUID())

        XCTAssertEqual(state.highlightedModeID, modes[0].id)
    }

    func testQueryKeepsHighlightWhenStillVisible() {
        let modes = makeModes(["Tweet Dax", "Tweet Thread", "Ask"])
        var state = ModePickerState(modes: modes, highlightedModeID: modes[1].id)

        state.setQuery("tweet")

        XCTAssertEqual(state.visibleModes, [modes[0], modes[1]])
        XCTAssertEqual(state.highlightedModeID, modes[1].id)
    }

    func testQueryMovesHighlightToFirstVisibleMode() {
        let modes = makeModes(["Tweet Dax", "Translate", "Ask"])
        var state = ModePickerState(modes: modes, highlightedModeID: modes[2].id)

        state.setQuery("tweet")

        XCTAssertEqual(state.visibleModes, [modes[0]])
        XCTAssertEqual(state.highlightedModeID, modes[0].id)
    }

    func testQueryClearsHighlightWhenNothingMatches() {
        let modes = makeModes(["Tweet Dax", "Translate", "Ask"])
        var state = ModePickerState(modes: modes)

        state.setQuery("newsletter")

        XCTAssertTrue(state.visibleModes.isEmpty)
        XCTAssertNil(state.highlightedModeID)
        XCTAssertNil(state.selectedModeID)
    }

    func testNextAndPreviousWrapThroughVisibleModes() {
        let modes = makeModes(["One", "Two", "Three"])
        var state = ModePickerState(modes: modes, highlightedModeID: modes[2].id)

        state.selectNext()
        XCTAssertEqual(state.highlightedModeID, modes[0].id)

        state.selectPrevious()
        XCTAssertEqual(state.highlightedModeID, modes[2].id)
    }

    func testHighlightIgnoresModeOutsideCurrentQuery() {
        let modes = makeModes(["Tweet Dax", "Translate", "Ask"])
        var state = ModePickerState(modes: modes, highlightedModeID: modes[0].id)

        state.setQuery("tweet")
        state.highlight(modes[1].id)

        XCTAssertEqual(state.highlightedModeID, modes[0].id)
    }

    private func makeModes(_ names: [String]) -> [SableMode] {
        names.map {
            SableMode(name: $0, symbol: "sparkles", instruction: "", runtimeID: .claude, model: "sonnet")
        }
    }
}
