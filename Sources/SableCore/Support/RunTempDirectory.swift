import Foundation

public final class RunTempDirectory {
    public let url: URL
    public let screenshotURL: URL

    public init(
        baseDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sable", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true),
        id: UUID = UUID()
    ) throws {
        url = baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        screenshotURL = url.appendingPathComponent("screenshot.png", isDirectory: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Clears abandoned run directories left by a previous crash or forced quit.
    public static func deleteStaleRuns(
        baseDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sable", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    ) throws {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else {
            return
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )
        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }
    }
}
