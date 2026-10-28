import Foundation
import SableCore

/// A user-facing failure with one recovery action. The overlay only renders it
/// and reports the chosen action; recovery itself (retry, opening Settings or
/// ChatGPT usage) belongs to the interaction owner via `onFailureAction`.
///
/// Copy follows the OpenAI Sign in with ChatGPT guidelines and devkit wording for
/// plan-usage states. Messages come from the typed errors' `errorDescription`,
/// which their modules guarantee to be nonsecret.
struct OverlayFailure: Equatable {
    enum Action: Equatable {
        case retry
        case openSettings
        case manageUsage
        /// Closing goes through `onCancel`, like Escape.
        case close

        var title: String {
            switch self {
            case .retry: return "Try again"
            case .openSettings: return "Open Settings"
            case .manageUsage: return "Manage usage"
            case .close: return "Close"
            }
        }
    }

    var title: String
    var message: String
    var primaryAction: Action
    /// Shows a "ChatGPT" header so plan-usage failures keep the ChatGPT identity
    /// visible, as the guidelines require for compact messages.
    var showsChatGPTIdentity: Bool
    var requestID: String?

    init(
        title: String,
        message: String,
        primaryAction: Action,
        showsChatGPTIdentity: Bool = false,
        requestID: String? = nil
    ) {
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
        self.showsChatGPTIdentity = showsChatGPTIdentity
        self.requestID = requestID
    }

    /// Maps the real typed errors to a presentation. Returns nil for
    /// cancellation, which should show nothing.
    static func classify(_ error: Error, provider: GenerationProvider? = nil) -> OverlayFailure? {
        if error is CancellationError { return nil }
        // Distinct helper names: overloading `classify` on the concrete types let the
        // call resolve back to this `Error` overload and recurse forever.
        if let error = error as? GenerationError { return generation(error, provider: provider) }
        if let failure = error as? GenerationFailure { return providerFailure(failure) }
        if let error = error as? ConnectionError { return connection(error) }
        if let error = error as? SableError {
            if error == .noSelectedText {
                return OverlayFailure(
                    title: "No text selected",
                    message: "Select text in any app, then try again.",
                    primaryAction: .close
                )
            }
            return OverlayFailure(title: "Rewrite failed", message: describe(error), primaryAction: .retry)
        }
        return OverlayFailure(title: "Rewrite failed", message: describe(error), primaryAction: .retry)
    }

    private static func generation(_ error: GenerationError, provider: GenerationProvider?) -> OverlayFailure {
        let message = describe(error)
        switch error {
        case let .providerFailure(failure):
            return providerFailure(failure)
        case .missingOpenRouterKey:
            return OverlayFailure(title: "Add your OpenRouter key", message: message, primaryAction: .openSettings)
        case .modelUnavailable, .noModels:
            return OverlayFailure(title: "Model not available", message: message, primaryAction: .openSettings)
        case .emptyOutput:
            return OverlayFailure(
                title: "No text came back",
                message: "Try again, or rephrase the instruction.",
                primaryAction: .retry
            )
        case .deadlineExceeded:
            return OverlayFailure(title: "Timed out", message: message, primaryAction: .retry)
        case .networkUnavailable:
            if provider == .chatGPT { return chatGPTConnectionTrouble() }
            return OverlayFailure(title: "Couldn't reach the provider", message: message, primaryAction: .retry)
        case .interrupted, .incomplete, .invalidResponse, .refused, .accountChanged, .responseTooLarge:
            return OverlayFailure(title: "Rewrite didn't finish", message: message, primaryAction: .retry)
        case .notImplemented, .missingCLIContext:
            return OverlayFailure(title: "Provider unavailable", message: message, primaryAction: .openSettings)
        }
    }

    private static func providerFailure(_ failure: GenerationFailure) -> OverlayFailure {
        let message = describe(failure)
        let requestID = failure.requestID
        let status = Int(failure.code ?? "") ?? failure.status

        if failure.provider == .openRouter {
            switch status {
            case 402:
                return OverlayFailure(title: "OpenRouter credits ran out", message: message,
                                      primaryAction: .openSettings, requestID: requestID)
            case 401:
                return OverlayFailure(title: "OpenRouter rejected the key", message: message,
                                      primaryAction: .openSettings, requestID: requestID)
            case 429:
                return OverlayFailure(title: "OpenRouter is rate limited", message: message,
                                      primaryAction: .retry, requestID: requestID)
            default:
                return OverlayFailure(title: "OpenRouter couldn't finish", message: message,
                                      primaryAction: .retry, requestID: requestID)
            }
        }

        func chatGPT(_ title: String, _ body: String, _ action: Action) -> OverlayFailure {
            OverlayFailure(title: title, message: body, primaryAction: action,
                           showsChatGPTIdentity: true, requestID: requestID)
        }
        switch failure.code {
        case "subscription_sharing_usage_limit_exceeded":
            return chatGPT("ChatGPT usage limit reached", "Review your usage settings in ChatGPT.", .manageUsage)
        case "subscription_sharing_user_not_eligible":
            return chatGPT("ChatGPT plan use isn't available", message, .openSettings)
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            var trouble = chatGPTConnectionTrouble()
            trouble.requestID = requestID
            return trouble
        case "subscription_sharing_invalid_user":
            return chatGPT("Reconnect to ChatGPT", reconnectMessage, .openSettings)
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return chatGPT("ChatGPT plan permission wasn't accepted", message, .openSettings)
        case "subscription_sharing_unsupported_capability":
            return OverlayFailure(title: "Model not available", message: message,
                                  primaryAction: .openSettings, requestID: requestID)
        default:
            break
        }
        switch status {
        case 429:
            return chatGPT("ChatGPT usage limit reached", "Review your usage settings in ChatGPT.", .manageUsage)
        case 401:
            return chatGPT("Reconnect to ChatGPT", reconnectMessage, .openSettings)
        case 403:
            return chatGPT("ChatGPT plan permission wasn't accepted", message, .openSettings)
        case 503:
            var trouble = chatGPTConnectionTrouble()
            trouble.requestID = requestID
            return trouble
        default:
            return chatGPT("ChatGPT couldn't finish", message, .retry)
        }
    }

    private static func connection(_ error: ConnectionError) -> OverlayFailure {
        switch error {
        case .notConnected:
            return OverlayFailure(
                title: "Connect your ChatGPT plan",
                message: "Continue with ChatGPT in Sable Settings to start rewriting.",
                primaryAction: .openSettings, showsChatGPTIdentity: true
            )
        case .planPermissionRequired:
            return OverlayFailure(
                title: "You're signed in with ChatGPT",
                message: "Usage sharing is off. Enable it to use your ChatGPT plan in Sable.",
                primaryAction: .openSettings, showsChatGPTIdentity: true
            )
        case .reauthenticationRequired:
            return OverlayFailure(title: "Reconnect to ChatGPT", message: reconnectMessage,
                                  primaryAction: .openSettings, showsChatGPTIdentity: true)
        case .networkUnavailable:
            return chatGPTConnectionTrouble()
        default:
            return OverlayFailure(title: "ChatGPT connection problem", message: describe(error),
                                  primaryAction: .openSettings, showsChatGPTIdentity: true)
        }
    }

    private static let reconnectMessage =
        "Your connection needs to be renewed before Sable can use ChatGPT again."

    private static func chatGPTConnectionTrouble() -> OverlayFailure {
        OverlayFailure(
            title: "Couldn't connect to ChatGPT",
            message: "Check your connection and try again. Your existing billing choice stays the same.",
            primaryAction: .retry,
            showsChatGPTIdentity: true
        )
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Content for the non-key HUD pill. The pill never takes keyboard focus, so it
/// suits quick-copy runs and outcomes reported after the panel has closed.
enum OverlayNotice: Equatable {
    /// Persists until replaced or closed; its ✕ reports `onNoticeCancel`.
    case running(modeName: String)
    case copied
    case message(title: String, detail: String?)
    /// Its action button reports `onFailureAction` (`.close` just dismisses).
    case failure(OverlayFailure)

    /// Seconds before the pill dismisses itself; nil keeps it up.
    var duration: TimeInterval? {
        switch self {
        case .running: return nil
        case .copied: return 1.2
        case .message: return 2.5
        case .failure: return 10
        }
    }
}
