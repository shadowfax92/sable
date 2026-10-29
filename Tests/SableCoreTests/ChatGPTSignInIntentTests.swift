import XCTest
@testable import SableCore

/// Exercises billing-choice behavior at the OAuth handoff without opening a
/// browser or constructing the coordinator's windows and native services.
final class ChatGPTSignInIntentTests: XCTestCase {
    private let account = ConnectionAccount(id: "verified-account", displayName: "Fixture")
    private let explicitOpenRouter = GenerationSelection(provider: .openRouter, model: "owner/chosen-model")

    func testFirstConnectOptsIntoChatGPTOnlyAfterVerifiedPlanConsent() {
        let intent = ChatGPTSignInIntent(startingStatus: ConnectionStatus())
        let verified = ConnectionStatus(activeAccount: account, planUsageEnabled: true)
        XCTAssertEqual(intent.selection(after: verified, current: explicitOpenRouter, providerChoiceUnchanged: true),
                       GenerationSelection(provider: .chatGPT))
        for incomplete in [ConnectionStatus(), ConnectionStatus(activeAccount: account),
                           ConnectionStatus(activeAccount: account, planUsageEnabled: true, needsReconnect: true)] {
            XCTAssertEqual(intent.selection(after: incomplete, current: explicitOpenRouter, providerChoiceUnchanged: true),
                           explicitOpenRouter)
        }
    }

    func testReconnectPreservesExistingOpenRouterProviderAndModel() {
        let intent = ChatGPTSignInIntent(startingStatus: ConnectionStatus(activeAccount: account, needsReconnect: true))
        let renewed = ConnectionStatus(activeAccount: account, planUsageEnabled: true)
        XCTAssertEqual(intent.selection(after: renewed, current: explicitOpenRouter, providerChoiceUnchanged: true),
                       explicitOpenRouter)
    }

    func testPermissionRenewalPreservesExistingProviderAndModel() {
        let intent = ChatGPTSignInIntent(startingStatus: ConnectionStatus(activeAccount: account, planUsageEnabled: false))
        let enabled = ConnectionStatus(activeAccount: account, planUsageEnabled: true)
        XCTAssertEqual(intent.selection(after: enabled, current: explicitOpenRouter, providerChoiceUnchanged: true),
                       explicitOpenRouter)
    }

    func testNewerSelectionWhileFirstSignInIsPendingWins() {
        let intent = ChatGPTSignInIntent(startingStatus: ConnectionStatus())
        let verified = ConnectionStatus(activeAccount: account, planUsageEnabled: true)
        let newerChoice = GenerationSelection(provider: .openRouter, model: "owner/newer-model")
        XCTAssertEqual(intent.selection(after: verified, current: newerChoice, providerChoiceUnchanged: false), newerChoice)
    }

    func testExpiredConnectionWithoutActiveIdentityStillDoesNotOptIn() {
        let intent = ChatGPTSignInIntent(startingStatus: ConnectionStatus(needsReconnect: true))
        let verified = ConnectionStatus(activeAccount: account, planUsageEnabled: true)
        XCTAssertEqual(intent.selection(after: verified, current: explicitOpenRouter, providerChoiceUnchanged: true),
                       explicitOpenRouter)
    }

    func testReplacingAnActiveConnectionPreservesExplicitCLISelection() {
        let intent = ChatGPTSignInIntent(startingStatus: ConnectionStatus(activeAccount: account, planUsageEnabled: true))
        let replacement = ConnectionStatus(activeAccount: ConnectionAccount(id: "new-account", displayName: "New"), planUsageEnabled: true)
        let existing = GenerationSelection(provider: .legacyCLI)
        XCTAssertEqual(intent.selection(after: replacement, current: existing, providerChoiceUnchanged: true), existing)
    }
}
