import Foundation

public struct RuntimeSettings: Codable, Equatable, Sendable {
    public var claudePath: String
    public var codexPath: String

    public init(claudePath: String = "", codexPath: String = "") {
        self.claudePath = claudePath
        self.codexPath = codexPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        claudePath = try values.decodeIfPresent(String.self, forKey: .claudePath) ?? ""
        codexPath = try values.decodeIfPresent(String.self, forKey: .codexPath) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(claudePath, forKey: .claudePath)
        try values.encode(codexPath, forKey: .codexPath)
    }

    /// Returns the explicit executable path for a runtime, or an empty string to use PATH lookup.
    public func command(for runtime: RuntimeID) -> String {
        switch runtime {
        case .claude:
            Self.cleanPath(claudePath)
        case .codex:
            Self.cleanPath(codexPath)
        }
    }

    public var processEnvironment: [String: String] {
        RuntimeEnvironment.subprocessEnvironment()
    }

    private static func cleanPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case claudePath
        case codexPath
    }
}
