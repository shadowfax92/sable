import Foundation

public struct AppConfig: Decodable, Equatable {
    public let hotkeys: Hotkeys
    public let capture: Capture
    public let claude: Claude
    public let prompts: Prompts

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

    public struct Claude: Decodable, Equatable {
        public let command: String
        public let args: [String]
        public let cwd: String
        public let timeoutSeconds: TimeInterval

        enum CodingKeys: String, CodingKey {
            case command
            case args
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
}
