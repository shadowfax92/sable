import Foundation

public struct AppConfig: Decodable, Equatable {
    public let hotkeys: Hotkeys
    public let capture: Capture
    public let runtime: Runtime
    public let prompts: Prompts

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hotkeys = try values.decode(Hotkeys.self, forKey: .hotkeys)
        capture = try values.decode(Capture.self, forKey: .capture)
        runtime = try values.decodeIfPresent(Runtime.self, forKey: .runtime)
            ?? Runtime(legacyClaude: values.decode(LegacyClaude.self, forKey: .claude))
        prompts = try values.decode(Prompts.self, forKey: .prompts)
    }

    public struct Hotkeys: Decodable, Equatable {
        public let quickFix: String
        public let ask: String

        enum CodingKeys: String, CodingKey {
            case quickFix = "quick_fix"
            case ask
        }
    }

    public struct Capture: Decodable, Equatable {
        public let selectedTextFallback: String
        public let screenshot: Screenshot

        enum CodingKeys: String, CodingKey {
            case selectedTextFallback = "selected_text_fallback"
            case screenshot
        }
    }

    public struct Screenshot: Decodable, Equatable {
        public let enabled: Bool
        public let target: String
        public let fallback: String
        public let format: String
    }

    public struct Runtime: Decodable, Equatable {
        public let id: RuntimeID
        public let cwd: String
        public let timeoutSeconds: TimeInterval

        public init(id: RuntimeID, cwd: String, timeoutSeconds: TimeInterval) {
            self.id = id
            self.cwd = cwd
            self.timeoutSeconds = timeoutSeconds
        }

        fileprivate init(legacyClaude: LegacyClaude) {
            id = .claude
            cwd = legacyClaude.cwd
            timeoutSeconds = legacyClaude.timeoutSeconds
        }

        enum CodingKeys: String, CodingKey {
            case id
            case cwd
            case timeoutSeconds = "timeout_seconds"
        }
    }

    public struct Prompts: Decodable, Equatable {
        public let quickFix: String

        enum CodingKeys: String, CodingKey {
            case quickFix = "quick_fix"
        }
    }

    fileprivate struct LegacyClaude: Decodable, Equatable {
        let cwd: String
        let timeoutSeconds: TimeInterval

        enum CodingKeys: String, CodingKey {
            case cwd
            case timeoutSeconds = "timeout_seconds"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case hotkeys
        case capture
        case runtime
        case claude
        case prompts
    }
}
