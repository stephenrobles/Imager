import Foundation

/// Puts an optimized file in place of the original. The original goes to the Trash so it can be
/// brought back, and the replacement keeps the file's identity when asked to.
nonisolated enum FileSaver {
    struct Outcome: Sendable {
        /// Where the file now lives (normally unchanged).
        let url: URL
        /// Where the original went, for Revert. Nil when it could not be kept.
        let revertURL: URL?
    }

    enum Failure: Error, LocalizedError {
        case folderNotWritable
        case truncatedOutput
        case cannotReplace(String)

        var errorDescription: String? {
            switch self {
            case .folderNotWritable: "The folder isn't writable"
            case .truncatedOutput: "The optimized file looks truncated, so the original was kept"
            case .cannotReplace(let reason): "The optimized file could not be saved: \(reason)"
            }
        }
    }

    /// - Parameters:
    ///   - preservePermissions: rewrites the original file's contents in place so hard links,
    ///     ownership, permissions and extended attributes survive (slightly slower).
    ///   - preserveDates: copies the creation and modification dates onto the new file.
    static func replace(original url: URL, with optimized: TempFile, preservePermissions: Bool, preserveDates: Bool) throws -> Outcome {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else { throw Failure.folderNotWritable }

        // Dropbox has lost files that were moved and trashed in quick succession; take the simple path there.
        let isDropbox = fm.fileExists(atPath: folder.appending(path: ".dropbox").path) || url.path.contains("/Dropbox/")

        let data = try Data(contentsOf: optimized.url)
        guard data.count == optimized.size, data.count >= 30 else { throw Failure.truncatedOutput }

        var sourceToMove = optimized.url
        if preservePermissions && !isDropbox {
            // Move the original to a hidden name, copy it back under its own name (that copy is what
            // gets trashed), then overwrite the hidden file's bytes so its inode and metadata carry on.
            let hidden = folder.appending(path: ".\(url.deletingPathExtension().lastPathComponent)~imager.\(url.pathExtension)")
            if fm.fileExists(atPath: hidden.path) { try? fm.removeItem(at: hidden) }
            try fm.moveItem(at: url, to: hidden)
            do {
                try fm.copyItem(at: hidden, to: url)
                let handle = try FileHandle(forWritingTo: hidden)
                try handle.write(contentsOf: data)
                try handle.truncate(atOffset: UInt64(data.count))
                try handle.close()
            } catch {
                // Put the original back under its name before giving up.
                try? fm.removeItem(at: url)
                try? fm.moveItem(at: hidden, to: url)
                throw Failure.cannotReplace(error.localizedDescription)
            }
            sourceToMove = hidden
        }

        if preserveDates, let attributes = try? fm.attributesOfItem(atPath: url.path) {
            var dates: [FileAttributeKey: Any] = [:]
            if let created = attributes[.creationDate] { dates[.creationDate] = created }
            if let modified = attributes[.modificationDate] { dates[.modificationDate] = modified }
            try? fm.setAttributes(dates, ofItemAtPath: sourceToMove.path)
        }

        // Trash the original; fall back to a ~bak rename on volumes without a Trash.
        var revertURL: URL?
        if !isDropbox, let trashed = trash(url) {
            revertURL = trashed
        } else {
            let backup = folder.appending(path: "\(url.lastPathComponent)~bak.\(url.pathExtension)")
            try? fm.removeItem(at: backup)
            do {
                try fm.moveItem(at: url, to: backup)
            } catch {
                throw Failure.cannotReplace(error.localizedDescription)
            }
            if isDropbox { sleep(1) }
            revertURL = trash(backup) ?? backup
        }

        do {
            try fm.moveItem(at: sourceToMove, to: url)
        } catch {
            // Try to restore the original so the user never loses the file.
            if let revertURL { try? fm.moveItem(at: revertURL, to: url) }
            throw Failure.cannotReplace(error.localizedDescription)
        }
        if isDropbox { sleep(1) }
        removeStaleAttributes(url)
        return Outcome(url: url, revertURL: revertURL)
    }

    /// Moves the original back into place.
    static func revert(original url: URL, from revertURL: URL, expectedSize: Int) throws -> URL {
        let fm = FileManager.default
        guard TempFile.size(of: revertURL) == expectedSize else {
            throw Failure.cannotReplace("the saved original has changed")
        }
        var result: NSURL?
        try fm.replaceItem(at: url, withItemAt: revertURL, backupItemName: nil, options: .usingNewMetadataOnly, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    private static func trash(_ url: URL) -> URL? {
        var trashed: NSURL?
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil {
            return trashed as URL?
        }
        return nil
    }

    /// Finder info, resource forks, quarantine flags and download origins describe the old bytes.
    private static func removeStaleAttributes(_ url: URL) {
        let stale = ["com.apple.FinderInfo", "com.apple.ResourceFork", "com.apple.quarantine", "com.apple.metadata:kMDItemWhereFroms"]
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            for name in stale { removexattr(path, name, 0) }
        }
    }
}
