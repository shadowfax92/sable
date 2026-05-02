import Foundation

public enum SableError: Error, Equatable, LocalizedError {
    case missingAccessibilityPermission
    case missingScreenRecordingPermission
    case noSelectedText
    case configNotFound(URL)
    case invalidConfig(String)
    case screenshotFailed(String)
    case claudeTimedOut
    case claudeFailed(String)
    case claudeResultMissing

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
        case .claudeTimedOut:
            return "Claude timed out"
        case .claudeFailed(let message):
            return "Claude failed: \(message)"
        case .claudeResultMissing:
            return "Claude did not return replacement text"
        }
    }
}
