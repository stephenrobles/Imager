import Foundation

/// A candidate output in the temporary directory. The file is deleted when the last reference
/// goes away, so a job only has to keep the smallest result alive.
nonisolated final class TempFile: Sendable {
    let url: URL
    let size: Int

    /// Returns nil when the file is missing or empty, which every tool uses to mean "no output".
    init?(url: URL) {
        guard let size = TempFile.size(of: url), size > 0 else { return nil }
        self.url = url
        self.size = size
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Imager", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fresh path for a tool to write to, named after the tool so leftovers are recognizable.
    static func makeURL(tool: String, extension ext: String) -> URL {
        directory.appending(path: "\(tool)-\(UUID().uuidString).\(ext)")
    }

    static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Removes leftovers from earlier runs that crashed or were force-quit.
    static func cleanUpLeftovers() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }
}
