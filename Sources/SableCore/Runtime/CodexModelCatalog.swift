import Foundation

/// Pulls the live Codex model list from `codex debug models` so Sable always
/// offers exactly what the installed CLI supports (including models the static
/// fallback predates, like `gpt-5.3-codex-spark`). Returns nil on any failure so
/// callers fall back to `RuntimeDefinitions.models(for: .codex)`.
public enum CodexModelCatalog {
    public static func detect(
        command: String = "codex",
        processClient: any ProcessClient = FoundationProcessClient()
    ) async -> [RuntimeModelOption]? {
        let invocation = ProcessInvocation(
            command: command.isEmpty ? "codex" : command,
            arguments: ["debug", "models"],
            timeout: 25
        )
        guard
            let result = try? await processClient.run(invocation),
            result.exitCode == 0
        else {
            return nil
        }
        return parse(result.stdout)
    }

    /// Parses the catalog JSON: keep `visibility == "list"` models, order by
    /// `priority` (lower first), and prepend the "default" sentinel.
    static func parse(_ json: String) -> [RuntimeModelOption]? {
        guard
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else {
            return nil
        }

        let options = models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model -> RuntimeModelOption? in
                guard let slug = model["slug"] as? String, !slug.isEmpty else {
                    return nil
                }
                let label = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
                return RuntimeModelOption(id: slug, label: label)
            }

        guard !options.isEmpty else {
            return nil
        }
        return [RuntimeDefinitions.defaultModel] + options
    }
}
