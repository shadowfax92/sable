import Foundation

public enum RunStatus: String, Codable, Equatable {
    case capturing
    case running
    case review
    case copied
    case pasted
    case discarded
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .capturing:
            return "Capturing"
        case .running:
            return "Running"
        case .review:
            return "Review"
        case .copied:
            return "Copied"
        case .pasted:
            return "Pasted"
        case .discarded:
            return "Discarded"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// History retains completed review buffers, including discarded edits. Optional
/// provider metadata keeps records from earlier app versions decodable.
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
    public var modeName: String?
    public var provider: GenerationProvider?
    public var model: String?

    public init(
        id: UUID,
        createdAt: Date,
        completedAt: Date?,
        status: RunStatus,
        instruction: String,
        selectedText: String,
        screenshotPath: String?,
        outputText: String?,
        errorMessage: String?,
        modeName: String? = nil,
        provider: GenerationProvider? = nil,
        model: String? = nil
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
        self.modeName = modeName
        self.provider = provider
        self.model = model
    }
}
