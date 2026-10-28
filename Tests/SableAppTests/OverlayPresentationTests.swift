import AppKit
@testable import SableApp
@testable import SableCore
import XCTest

final class OverlayKeyRouterTests: XCTestCase {
    private func key(_ code: UInt16, _ character: String? = nil, control: Bool = false, command: Bool = false)
        -> OverlayKeyRouter.Key {
        OverlayKeyRouter.Key(keyCode: code, character: character, control: control, command: command)
    }

    func testPickerMovesWithArrowsAndControlKeysAndPicksOnReturn() {
        let phase = OverlayModel.Phase.picking
        XCTAssertEqual(OverlayKeyRouter.action(for: key(125), in: phase), .moveNext)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(126), in: phase), .movePrevious)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(38, "j", control: true), in: phase), .moveNext)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(45, "n", control: true), in: phase), .moveNext)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(40, "k", control: true), in: phase), .movePrevious)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(35, "p", control: true), in: phase), .movePrevious)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(36), in: phase), .pick)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(76), in: phase), .pick)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(53), in: phase), .cancel)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(38, "j"), in: phase), .passThrough, "plain j types")
    }

    func testOtherPhases() {
        XCTAssertEqual(OverlayKeyRouter.action(for: key(53), in: .input), .back)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(36), in: .input), .passThrough)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(53), in: .thinking), .cancel)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(0, "a"), in: .thinking), .swallow)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(12, "q", command: true), in: .thinking), .passThrough)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(53), in: .done("x")), .closeLocally)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(36), in: .done("x")), .closeLocally)
        let failure = OverlayModel.Phase.failure(OverlayFailure(title: "t", message: "m", primaryAction: .retry))
        XCTAssertEqual(OverlayKeyRouter.action(for: key(36), in: failure), .primaryAction)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(53), in: failure), .cancel)
        XCTAssertEqual(OverlayKeyRouter.action(for: key(36), in: .error("legacy")), .primaryAction)
        for code: UInt16 in [53, 36, 125, 38] {
            XCTAssertEqual(OverlayKeyRouter.action(for: key(code), in: .review), .passThrough)
        }
    }
}

final class OverlayGeometryTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testResizeKeepsTopEdgeAndCenter() {
        let current = NSRect(x: 386, y: 400, width: 648, height: 300)
        let origin = OverlayPanelController.anchoredOrigin(
            currentFrame: current, newSize: NSSize(width: 648, height: 480), in: visible
        )
        XCTAssertEqual(origin.x, 386)
        XCTAssertEqual(origin.y + 480, current.maxY)
    }

    func testGrowthPastBottomMovesUpButKeepsTopOnScreen() {
        let current = NSRect(x: 100, y: 50, width: 648, height: 200)
        let grown = OverlayPanelController.anchoredOrigin(
            currentFrame: current, newSize: NSSize(width: 648, height: 400), in: visible
        )
        XCTAssertEqual(grown.y, 8)

        let huge = OverlayPanelController.anchoredOrigin(
            currentFrame: current, newSize: NSSize(width: 648, height: 2000), in: visible
        )
        XCTAssertEqual(huge.y + 2000, visible.maxY - 8)
    }

    func testPillSitsTopCenter() {
        let origin = NoticePillController.pillOrigin(size: NSSize(width: 300, height: 68), in: visible)
        XCTAssertEqual(origin, NSPoint(x: 570, y: 832))
    }
}

final class OverlayFailureTests: XCTestCase {
    private func failure(_ provider: GenerationProvider, status: Int?, code: String?, requestID: String? = nil)
        -> GenerationError {
        var error: [String: Any] = [:]
        if let code { error["code"] = code }
        return .providerFailure(GenerationFailure(
            provider: provider, status: status, payload: ["error": error], requestID: requestID
        ))
    }

    func testUsageLimitUsesManageUsageWithChatGPTIdentityAndRequestID() throws {
        let result = try XCTUnwrap(OverlayFailure.classify(
            failure(.chatGPT, status: 429, code: "subscription_sharing_usage_limit_exceeded", requestID: "req_42")
        ))
        XCTAssertEqual(result.title, "ChatGPT usage limit reached")
        XCTAssertEqual(result.message, "Review your usage settings in ChatGPT.")
        XCTAssertEqual(result.primaryAction, .manageUsage)
        XCTAssertTrue(result.showsChatGPTIdentity)
        XCTAssertEqual(result.requestID, "req_42")
    }

    func testRecoveryActionsForTypedErrors() {
        XCTAssertEqual(OverlayFailure.classify(failure(.chatGPT, status: 401, code: nil))?.primaryAction, .openSettings)
        XCTAssertEqual(OverlayFailure.classify(failure(.chatGPT, status: 503, code: nil))?.primaryAction, .retry)
        XCTAssertEqual(OverlayFailure.classify(failure(.openRouter, status: 402, code: nil))?.title, "OpenRouter credits ran out")
        XCTAssertFalse(OverlayFailure.classify(failure(.openRouter, status: 429, code: nil))?.showsChatGPTIdentity ?? true)
        XCTAssertEqual(OverlayFailure.classify(GenerationError.missingOpenRouterKey)?.primaryAction, .openSettings)
        XCTAssertEqual(OverlayFailure.classify(GenerationError.emptyOutput)?.primaryAction, .retry)
        XCTAssertEqual(OverlayFailure.classify(GenerationError.networkUnavailable, provider: .chatGPT)?.showsChatGPTIdentity, true)
        XCTAssertEqual(OverlayFailure.classify(ConnectionError.planPermissionRequired)?.title, "You're signed in with ChatGPT")
        XCTAssertEqual(OverlayFailure.classify(ConnectionError.reauthenticationRequired)?.primaryAction, .openSettings)
        XCTAssertEqual(OverlayFailure.classify(ConnectionError.notConnected)?.title, "Connect your ChatGPT plan")
        XCTAssertEqual(OverlayFailure.classify(SableError.noSelectedText)?.primaryAction, .close)
        XCTAssertNil(OverlayFailure.classify(CancellationError()))
    }
}

@MainActor
final class OverlayModelFlowTests: XCTestCase {
    func testInstructionFromPickerGoesBackButDirectHotkeyCancels() {
        let model = OverlayModel()
        var showedPicker = 0
        var cancelled = 0
        model.onShowPicker = { showedPicker += 1 }
        model.onCancel = { cancelled += 1 }
        let modes = SableSettings.defaultModes

        model.configurePicker(selectedText: "text", modes: modes, initialModeID: nil)
        model.configure(mode: modes[2], selectedText: "text", modes: modes)
        XCTAssertTrue(model.instructionReturnsToPicker)
        model.backFromInstruction()
        XCTAssertEqual(showedPicker, 1)

        model.invalidateSession()
        model.configure(mode: modes[2], selectedText: "text", modes: modes)
        XCTAssertFalse(model.instructionReturnsToPicker)
        model.backFromInstruction()
        XCTAssertEqual(cancelled, 1)
    }

    func testInstantModesNeedSelection() {
        let model = OverlayModel()
        var picked: [UUID] = []
        model.onPickMode = { picked.append($0) }
        let modes = SableSettings.defaultModes
        model.configurePicker(selectedText: "", modes: modes, initialModeID: modes[0].id)

        XCTAssertFalse(model.isModePickable(modes[0]))
        model.pickHighlightedMode()
        model.pickMode(modes[2].id)
        XCTAssertEqual(picked, [modes[2].id], "Ask still works without a selection")
    }

    func testFailureActionRoutesWithInteractionIDAndCloseCancels() {
        let model = OverlayModel()
        var actions: [(OverlayFailure.Action, UUID)] = []
        var cancelled = 0
        model.onFailureAction = { actions.append(($0, $1)) }
        model.onCancel = { cancelled += 1 }
        let id = UUID()
        model.configurePicker(selectedText: "", modes: SableSettings.defaultModes, initialModeID: nil, interactionID: id)

        model.showFailure(OverlayFailure(title: "t", message: "m", primaryAction: .manageUsage))
        model.performFailureAction()
        model.showFailure(OverlayFailure(title: "t", message: "m", primaryAction: .close))
        model.performFailureAction()

        XCTAssertEqual(actions.map(\.0), [.manageUsage])
        XCTAssertEqual(actions.first?.1, id)
        XCTAssertEqual(cancelled, 1)
    }

    func testPhaseChangesRequestLayout() {
        let model = OverlayModel()
        let before = model.layoutRequest
        model.phase = .thinking
        model.phase = .thinking
        XCTAssertEqual(model.layoutRequest, before + 1)
    }
}

@MainActor
final class OverlayPanelControllerContractTests: XCTestCase {
    func testStaleInteractionUpdatesAreIgnored() {
        let overlay = OverlayPanelController()
        let current = UUID()
        overlay.model.configurePicker(
            selectedText: "x", modes: SableSettings.defaultModes, initialModeID: nil, interactionID: current
        )

        XCTAssertFalse(overlay.showRunning(interactionID: UUID()))
        XCTAssertFalse(overlay.showFailure(OverlayFailure(title: "t", message: "m", primaryAction: .retry), interactionID: UUID()))
        XCTAssertEqual(overlay.model.phase, .picking)

        XCTAssertTrue(overlay.showRunning(interactionID: current))
        XCTAssertEqual(overlay.model.phase, .thinking)
        XCTAssertTrue(overlay.close(interactionID: current))
        XCTAssertNil(overlay.currentInteractionID)
        XCTAssertFalse(overlay.showReview(result: "r", target: ReviewTarget(), interactionID: current))
    }
}

// F2: while the panel isn't key, keystrokes go to another app, so running and
// review must not advertise ⏎/⌘⏎/esc.
@MainActor
final class OverlayKeyStateTests: XCTestCase {
    func testNonKeyReviewAndRunningOfferOnlyTheClickAffordance() {
        let target = ReviewTarget(sourceAppName: "Slack", canPasteBack: true)
        for mode in [EditorMode.normal, .insert, .visual] {
            XCTAssertEqual(OverlayHints.review(mode: mode, target: target, isPanelKey: false),
                           [OverlayHint(text: "click to review")])
        }
        XCTAssertEqual(OverlayHints.running(isPanelKey: false), [OverlayHint(text: "click to focus")])
        XCTAssertEqual(OverlayHints.running(isPanelKey: true), [OverlayHint(text: "cancel", cap: "esc")])
    }

    func testKeyReviewHintsNameThePasteDestinationOnlyWhenSafe() {
        let slack = OverlayHints.review(mode: .normal, target: ReviewTarget(sourceAppName: "Slack", canPasteBack: true),
                                        isPanelKey: true)
        XCTAssertEqual(slack.map(\.cap), ["⏎", "⌘⏎", "i", "esc"])
        XCTAssertEqual(slack[1].text, "paste into Slack")

        let unsafe = OverlayHints.review(mode: .normal, target: ReviewTarget(), isPanelKey: true)
        XCTAssertFalse(unsafe.contains { $0.cap == "⌘⏎" })
    }

    func testGainingKeyRefocusesReviewButCompletionAndOtherPhasesDoNot() {
        let model = OverlayModel()
        model.configurePicker(selectedText: "x", modes: SableSettings.defaultModes, initialModeID: nil)
        model.showRunning()
        let running = model.focusNonce
        model.panelKeyDidChange(true)
        XCTAssertEqual(model.focusNonce, running)
        model.panelKeyDidChange(false)

        model.presentReview(result: "r", engine: ScriptedEngine(initial: "r", updates: []))
        let afterCompletion = model.focusNonce
        XCTAssertFalse(model.isPanelKey, "completion never makes the panel key")

        model.panelKeyDidChange(true) // the user clicked the panel
        XCTAssertTrue(model.isPanelKey)
        XCTAssertEqual(model.focusNonce, afterCompletion + 1)
        model.panelKeyDidChange(true)
        XCTAssertEqual(model.focusNonce, afterCompletion + 1)
    }
}
