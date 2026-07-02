import Foundation

public enum ModeSearch {
    /// Returns modes matching every query token while preserving the user's order.
    public static func filter(_ modes: [SableMode], query: String) -> [SableMode] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }

        guard !tokens.isEmpty else { return modes }

        return modes.filter { mode in
            let haystack = searchableText(for: mode)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    private static func searchableText(for mode: SableMode) -> String {
        [
            mode.name,
            mode.symbol,
            mode.runtimeID.rawValue,
            RuntimeDefinitions.definition(for: mode.runtimeID).displayName,
            mode.model,
            RuntimeDefinitions.modelLabel(for: mode.model, runtime: mode.runtimeID),
        ]
        .joined(separator: " ")
        .lowercased()
    }
}
