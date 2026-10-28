import SableCore
@testable import SableApp
import XCTest

@MainActor
final class ReviewSessionTests: XCTestCase {
    func testCopyAndPasteDeliverFinalEditedTextOnce() {
        let id = UUID()
        var deliveries: [ReviewDelivery] = []
        let edited = EditorState(text: "Edited")
        let engine = ScriptedEngine(initial: "Original", updates: [
            EditorUpdate(state: edited, effects: [.copyAndClose("Edited")], disposition: .handled),
            EditorUpdate(state: edited, effects: [.pasteAndClose("Edited")], disposition: .handled),
        ])
        let session = ReviewSession(interactionID: id, text: "Original", target: ReviewTarget(), engine: engine) {
            deliveries.append($0)
        }

        XCTAssertEqual(session.send(.key(.enter, timestamp: 1)), .handled)
        XCTAssertNil(session.send(.key(.enter, modifiers: .command, timestamp: 2)))

        XCTAssertEqual(deliveries, [ReviewDelivery(interactionID: id, action: .copy, text: "Edited")])
        XCTAssertEqual(session.state, edited)
        XCTAssertTrue(session.isFinished)
    }

    func testUneditedCancelDiscardsImmediately() {
        var deliveries: [ReviewDelivery] = []
        let state = EditorState(text: "Result")
        let engine = ScriptedEngine(initial: "Result", updates: [
            EditorUpdate(state: state, effects: [.cancel], disposition: .handled),
        ])
        let session = ReviewSession(interactionID: UUID(), text: "Result", target: ReviewTarget(), engine: engine) {
            deliveries.append($0)
        }

        session.send(.key(.escape, timestamp: 1))

        XCTAssertEqual(deliveries.map(\.action), [.discard])
        XCTAssertEqual(deliveries.first?.text, "Result")
    }

    func testEditedCancelArmsThenDiscardsWithinWindow() {
        var clock: TimeInterval = 10
        var deliveries: [ReviewDelivery] = []
        let edited = EditorState(text: "Result, edited")
        let cancel = EditorUpdate(state: edited, effects: [.cancel], disposition: .handled)
        let engine = ScriptedEngine(initial: "Result", updates: [cancel, cancel])
        let session = ReviewSession(
            interactionID: UUID(), text: "Result", target: ReviewTarget(), engine: engine,
            now: { clock }
        ) { deliveries.append($0) }

        session.send(.key(.escape, timestamp: 1))
        XCTAssertTrue(session.isDiscardArmed)
        XCTAssertTrue(deliveries.isEmpty)

        clock += 1
        session.send(.key(.escape, timestamp: 2))
        XCTAssertEqual(deliveries.map(\.action), [.discard])
        XCTAssertEqual(deliveries.first?.text, "Result, edited")
    }

    func testArmedDiscardExpiresAndRearms() {
        var clock: TimeInterval = 0
        var deliveries: [ReviewDelivery] = []
        let edited = EditorState(text: "Changed")
        let cancel = EditorUpdate(state: edited, effects: [.cancel], disposition: .handled)
        let move = EditorUpdate(state: edited, disposition: .handled)
        let engine = ScriptedEngine(initial: "Original", updates: [cancel, cancel, cancel, move, cancel])
        let session = ReviewSession(
            interactionID: UUID(), text: "Original", target: ReviewTarget(), engine: engine,
            now: { clock }
        ) { deliveries.append($0) }

        session.send(.key(.escape, timestamp: 0))
        clock += ReviewSession.discardConfirmationWindow + 0.1
        session.send(.key(.escape, timestamp: 2)) // expired: re-arms instead of discarding
        XCTAssertTrue(session.isDiscardArmed)

        clock += 0.2
        session.send(.key(.escape, timestamp: 3)) // within the new window
        XCTAssertEqual(deliveries.map(\.action), [.discard])
    }

    func testNonCancelEventDisarmsPendingDiscard() {
        var deliveries: [ReviewDelivery] = []
        let edited = EditorState(text: "Changed")
        let engine = ScriptedEngine(initial: "Original", updates: [
            EditorUpdate(state: edited, effects: [.cancel], disposition: .handled),
            EditorUpdate(state: edited, disposition: .handled),
            EditorUpdate(state: edited, effects: [.cancel], disposition: .handled),
        ])
        let session = ReviewSession(
            interactionID: UUID(), text: "Original", target: ReviewTarget(), engine: engine,
            now: { 0 }
        ) { deliveries.append($0) }

        session.send(.key(.escape, timestamp: 0))
        session.send(.key(.character("l"), timestamp: 0.1))
        XCTAssertFalse(session.isDiscardArmed)
        session.send(.key(.escape, timestamp: 0.2))

        XCTAssertTrue(deliveries.isEmpty, "a fresh arm is required after another command")
        XCTAssertTrue(session.isDiscardArmed)
    }

    func testEngineFailureLeavesStateAndDeliversNothing() {
        var deliveries: [ReviewDelivery] = []
        let engine = ScriptedEngine(initial: "Result", updates: [])
        let session = ReviewSession(interactionID: UUID(), text: "Result", target: ReviewTarget(), engine: engine) {
            deliveries.append($0)
        }

        XCTAssertNil(session.send(.key(.enter, timestamp: 0)))
        XCTAssertEqual(session.state, EditorState(text: "Result"))
        XCTAssertTrue(deliveries.isEmpty)
        XCTAssertFalse(session.isFinished)
    }
}

/// Returns scripted updates in order, then throws like the skeleton engine.
struct ScriptedEngine: EditorHandling {
    private(set) var state: EditorState
    private var updates: [EditorUpdate]

    init(initial: String, updates: [EditorUpdate]) {
        state = EditorState(text: initial)
        self.updates = updates
    }

    mutating func handle(_ event: EditorEvent) throws -> EditorUpdate {
        guard !updates.isEmpty else { throw EditorError.notImplemented }
        let update = updates.removeFirst()
        state = update.state
        return update
    }
}
