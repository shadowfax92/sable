import Foundation

/// Safe protocol diagnostics retain classification, status and request correlation
/// without retaining the server's free-form message, request body or credentials.
public struct GenerationFailure: Error, Equatable, Sendable, LocalizedError {
    public enum BodyShape: String, Sendable { case structured, detail, unknown }
    public let provider: GenerationProvider
    /// Actual admission status; a late SSE failure still has HTTP 200.
    public let status: Int?
    /// Provider machine code, including OpenRouter numeric error codes as strings.
    public let code: String?
    public let parameter: String?
    public let requestID: String?
    public let bodyShape: BodyShape

    init(provider: GenerationProvider, status: Int?, payload: [String: Any], requestID: String?, redacting credential: ConnectionSecret? = nil) {
        self.provider = provider
        self.status = status
        // Responses' standalone error event puts code/param at the top level;
        // admission failures and response.failed nest the same fields in error.
        let error = (payload["error"] as? [String: Any]) ?? (payload["type"] as? String == "error" ? payload : nil)
        bodyShape = error != nil ? .structured : (payload["detail"] != nil ? .detail : .unknown)
        let candidate = error?["code"] as? String ?? (error?["code"] as? NSNumber)?.stringValue
        code = Self.safeMetadata(candidate, redacting: credential)
        parameter = Self.safeMetadata(error?["param"] as? String, redacting: credential)
        self.requestID = Self.safeMetadata(requestID, redacting: credential)
    }

    public var errorDescription: String? {
        switch code {
        case "subscription_sharing_user_not_eligible":
            return "ChatGPT plan usage is unavailable for this account, workspace or policy. Check your account eligibility."
        case "subscription_sharing_usage_limit_exceeded":
            return "Sable's ChatGPT usage limit was reached. Check https://chatgpt.com/settings/usage before trying again."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return "ChatGPT usage is temporarily unavailable. Your connection is preserved; try again later."
        case "subscription_sharing_unsupported_capability":
            return "ChatGPT rejected an unsupported request option. Choose an available model or check the integration."
        case "subscription_sharing_route_not_supported":
            return "ChatGPT rejected this API route. Check the integration's Responses endpoint."
        case "subscription_sharing_invalid_user":
            return "ChatGPT could not validate this account. Check the selected account and sign in again if access was revoked."
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return "ChatGPT plan permission was not accepted. Check the account's grant and the integration configuration."
        default: break
        }
        let name = provider == .openRouter ? "OpenRouter" : "ChatGPT"
        switch Int(code ?? "") ?? status {
        case 401: return "\(name) rejected authentication. Check the selected account or saved key and permissions."
        case 402: return "OpenRouter has insufficient credit. Check your balance; no other billing path was used."
        case 403: return "\(name) denied this request. Check account permissions, policy and serving region."
        case 429: return "\(name) is rate limited. Pause requests and check usage before trying again."
        case 503: return "\(name) is temporarily unavailable. Your connection is preserved; try again later."
        default: return "\(name) could not complete this request. Try again later or check the provider settings."
        }
    }

    /// Recovery text recognizes known codes, while diagnostics retain future
    /// machine fields unchanged within a bounded identifier grammar. Free-form
    /// messages are never retained, and echoed bearer values are removed before
    /// any field can escape through status, reflection, or error descriptions.
    private static func safeMetadata(_ value: String?, redacting credential: ConnectionSecret?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                      || [45, 46, 47, 91, 93, 95].contains(byte)
              }) else { return nil }
        if let credential, !credential.rawValue.isEmpty, value.contains(credential.rawValue) { return nil }
        if value.hasPrefix("sk-"), value.count > 20 { return nil }
        return value
    }
}

extension GenerationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notImplemented: return "This generation provider is not available yet."
        case .missingCLIContext: return "Advanced CLI generation needs its runtime settings."
        case .missingOpenRouterKey: return "Save an OpenRouter API key in Settings before using OpenRouter."
        case .noModels: return "No text models are available for this provider. Check your account and model access."
        case .modelUnavailable: return "The selected model is unavailable. Choose a model from the provider's catalog."
        case .accountChanged: return "The ChatGPT account changed during this request. Run the rewrite again."
        case .invalidResponse: return "The provider returned an invalid response. No partial output was delivered."
        case .interrupted: return "The response stream ended before completion. Run the rewrite again."
        case .incomplete: return "The provider did not finish the rewrite. No partial output was delivered."
        case .refused: return "The provider declined this rewrite. No partial output was delivered."
        case .emptyOutput: return "The provider completed without text. No output was delivered."
        case .deadlineExceeded: return "The rewrite timed out. Try a shorter selection or increase the timeout."
        case .networkUnavailable: return "The provider connection failed. Check your network and try again."
        case .responseTooLarge: return "The provider response exceeded Sable's size limit. Try a shorter selection."
        case .providerFailure(let failure): return failure.errorDescription
        }
    }
}
