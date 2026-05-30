import Foundation

public enum RuntimeEnvironment {
    /// Builds the subprocess environment used by GUI-launched Sable runtime calls.
    public static func subprocessEnvironment(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var output = environment
        output["PATH"] = subprocessSearchPath(homeURL: homeURL, environment: environment)
        return output
    }

    public static func subprocessSearchPath(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var paths = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        paths += [
            homeURL.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var seen = Set<String>()
        return paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }
}
