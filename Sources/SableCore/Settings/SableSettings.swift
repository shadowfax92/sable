import Foundation

/// What Sable does with a completed rewrite. Persisted by raw value, so cases
/// must never be renamed. Unknown values decode as the default instead of
/// failing: a settings decode failure makes the app fall back to standard
/// settings, and the next autosave would overwrite the user's custom modes.
public enum ResultHandling: String, Codable, Equatable, Sendable, CaseIterable {
    /// Keep the result in the overlay's modal editor. Nothing reaches the
    /// clipboard until the user accepts it (Enter copies, Cmd-Enter pastes back).
    case review
    /// Copy the result as soon as it completes and dismiss without taking focus.
    case quickCopy
}

/// One reusable text transformation. A mode bundles the system instruction with
/// the legacy harness + model, plus whether Sable should wait for the
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
    /// Nil inherits the app-wide selection. Legacy runtime/model values remain
    /// intact even when this mode uses a direct provider.
    public var generation: GenerationSelection?
    /// Nil inherits `SableSettings.resultHandling`. Lets an instant mode keep a
    /// quick-copy workflow while the app-wide default reviews results.
    public var resultHandling: ResultHandling?

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "wand.and.stars",
        instruction: String,
        runtimeID: RuntimeID = .claude,
        model: String = "default",
        requiresInput: Bool = false,
        generation: GenerationSelection? = nil,
        resultHandling: ResultHandling? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.instruction = instruction
        self.runtimeID = runtimeID
        self.model = model
        self.requiresInput = requiresInput
        self.generation = generation
        self.resultHandling = resultHandling
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
        generation = try values.decodeIfPresent(GenerationSelection.self, forKey: .generation)
        // A presentation preference must not make the whole settings file
        // unreadable; an unknown value simply inherits the app-wide default.
        resultHandling = try? values.decodeIfPresent(ResultHandling.self, forKey: .resultHandling)
    }
}

/// User-editable modes, runtime settings, run limits, and picker defaults.
public struct SableSettings: Codable, Equatable, Sendable {
    public var modes: [SableMode]
    public var runtimePaths: RuntimeSettings
    public var cwd: String
    public var timeoutSeconds: TimeInterval
    public var defaultModeID: UUID?
    /// Only provider/model preferences belong in settings; credentials live in
    /// the connection module's protected store. CLI remains the rollout default.
    public var generation: GenerationSelection
    /// App-wide result handling for modes without an override. Review is the
    /// default for new and existing installs; the interaction owner resolves it
    /// per run with `resultHandling(for:)`.
    public var resultHandling: ResultHandling
    /// CLI providers only: attach a screenshot for visual context. Off by
    /// default. Direct providers are text-only and never capture the screen,
    /// whatever this says.
    public var attachesScreenshotsForCLI: Bool

    public init(
        modes: [SableMode],
        runtimePaths: RuntimeSettings = RuntimeSettings(),
        cwd: String = "~",
        timeoutSeconds: TimeInterval = 120,
        defaultModeID: UUID? = nil,
        generation: GenerationSelection = GenerationSelection(provider: .legacyCLI),
        resultHandling: ResultHandling = .review,
        attachesScreenshotsForCLI: Bool = false
    ) {
        self.modes = modes
        self.runtimePaths = runtimePaths
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
        self.defaultModeID = defaultModeID
        self.generation = generation
        self.resultHandling = resultHandling
        self.attachesScreenshotsForCLI = attachesScreenshotsForCLI
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedModes = try values.decodeIfPresent([SableMode].self, forKey: .modes) ?? []
        modes = decodedModes.isEmpty ? SableSettings.defaultModes : decodedModes
        runtimePaths = try values.decodeIfPresent(RuntimeSettings.self, forKey: .runtimePaths) ?? RuntimeSettings()
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd) ?? "~"
        timeoutSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? 120
        defaultModeID = try values.decodeIfPresent(UUID.self, forKey: .defaultModeID)
        generation = try values.decodeIfPresent(GenerationSelection.self, forKey: .generation)
            ?? GenerationSelection(provider: .legacyCLI)
        // Tolerant like every other UI preference: see `ResultHandling`.
        resultHandling = (try? values.decodeIfPresent(ResultHandling.self, forKey: .resultHandling)) ?? .review
        attachesScreenshotsForCLI = (try? values.decodeIfPresent(Bool.self, forKey: .attachesScreenshotsForCLI)) ?? false
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

    /// First-run settings with "Ask" initially highlighted in the picker.
    public static var standard: SableSettings {
        let modes = defaultModes
        return SableSettings(modes: modes, defaultModeID: modes.last?.id)
    }

    public func mode(withID id: UUID) -> SableMode? {
        modes.first { $0.id == id }
    }

    /// Resolve inheritance only, never connection availability. A failed direct
    /// provider must report its error rather than silently selecting a paid fallback.
    public func generationSelection(for mode: SableMode) -> GenerationSelection {
        mode.generation ?? generation
    }

    /// Resolves the per-mode override. The interaction owner snapshots this at
    /// run start so a settings edit mid-run cannot change how a result is delivered.
    public func resultHandling(for mode: SableMode) -> ResultHandling {
        mode.resultHandling ?? resultHandling
    }

    /// Initial picker mode, falling back to the first mode.
    public var defaultMode: SableMode? {
        if let defaultModeID, let match = mode(withID: defaultModeID) {
            return match
        }
        return modes.first
    }
}
