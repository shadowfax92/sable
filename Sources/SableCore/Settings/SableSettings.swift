import Foundation

/// One reusable text transformation. A mode bundles the system instruction with
/// the harness + model that should run it, plus whether Sable should wait for the
/// user to type an extra instruction (free-form "ask") or fire immediately
/// (one-shot, like "fix grammar"). Each mode's hotkey lives in `KeyboardShortcuts`
/// keyed by the mode `id`, so the id must stay stable across launches.
public struct SableMode: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var instruction: String
    public var runtimeID: RuntimeID
    public var model: String
    public var requiresInput: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "wand.and.stars",
        instruction: String,
        runtimeID: RuntimeID = .claude,
        model: String = "default",
        requiresInput: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.instruction = instruction
        self.runtimeID = runtimeID
        self.model = model
        self.requiresInput = requiresInput
    }

    // Tolerant decoding so older/partial settings files still load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Mode"
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? "wand.and.stars"
        instruction = try values.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        runtimeID = try values.decodeIfPresent(RuntimeID.self, forKey: .runtimeID) ?? .claude
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? "default"
        requiresInput = try values.decodeIfPresent(Bool.self, forKey: .requiresInput) ?? false
    }
}

/// Everything the app owns and can rewrite from the in-app settings: the user's
/// modes, the CLI binary paths, the shared run directory + timeout, and which
/// mode the global popup hotkey opens with.
public struct SableSettings: Codable, Equatable, Sendable {
    public var modes: [SableMode]
    public var runtimePaths: RuntimeSettings
    public var cwd: String
    public var timeoutSeconds: TimeInterval
    public var defaultModeID: UUID?

    public init(
        modes: [SableMode],
        runtimePaths: RuntimeSettings = RuntimeSettings(),
        cwd: String = "~",
        timeoutSeconds: TimeInterval = 120,
        defaultModeID: UUID? = nil
    ) {
        self.modes = modes
        self.runtimePaths = runtimePaths
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
        self.defaultModeID = defaultModeID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedModes = try values.decodeIfPresent([SableMode].self, forKey: .modes) ?? []
        modes = decodedModes.isEmpty ? SableSettings.defaultModes : decodedModes
        runtimePaths = try values.decodeIfPresent(RuntimeSettings.self, forKey: .runtimePaths) ?? RuntimeSettings()
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd) ?? "~"
        timeoutSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? 120
        defaultModeID = try values.decodeIfPresent(UUID.self, forKey: .defaultModeID)
    }

    public static let defaultModes: [SableMode] = [
        SableMode(
            name: "Fix Grammar",
            symbol: "text.badge.checkmark",
            instruction: """
            Fix spelling and grammar. Remove filler words. Convert any accidental \
            inconsistencies in phrasing. Maintain the original tone and meaning. \
            Do not include any preamble — just output the corrected text.
            """,
            runtimeID: .claude,
            model: "sonnet",
            requiresInput: false
        ),
        SableMode(
            name: "Make Concise",
            symbol: "scissors",
            instruction: """
            Rewrite the text to be as concise as possible while preserving meaning \
            and tone. Return only the rewritten text.
            """,
            runtimeID: .claude,
            model: "sonnet",
            requiresInput: false
        ),
        SableMode(
            name: "Ask",
            symbol: "sparkles",
            instruction: "",
            runtimeID: .claude,
            model: "default",
            requiresInput: true
        ),
    ]

    /// First-run settings: the three starter modes, defaulting the popup to "Ask".
    public static var standard: SableSettings {
        let modes = defaultModes
        return SableSettings(modes: modes, defaultModeID: modes.last?.id)
    }

    public func mode(withID id: UUID) -> SableMode? {
        modes.first { $0.id == id }
    }

    /// The mode the bare popup hotkey opens with — the configured default, or the
    /// first mode as a fallback.
    public var defaultMode: SableMode? {
        if let defaultModeID, let match = mode(withID: defaultModeID) {
            return match
        }
        return modes.first
    }
}
