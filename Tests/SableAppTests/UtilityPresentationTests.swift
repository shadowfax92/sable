import SableCore
@testable import SableApp
import XCTest

/// Headless checks for the utility window's state rules: connection
/// precedence, provider/model namespaces, legacy-field preservation, and the
/// routing of connection and key actions through `MainWindowModel`.
@MainActor
final class UtilityPresentationTests: XCTestCase {
    private let account = ConnectionAccount(id: "reg-1", displayName: "Ada", email: "ada@example.com")

    // MARK: Connection

    func testConnectionPhasesFollowReportedStatus() {
        XCTAssertEqual(phase(ConnectionStatus()), .signedOut)
        XCTAssertEqual(phase(ConnectionStatus(activeAccount: account, planUsageEnabled: true)), .connected)
        XCTAssertEqual(phase(ConnectionStatus(activeAccount: account, planUsageEnabled: false)), .usageSharingOff)
        // Terminal invalidation clears the active account but must not read as
        // a plain signed-out state.
        XCTAssertEqual(phase(ConnectionStatus(activeAccount: nil, needsReconnect: true)), .reconnectRequired)
        XCTAssertEqual(phase(ConnectionStatus(isSigningIn: true)), .signingIn)
    }

    func testOnlyPlanEnabledConnectionCanChooseModel() {
        let connected = presentation(ConnectionStatus(activeAccount: account, planUsageEnabled: true))
        let identityOnly = presentation(ConnectionStatus(activeAccount: account, planUsageEnabled: false))
        XCTAssertTrue(connected.canChooseModel)
        XCTAssertFalse(identityOnly.canChooseModel)
        XCTAssertFalse(presentation(ConnectionStatus()).canChooseModel)
    }

    func testReplacementSignInKeepsActiveAccountVisible() {
        let state = presentation(
            ConnectionStatus(activeAccount: account, planUsageEnabled: true),
            activity: .signingIn
        )
        XCTAssertEqual(state.phase, .signingIn)
        XCTAssertEqual(state.account, account)
        XCTAssertFalse(state.canChooseModel)
    }

    func testDisconnectingTakesPrecedenceOverSignIn() {
        let state = presentation(ConnectionStatus(activeAccount: account, isSigningIn: true), activity: .disconnecting)
        XCTAssertEqual(state.phase, .disconnecting)
    }

    func testFailedSignInPreservesWhateverStatusReports() {
        let failure = ConnectionIssue.signInFailed("ChatGPT sign-in was declined.")

        let withPrevious = presentation(
            ConnectionStatus(activeAccount: account, planUsageEnabled: true),
            issue: failure
        )
        XCTAssertEqual(withPrevious.phase, .connected)
        XCTAssertEqual(withPrevious.account, account)
        XCTAssertEqual(withPrevious.notice, .signInFailed("ChatGPT sign-in was declined."))

        let firstAttempt = presentation(ConnectionStatus(), issue: failure)
        XCTAssertEqual(firstAttempt.phase, .signedOut)
        XCTAssertEqual(firstAttempt.notice, .signInFailed("ChatGPT sign-in was declined."))
    }

    func testUnconfirmedRemoteSignOutIsSignedOutWithNotice() {
        let state = presentation(ConnectionStatus(), issue: .remoteSignOutUnconfirmed)
        XCTAssertEqual(state.phase, .signedOut)
        XCTAssertEqual(state.notice, .remoteSignOutUnconfirmed)
    }

    // MARK: Providers and models

    func testChangingProviderResetsModelNamespace() {
        let chatGPT = GenerationSelection(provider: .chatGPT, model: "gpt-account-slug")
        XCTAssertEqual(chatGPT.selectingProvider(.openRouter), GenerationSelection(provider: .openRouter))
        XCTAssertEqual(chatGPT.selectingProvider(.legacyCLI), GenerationSelection(provider: .legacyCLI))
        XCTAssertEqual(chatGPT.selectingProvider(.chatGPT), chatGPT)
    }

    func testModelMenuKeepsServerOrderAndAnUnavailableStoredSlug() {
        let catalog = ModelCatalogState.loaded([
            GenerationModel(id: "b-model", displayName: "B"),
            GenerationModel(id: "a-model", displayName: "A"),
        ])

        let listed = ModelMenuEntry.entries(catalog: catalog, selected: "a-model")
        XCTAssertEqual(listed.map(\.slug), [nil, "b-model", "a-model"])
        XCTAssertEqual(listed.map(\.title), ["Automatic", "B", "A"])

        let missing = ModelMenuEntry.entries(catalog: catalog, selected: "retired-model")
        XCTAssertEqual(missing.last, ModelMenuEntry(slug: "retired-model", title: "retired-model (unavailable)"))
        XCTAssertEqual(missing.count, 4)
    }

    func testModelMenuDoesNotJudgeAvailabilityBeforeCatalogLoads() {
        for catalog in [ModelCatalogState.idle, .loading, .failed("offline")] {
            let entries = ModelMenuEntry.entries(catalog: catalog, selected: "stored", defaultTitle: "Account default")
            XCTAssertEqual(entries, [
                ModelMenuEntry(slug: nil, title: "Account default"),
                ModelMenuEntry(slug: "stored", title: "stored"),
            ])
        }
    }

    // MARK: Per-mode override

    func testDirectOverrideNeverUsesOrClearsLegacyModel() {
        var mode = SableMode(name: "Fix", instruction: "Fix it", runtimeID: .codex, model: "sonnet")

        ModeProviderChoice.provider(.chatGPT).apply(to: &mode)
        XCTAssertEqual(mode.generation, GenerationSelection(provider: .chatGPT))
        XCTAssertEqual(mode.runtimeID, .codex)
        XCTAssertEqual(mode.model, "sonnet")

        mode.generation?.model = "gpt-account-slug"
        ModeProviderChoice.provider(.chatGPT).apply(to: &mode)
        XCTAssertEqual(mode.generation?.model, "gpt-account-slug", "re-picking the same provider keeps its model")

        ModeProviderChoice.provider(.legacyCLI).apply(to: &mode)
        XCTAssertEqual(mode.generation, GenerationSelection(provider: .legacyCLI))
        XCTAssertEqual(mode.model, "sonnet")

        ModeProviderChoice.inherit.apply(to: &mode)
        XCTAssertNil(mode.generation)
        XCTAssertEqual(ModeProviderChoice(mode), .inherit)
        XCTAssertEqual(mode.runtimeID, .codex)
        XCTAssertEqual(mode.model, "sonnet")
    }

    // MARK: Model actions

    func testOpenRouterKeyIsTrimmedHandedOffAndNotRetained() {
        let model = MainWindowModel()
        model.openRouterKeyIssue = "Previous failure"
        var received: [String] = []
        model.onSaveOpenRouterKey = { received.append($0.rawValue) }

        XCTAssertFalse(model.submitOpenRouterKey("  \n"))
        XCTAssertEqual(received, [])
        XCTAssertEqual(model.openRouterKeyIssue, "Previous failure")

        XCTAssertTrue(model.submitOpenRouterKey("  sk-or-test\n"))
        XCTAssertEqual(received, ["sk-or-test"])
        XCTAssertNil(model.openRouterKeyIssue)
        XCTAssertFalse(model.hasOpenRouterKey, "only the coordinator reports a saved key")
    }

    func testConnectStartsSignInWithoutSwitchingProvider() {
        let model = MainWindowModel()
        model.connectionIssue = .signInFailed("Earlier failure")
        var connects = 0
        model.onConnectChatGPT = { connects += 1 }

        model.connectChatGPT()

        XCTAssertEqual(connects, 1)
        XCTAssertEqual(model.connectionActivity, .signingIn)
        XCTAssertNil(model.connectionIssue)
        XCTAssertEqual(model.settings.generation.provider, .legacyCLI)
    }

    func testDisconnectAndCancelRouteToCallbacks() {
        let model = MainWindowModel()
        var calls: [String] = []
        model.onDisconnectChatGPT = { calls.append("disconnect") }
        model.onCancelChatGPTSignIn = { calls.append("cancel") }

        model.cancelChatGPTSignIn()
        model.disconnectChatGPT()

        XCTAssertEqual(calls, ["cancel", "disconnect"])
        XCTAssertEqual(model.connectionActivity, .disconnecting)
    }

    func testCatalogIsRequestedOnlyWhileUnloaded() {
        let model = MainWindowModel()
        var requests: [GenerationProvider] = []
        model.onRefreshModels = { requests.append($0) }

        model.requestModelCatalogIfNeeded(.chatGPT)
        model.modelCatalogs[.chatGPT] = .loading
        model.requestModelCatalogIfNeeded(.chatGPT)
        model.modelCatalogs[.chatGPT] = .failed("offline")
        model.requestModelCatalogIfNeeded(.chatGPT)

        XCTAssertEqual(requests, [.chatGPT], "loading and failed catalogs wait for an explicit refresh")
    }

    // MARK: Helpers

    private func presentation(
        _ status: ConnectionStatus,
        activity: ConnectionActivity = .idle,
        issue: ConnectionIssue? = nil
    ) -> ChatGPTConnectionPresentation {
        ChatGPTConnectionPresentation(status: status, activity: activity, issue: issue)
    }

    private func phase(_ status: ConnectionStatus) -> ChatGPTConnectionPresentation.Phase {
        presentation(status).phase
    }
}
