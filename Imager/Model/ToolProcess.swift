import Foundation
import Synchronization

/// Runs one of the bundled command-line optimizers. The call suspends until the process exits,
/// cancelling the task kills the process, and the combined stdout/stderr comes back as text.
nonisolated enum ToolProcess {
    struct Result: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    enum Failure: Error, LocalizedError {
        case missingExecutable(String)
        case launchFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable(let name): "\(name) is missing from the app"
            case .launchFailed(let name, let reason): "\(name) could not start: \(reason)"
            }
        }
    }

    /// The optimizers live next to the app's own executable (Contents/MacOS).
    static func helper(_ name: String) throws -> URL {
        if let url = Bundle.main.url(forAuxiliaryExecutable: name), FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw Failure.missingExecutable(name)
    }

    /// - Parameters:
    ///   - standardInput: a file to feed on stdin; otherwise stdin is empty.
    ///   - standardOutput: a file that receives stdout; otherwise stdout is captured with stderr.
    ///   - timeout: seconds after which the process is terminated; the result then says so.
    static func run(
        _ executable: URL,
        arguments: [String],
        standardInput: URL? = nil,
        standardOutput: URL? = nil,
        timeout: TimeInterval? = nil,
        lowPriority: Bool = false
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = lowPriority ? .utility : .userInitiated
        var environment = ProcessInfo.processInfo.environment
        environment["NSUnbufferedIO"] = "YES"
        process.environment = environment

        if let standardInput {
            process.standardInput = try FileHandle(forReadingFrom: standardInput)
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let capture = Pipe()
        let buffer = Mutex(Data())
        capture.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.withLock { $0.append(data) }
            }
        }
        process.standardError = capture
        var outputHandle: FileHandle?
        if let standardOutput {
            FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
            let handle = try FileHandle(forWritingTo: standardOutput)
            outputHandle = handle
            process.standardOutput = handle
        } else {
            process.standardOutput = capture
        }

        let timedOut = Mutex(false)
        let launchError = Mutex<String?>(nil)
        let watchdog: Task<Void, Never>? = timeout.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, process.isRunning else { return }
                timedOut.withLock { $0 = true }
                process.terminate()
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    launchError.withLock { $0 = "cancelled" }
                    continuation.resume()
                    return
                }
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                    if lowPriority {
                        // Only when asked: on Apple silicon a lower priority pins work to efficiency cores.
                        setpriority(PRIO_PROCESS, id_t(process.processIdentifier), 10)
                    }
                } catch {
                    process.terminationHandler = nil
                    launchError.withLock { $0 = error.localizedDescription }
                    continuation.resume()
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        watchdog?.cancel()

        capture.fileHandleForReading.readabilityHandler = nil
        if launchError.withLock({ $0 }) == nil, let rest = try? capture.fileHandleForReading.readToEnd(), !rest.isEmpty {
            buffer.withLock { $0.append(rest) }
        }
        try? outputHandle?.close()
        try? capture.fileHandleForReading.close()
        try? capture.fileHandleForWriting.close()

        if let reason = launchError.withLock({ $0 }) {
            if reason == "cancelled" { throw CancellationError() }
            throw Failure.launchFailed(executable.lastPathComponent, reason)
        }
        try Task.checkCancellation()

        let output = String(decoding: buffer.withLock { $0 }, as: UTF8.self)
        return Result(status: process.terminationStatus, output: output, timedOut: timedOut.withLock { $0 })
    }
}
