import Foundation

/// Captures billing intent before OAuth suspends. A signed-out Continue opts in
/// to ChatGPT; renewing identity/permission must preserve the existing provider
/// and model, as must any newer explicit choice made while sign-in is pending.
public struct ChatGPTSignInIntent: Sendable {
    private let adoptsChatGPT: Bool

    public init(startingStatus: ConnectionStatus) {
        adoptsChatGPT = startingStatus.activeAccount == nil && !startingStatus.needsReconnect
    }

    public func selection(
        after verifiedStatus: ConnectionStatus,
        current: GenerationSelection,
        providerChoiceUnchanged: Bool
    ) -> GenerationSelection {
        guard adoptsChatGPT, providerChoiceUnchanged,
              verifiedStatus.activeAccount != nil, verifiedStatus.planUsageEnabled,
              !verifiedStatus.needsReconnect else { return current }
        return GenerationSelection(provider: .chatGPT)
    }
}
