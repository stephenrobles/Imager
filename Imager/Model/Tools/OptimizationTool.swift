import Foundation

/// The file a tool starts from: the original, or the smallest result so far.
nonisolated struct ToolInput: Sendable {
    let url: URL
    let size: Int
    let kind: ImageKind

    var isLarge: Bool { kind.isLarge(size) }
    var isSmall: Bool { kind.isSmall(size) }
}

nonisolated struct ToolOptions: Sendable {
    let lowPriority: Bool
}

nonisolated enum ToolFailure: Error, LocalizedError {
    case exited(tool: String, status: Int32, output: String)
    case timedOut(tool: String)

    var errorDescription: String? {
        switch self {
        case .exited(let tool, let status, let output):
            let detail = output.split(whereSeparator: \.isNewline).last.map { " (\($0.trimmingCharacters(in: .whitespaces)))" } ?? ""
            return "\(tool) failed with status \(status)\(detail)"
        case .timedOut(let tool):
            return "\(tool) took too long and was stopped"
        }
    }
}

/// One optimizer. A job runs several on the same file and keeps whichever output is smallest.
nonisolated protocol OptimizationTool: Sendable {
    /// Shown in the Best Tool column and in tooltips.
    var name: String { get }
    /// Folded into the results cache key so changed settings invalidate "already optimal" entries.
    var settingsKey: String { get }
    /// True when the output differs in more than its compression: pixels re-encoded, metadata
    /// dropped. These run first, one at a time, so the pure recompressors start from their result.
    var changesContent: Bool { get }
    /// Returns the output when the tool produced one worth comparing, nil when it declined.
    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile?
}

extension OptimizationTool {
    /// Runs a bundled helper and turns a non-zero exit into an error.
    func runHelper(_ helper: String, _ arguments: [String], standardInput: URL? = nil, standardOutput: URL? = nil,
                   timeout: TimeInterval? = nil, options: ToolOptions, acceptedStatuses: Set<Int32> = [0]) async throws -> ToolProcess.Result {
        let executable = try ToolProcess.helper(helper)
        let result = try await ToolProcess.run(executable, arguments: arguments, standardInput: standardInput,
                                               standardOutput: standardOutput, timeout: timeout, lowPriority: options.lowPriority)
        if result.timedOut { throw ToolFailure.timedOut(tool: name) }
        guard acceptedStatuses.contains(result.status) else {
            throw ToolFailure.exited(tool: name, status: result.status, output: result.output)
        }
        return result
    }

    /// Copies the input somewhere a tool can modify it in place.
    func scratchCopy(of input: ToolInput, tool: String) throws -> URL {
        let url = TempFile.makeURL(tool: tool, extension: input.url.pathExtension.isEmpty ? input.kind.rawValue : input.url.pathExtension)
        try FileManager.default.copyItem(at: input.url, to: url)
        return url
    }

    /// Mirrors the original app: slower levels get more time, big files a little more still.
    func timeLimit(level: Int, size: Int) -> TimeInterval {
        let bySize = 10 + size / 1024
        let byLevel = 8 + level * 13
        return TimeInterval(min(byLevel, bySize))
    }
}
