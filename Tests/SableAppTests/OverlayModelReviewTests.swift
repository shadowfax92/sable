import SableCore
@testable import SableApp
import XCTest

@MainActor
final class OverlayModelReviewTests: XCTestCase {
    func testPresentReviewOwnsSessionAndRequestsFocusAndLayout() {
        let model = OverlayModel()
        let id = UUID()
        model.configurePicker(selectedText: "Source", modes: SableSettings.defaultModes, initialModeID: nil, interactionID: id)
        let focus = model.focusNonce
        let layout = model.layoutRequest

        model.presentReview(
            result: "Result",
            target: ReviewTarget(sourceAppName: "Notes", canPasteBack: true),
            engine: ScriptedEngine(initial: "Result", updates: [])
        )

        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.reviewSession?.interactionID, id)
        XCTAssertEqual(model.reviewSession?.originalText, "Result")
        XCTAssertEqual(model.reviewSession?.target.sourceAppName, "Notes")
        XCTAssertEqual(model.focusNonce, focus + 1)
        XCTAssertEqual(model.layoutRequest, layout + 1)
    }

    func testDeliveryReachesCallbackWithEditedText() {
        let model = OverlayModel()
        var received: [ReviewDelivery] = []
        model.onReviewDelivery = { received.append($0) }
        model.configurePicker(selectedText: "", modes: SableSettings.defaultModes, initialModeID: nil)
        let edited = EditorState(text: "Edited")
        model.presentReview(result: "Result", engine: ScriptedEngine(initial: "Result", updates: [
            EditorUpdate(state: edited, effects: [.pasteAndClose("Edited")], disposition: .handled),
        ]))

        model.reviewSession?.send(.key(.enter, modifiers: .command, timestamp: 0))

        XCTAssertEqual(received.map(\.action), [.paste])
        XCTAssertEqual(received.first?.text, "Edited")
        XCTAssertEqual(received.first?.interactionID, model.interactionID)
    }

    func testStaleSessionCannotDeliverAfterInvalidationOrNewInteraction() {
        let model = OverlayModel()
        var received: [ReviewDelivery] = []
        model.onReviewDelivery = { received.append($0) }
        let copy = EditorUpdate(state: EditorState(text: "Old"), effects: [.copyAndClose("Old")], disposition: .handled)

        model.configurePicker(selectedText: "", modes: SableSettings.defaultModes, initialModeID: nil)
        model.presentReview(result: "Old", engine: ScriptedEngine(initial: "Old", updates: [copy]))
        let closedSession = model.reviewSession
        model.invalidateSession()
        closedSession?.send(.key(.enter, timestamp: 0))
        XCTAssertNil(model.reviewSession)
        XCTAssertNil(model.interactionID)

        model.configurePicker(selectedText: "", modes: SableSettings.defaultModes, initialModeID: nil)
        model.presentReview(result: "Old", engine: ScriptedEngine(initial: "Old", updates: [copy]))
        let superseded = model.reviewSession
        model.configurePicker(selectedText: "", modes: SableSettings.defaultModes, initialModeID: nil)
        superseded?.send(.key(.enter, timestamp: 1))

        XCTAssertTrue(received.isEmpty)
    }

    func testSwitchingModeKeepsInteractionButDirectHotkeyStartsOne() {
        let model = OverlayModel()
        let modes = SableSettings.defaultModes
        model.configurePicker(selectedText: "", modes: modes, initialModeID: nil)
        let pickerID = model.interactionID

        model.configure(mode: modes[2], selectedText: "", modes: modes)
        XCTAssertEqual(model.interactionID, pickerID)

        model.invalidateSession()
        model.configure(mode: modes[0], selectedText: "", modes: modes)
        XCTAssertNotNil(model.interactionID)
        XCTAssertNotEqual(model.interactionID, pickerID)
    }
}
