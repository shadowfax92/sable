import Foundation

public enum SableError: Error, Equatable, LocalizedError {
    case missingAccessibilityPermission
    case missingScreenRecordingPermission
    case noSelectedText
    case configNotFound(URL)
    case invalidConfig(String)
    case screenshotFailed(String)
    case runtimeTimedOut(String)
    case runtimeFailed(String, String)
    case runtimeResultMissing(String)

    public var errorDescription: String? {
        switch self {
        case .missingAccessibilityPermission:
            return "Missing Accessibility permission"
        case .missingScreenRecordingPermission:
            return "Missing Screen Recording permission"
        case .noSelectedText:
            return "No selected text found"
        case .configNotFound(let url):
            return "Config file not found at \(url.path)"
        case .invalidConfig(let message):
            return "Invalid config: \(message)"
        case .screenshotFailed(let message):
            return "Screenshot failed: \(message)"
        case .runtimeTimedOut(let runtime):
            return "\(runtime) timed out"
        case .runtimeFailed(let runtime, let message):
            return "\(runtime) failed: \(message)"
        case .runtimeResultMissing(let runtime):
            return "\(runtime) did not return replacement text"
        }
    }
}
