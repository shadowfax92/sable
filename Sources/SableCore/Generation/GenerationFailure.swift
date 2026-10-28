import Foundation

/// Safe protocol diagnostics retain classification, status and request correlation
/// without retaining the server's free-form message, request body or credentials.
public struct GenerationFailure: Error, Equatable, Sendable, LocalizedError {
    public enum BodyShape: String, Sendable { case structured, detail, unknown }
    public let provider: GenerationProvider
    public let status: Int?
    public let code: String?
    public let parameter: String?
    public let requestID: String?
    public let bodyShape: BodyShape

    init(provider: GenerationProvider, status: Int?, payload: [String: Any], requestID: String?) {
        self.provider = provider
        let error = payload["error"] as? [String: Any]
        self.status = status ?? error?["code"] as? Int
        bodyShape = error != nil ? .structured : (payload["detail"] != nil ? .detail : .unknown)
        // Only documented machine codes are retained. An arbitrary "code" can
        // itself contain a secret or echoed prompt; it is not trusted diagnostic text.
        let candidate = error?["code"] as? String
        code = candidate.flatMap { Self.knownCodes.contains($0) ? $0 : nil }
        let param = error?["param"] as? String
        parameter = param.flatMap { Self.knownParameters.contains($0) ? $0 : nil }
        self.requestID = requestID.flatMap { value in
            value.count <= 128 && value.hasPrefix("req_") && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            } ? value : nil
        }
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
        switch status {
        case 401: return "\(name) rejected authentication. Check the selected account or saved key and permissions."
        case 402: return "OpenRouter has insufficient credit. Check your balance; no other billing path was used."
        case 403: return "\(name) denied this request. Check account permissions, policy and serving region."
        case 429: return "\(name) is rate limited. Pause requests and check usage before trying again."
        case 503: return "\(name) is temporarily unavailable. Your connection is preserved; try again later."
        default: return "\(name) could not complete this request. Try again later or check the provider settings."
        }
    }

    private static let knownCodes: Set<String> = [
        "subscription_sharing_user_not_eligible", "subscription_sharing_usage_limit_exceeded",
        "subscription_sharing_usage_unavailable", "subscription_sharing_unsupported_capability",
        "subscription_sharing_route_not_supported", "subscription_sharing_invalid_user",
        "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context",
        "subscription_sharing_user_unavailable", "rate_limit_exceeded", "insufficient_quota",
        "invalid_api_key", "model_not_found", "server_error"
    ]
    private static let knownParameters: Set<String> = ["model", "input", "tools", "service_tier", "store", "stream"]
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
