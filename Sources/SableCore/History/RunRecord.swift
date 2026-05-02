import Foundation

public enum RunStatus: String, Codable, Equatable {
    case capturing
    case running
    case copied
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .capturing:
            return "Capturing"
        case .running:
            return "Running Claude"
        case .copied:
            return "Copied"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

public struct RunRecord: Codable, Equatable, Identifiable {
    public let id: UUID
    public var createdAt: Date
    public var completedAt: Date?
    public var status: RunStatus
    public var instruction: String
    public var selectedText: String
    public var screenshotPath: String?
    public var outputText: String?
    public var errorMessage: String?

    public init(
        id: UUID,
        createdAt: Date,
        completedAt: Date?,
        status: RunStatus,
        instruction: String,
        selectedText: String,
        screenshotPath: String?,
        outputText: String?,
        errorMessage: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.instruction = instruction
        self.selectedText = selectedText
        self.screenshotPath = screenshotPath
        self.outputText = outputText
        self.errorMessage = errorMessage
    }
}
