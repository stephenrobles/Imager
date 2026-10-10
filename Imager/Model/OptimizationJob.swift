import AppKit
import Foundation
import Observation

/// One image in the list: where it is, what happened to it, and the work in flight.
@Observable
final class OptimizationJob: Identifiable {
    enum Status: Equatable {
        case waiting
        case inspecting
        case converting(String)
        case running(String)
        case optimized(String)
        case converted(String)
        case unchanged
        case stopped
        case reverted
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .waiting, .inspecting, .converting, .running: true
            default: false
            }
        }

        var isFinished: Bool { !isBusy }
    }

    let id = UUID()
    private(set) var url: URL
    private(set) var displayName: String
    private(set) var kind: ImageKind?
    private(set) var status: Status = .waiting
    /// Size when the file was first added (or when it changed on disk).
    private(set) var originalSize: Int?
    /// The smallest size seen so far, live while tools run.
    private(set) var currentSize: Int?
    private(set) var savedSize: Int?
    private(set) var bestTool: String?
    private(set) var revertURL: URL?
    private(set) var revertSize: Int?
    private(set) var lossyUsed = false
    /// True from start until the pipeline (and the save) has finished.
    private(set) var isBusy = false
    /// Where the file was before a conversion gave it a new name.
    private(set) var originalURL: URL?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runCount = 0
    @ObservationIgnored private var best: TempFile?
    /// Size each tool got the file down to, for the Best Tool column.
    @ObservationIgnored private var toolResults: [String: Int] = [:]

    init(url: URL) {
        self.url = url
        displayName = FileManager.default.displayName(atPath: url.path)
    }

    var isOptimized: Bool {
        switch status {
        case .optimized, .converted: true
        default: false
        }
    }

    var canRevert: Bool { revertURL != nil && !isBusy }

    /// Fraction saved so far (negative when a conversion made the file bigger), nil until there is
    /// something to show.
    var savings: Double? {
        guard let originalSize, originalSize > 0, let currentSize else { return nil }
        if currentSize >= originalSize, originalURL == nil { return status.isFinished ? 0 : nil }
        return 1 - Double(currentSize) / Double(originalSize)
    }

    var statusDescription: String {
        switch status {
        case .waiting: "Waiting to be optimized"
        case .inspecting: "Inspecting the file"
        case .converting(let format): "Converting to \(format)"
        case .running(let tool): "Running \(tool)"
        case .optimized(let tool): "Optimized with \(tool)"
        case .converted(let format): "Converted to \(format)"
        case .unchanged: "Already as small as these tools can make it"
        case .stopped: "Stopped"
        case .reverted: "Reverted to the original"
        case .failed(let message): message
        }
    }

    // MARK: - Control

    func start(queue: OptimizationQueue) {
        guard task == nil else { return }
        status = .waiting
        isBusy = true
        task = Task { [weak self, weak queue] in
            guard let self, let queue else { return }
            await run(queue: queue)
            task = nil
            isBusy = false
            queue.jobDidFinish(self)
        }
    }

    /// Stops the tools; whatever is smallest so far is still saved.
    func stop() {
        task?.cancel()
    }

    /// Puts the original back from the Trash.
    func revert() -> Bool {
        guard canRevert, let revertURL, let revertSize else { return false }
        do {
            if let originalURL {
                try FileSaver.revertConversion(converted: url, original: originalURL, from: revertURL, expectedSize: revertSize)
                url = originalURL
                self.originalURL = nil
                displayName = FileManager.default.displayName(atPath: url.path)
                kind = nil
            } else {
                url = try FileSaver.revert(original: url, from: revertURL, expectedSize: revertSize)
            }
            self.revertURL = nil
            self.revertSize = nil
            savedSize = nil
            best = nil
            originalSize = revertSize
            currentSize = revertSize
            bestTool = nil
            toolResults = [:]
            lossyUsed = false
            runCount = 0
            status = .reverted
            return true
        } catch {
            status = .failed("Couldn't revert: \(error.localizedDescription)")
            return false
        }
    }

    func cleanUp() {
        task?.cancel()
        best = nil
    }

    // MARK: - The pipeline

    private func run(queue: OptimizationQueue) async {
        let settings = AppSettings.shared.snapshot
        status = .inspecting
        toolResults = [:]

        let probe: (kind: ImageKind?, size: Int)
        do {
            probe = try await Self.probe(url)
        } catch {
            fail("Can't open the file")
            return
        }
        guard var kind = probe.kind else {
            fail(settings.isConverting ? "Not an image Imager can read" : "Not a PNG, JPEG, GIF or SVG file")
            return
        }
        self.kind = kind
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            fail("The file isn't writable")
            return
        }

        // A second run keeps the original size for the savings column, unless the file changed.
        let changedSinceSave = savedSize != nil && savedSize != probe.size
        let ranBefore = originalSize != nil && !changedSinceSave
        if !ranBefore {
            originalSize = probe.size
            savedSize = nil
            revertURL = nil
            revertSize = nil
            originalURL = nil
            bestTool = nil
            lossyUsed = false
            runCount = 0
        }
        best = nil
        currentSize = probe.size
        var size = probe.size
        var convertedTo: ConvertFormat?

        // Conversion comes first; the optimizers then see the new file.
        if settings.isConverting, let target = settings.convertFormat.kind, kind != target, kind.isConvertible {
            status = .converting(settings.convertFormat.title)
            do {
                if let converted = try await Self.convert(url: url, settings: settings) {
                    let outcome = try await Self.place(original: url, converted: converted, settings: settings)
                    originalURL = url
                    url = outcome.url
                    displayName = FileManager.default.displayName(atPath: url.path)
                    if let trashed = outcome.revertURL, revertURL == nil {
                        revertURL = trashed
                        revertSize = probe.size
                    }
                    kind = target
                    self.kind = target
                    size = converted.size
                    savedSize = size
                    currentSize = size
                    convertedTo = settings.convertFormat
                    toolResults[settings.convertFormat.title] = size
                    bestTool = settings.convertFormat.title
                }
            } catch is CancellationError {
                status = .stopped
                return
            } catch {
                fail(error.localizedDescription)
                return
            }
        }

        guard kind.isOptimizable else {
            if let convertedTo {
                status = .converted(convertedTo.title)
            } else if settings.isConverting, settings.convertFormat.kind == kind {
                status = .unchanged
                bestTool = nil
            } else {
                fail("\(kind.name) files can be converted, not optimized. Pick a format in the toolbar.")
            }
            return
        }

        let level = min(settings.level + (ranBefore ? 1 : 0), AppSettings.levelRange.upperBound + 1)
        let input = ToolInput(url: url, size: size, kind: kind)

        let plan = Self.plan(for: input, settings: settings, level: level, ranBefore: ranBefore, lossyAlreadyApplied: lossyUsed)
        guard !plan.first.isEmpty || !plan.later.isEmpty else {
            if let convertedTo {
                status = .converted(convertedTo.title)
            } else {
                fail("Every tool for \(kind.name) files is turned off in Settings")
            }
            return
        }
        if settings.lossy, plan.first.contains(where: \.changesContent) || plan.later.contains(where: \.changesContent) {
            lossyUsed = lossyUsed || plan.usesLossy
        }
        runCount += 1

        let settingsKey = (plan.first + plan.later).map(\.settingsKey).joined(separator: "|")
        let cacheKey: Data?
        do {
            cacheKey = try await Self.cacheKey(url: url, settingsKey: settingsKey)
        } catch {
            cacheKey = nil
        }
        if convertedTo == nil, let cacheKey, await queue.cache.contains(cacheKey) {
            status = .unchanged
            return
        }

        let options = ToolOptions(lowPriority: settings.lowPriority)
        var failure: Error?
        var wasStopped = false
        do {
            for tool in plan.first {
                try Task.checkCancellation()
                status = .running(tool.name)
                await queue.scheduler.acquire()
                defer { Task { await queue.scheduler.release() } }
                let output = try await Self.perform(tool, input: currentInput, options: options)
                consider(output, from: tool)
            }
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: (String, TempFile?).self) { group in
                for tool in plan.later {
                    group.addTask { [self] in
                        await queue.scheduler.acquire()
                        defer { Task { await queue.scheduler.release() } }
                        try Task.checkCancellation()
                        // Each tool starts from whatever is smallest when its turn comes.
                        let input = await self.currentInput
                        await self.noteRunning(tool.name)
                        return (tool.name, try await Self.perform(tool, input: input, options: options))
                    }
                }
                for try await (name, output) in group {
                    considerResult(output, toolName: name)
                }
            }
        } catch is CancellationError {
            wasStopped = true
        } catch {
            failure = error
        }

        // Save whatever is smallest, even after a stop or a tool failure.
        if let best, best.size < (savedSize ?? originalSize ?? Int.max) {
            do {
                let outcome = try await Self.save(url: url, best: best, settings: settings)
                url = outcome.url
                if revertURL == nil, let trashed = outcome.revertURL {
                    revertURL = trashed
                    revertSize = savedSize ?? originalSize
                }
                savedSize = best.size
                currentSize = best.size
                self.best = nil
                status = convertedTo.map { .converted($0.title) } ?? .optimized(bestTool ?? "")
            } catch {
                self.best = nil
                fail(error.localizedDescription)
            }
        } else if let failure {
            fail(failure.localizedDescription)
        } else if wasStopped {
            status = .stopped
            currentSize = savedSize ?? originalSize
        } else if let convertedTo {
            status = .converted(convertedTo.title)
            currentSize = savedSize ?? originalSize
        } else {
            status = .unchanged
            currentSize = savedSize ?? originalSize
            if let cacheKey, !settings.lossy || !plan.usesLossy {
                await queue.cache.rememberUnoptimizable(cacheKey, size: probe.size)
            }
        }
    }

    private func fail(_ message: String) {
        status = .failed(message)
        currentSize = savedSize ?? originalSize
    }

    /// The file the next tool should start from.
    private var currentInput: ToolInput {
        if let best, let kind { return ToolInput(url: best.url, size: best.size, kind: kind) }
        return ToolInput(url: url, size: savedSize ?? originalSize ?? 0, kind: kind ?? .png)
    }

    private func noteRunning(_ tool: String) {
        if case .running = status { return }
        status = .running(tool)
    }

    private func consider(_ output: TempFile?, from tool: any OptimizationTool) {
        considerResult(output, toolName: tool.name)
    }

    private func considerResult(_ output: TempFile?, toolName: String) {
        guard let output else { return }
        let reference = best?.size ?? savedSize ?? originalSize ?? Int.max
        toolResults[toolName] = output.size
        guard output.size > 0, output.size < reference else { return }
        best = output
        currentSize = output.size
        updateBestTool()
    }

    /// Credits the tool that got the file smallest; when a different tool took the biggest single
    /// bite, both are named, like "pngquant+Zopfli".
    private func updateBestTool() {
        guard let originalSize else { return }
        var smallestTool: String?
        var smallest = originalSize
        var biggestStepTool: String?
        var biggestStep = 0.0
        var previous = Double(originalSize)
        for (tool, size) in toolResults.sorted(by: { $0.value > $1.value }) {
            if size < smallest { smallest = size; smallestTool = tool }
            let step = previous / Double(max(size, 1))
            if step > biggestStep { biggestStep = step; biggestStepTool = tool }
            previous = min(previous, Double(size))
        }
        if let smallestTool, let biggestStepTool, smallestTool != biggestStepTool {
            bestTool = "\(biggestStepTool)+\(smallestTool)"
        } else {
            bestTool = smallestTool ?? biggestStepTool
        }
    }

    // MARK: - Planning

    nonisolated struct Plan {
        /// Tools that change the content (lossy passes, metadata stripping); run in order, one at a time.
        var first: [any OptimizationTool] = []
        /// Pure recompressors; run in parallel, each starting from the smallest file so far.
        var later: [any OptimizationTool] = []
        var usesLossy = false
    }

    nonisolated static func plan(for input: ToolInput, settings: SettingsSnapshot, level: Int, ranBefore: Bool, lossyAlreadyApplied: Bool) -> Plan {
        var plan = Plan()
        var ordered: [any OptimizationTool] = []
        let level = max(0, level)

        switch input.kind {
        case .png:
            if settings.lossy, settings.pngquantEnabled, !lossyAlreadyApplied, settings.pngQuality > 30, settings.pngQuality < 100 {
                plan.first.append(PngquantTool(minQuality: settings.pngQuality, level: level))
                plan.usesLossy = true
            }
            var pngcrush = settings.pngcrushEnabled
            if level < 2, settings.optipngEnabled { pngcrush = false } // OptiPNG covers it at low effort
            if pngcrush { ordered.append(PngcrushTool(level: level, strip: settings.stripPNGMetadata)) }
            if settings.optipngEnabled { ordered.append(OptiPNGTool(level: level, strip: settings.stripPNGMetadata)) }
            if settings.advpngEnabled { ordered.append(AdvPNGTool(level: level)) }
            if settings.zopfliEnabled { ordered.append(ZopfliTool(level: level, strip: settings.stripPNGMetadata, alternativeStrategy: ranBefore)) }
        case .jpeg:
            let quality = settings.lossy ? settings.jpegQuality : 100
            if settings.jpegoptimEnabled { ordered.append(JpegoptimTool(maxQuality: quality, strip: settings.stripJPEGMetadata)) }
            if settings.jpegtranEnabled { ordered.append(JpegtranTool(strip: settings.stripJPEGMetadata)) }
            if quality < 100, settings.jpegoptimEnabled { plan.usesLossy = true }
        case .gif:
            if settings.gifsicleEnabled {
                if settings.lossy, !lossyAlreadyApplied, settings.gifQuality > 30, settings.gifQuality < 100 {
                    plan.first.append(GifsicleTool(quality: settings.gifQuality, interlace: false))
                    plan.usesLossy = true
                }
                // The lossless pass always runs, so a declined lossy result still leaves a smaller file.
                ordered.append(GifsicleTool(quality: 100, interlace: false))
                if level > 1 { ordered.append(GifsicleTool(quality: 100, interlace: true)) }
            }
        case .svg:
            if settings.svgoEnabled {
                ordered.append(SVGOTool(lossy: settings.lossy))
                if settings.lossy { plan.usesLossy = true }
            }
        default:
            break
        }

        // Tools with side effects go first so the recompressors don't redo their work.
        for tool in ordered {
            if tool.changesContent { plan.first.append(tool) } else { plan.later.append(tool) }
        }
        return plan
    }

    // MARK: - Off the main thread

    @concurrent
    private static func probe(_ url: URL) async throws -> (kind: ImageKind?, size: Int) {
        let size = TempFile.size(of: url) ?? 0
        guard size > 0 else { throw CocoaError(.fileReadUnknown) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4096) ?? Data()
        return (ImageKind.detect(head, url: url), size)
    }

    @concurrent
    private static func cacheKey(url: URL, settingsKey: String) async throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return ResultsCache.key(settings: settingsKey, data: data)
    }

    @concurrent
    private static func perform(_ tool: any OptimizationTool, input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        try await tool.run(input, options: options)
    }

    @concurrent
    private static func convert(url: URL, settings: SettingsSnapshot) async throws -> TempFile? {
        try Task.checkCancellation()
        let strip = settings.convertFormat == .png ? settings.stripPNGMetadata : settings.stripJPEGMetadata
        return try ImageConverter.convert(url, to: settings.convertFormat, quality: settings.convertQuality, stripMetadata: strip)
    }

    @concurrent
    private static func place(original: URL, converted: TempFile, settings: SettingsSnapshot) async throws -> FileSaver.Outcome {
        try FileSaver.placeConverted(original: original, converted: converted, fileExtension: settings.convertFormat.fileExtension,
                                     keepOriginal: settings.keepOriginalWhenConverting, preserveDates: settings.preserveDates)
    }

    @concurrent
    private static func save(url: URL, best: TempFile, settings: SettingsSnapshot) async throws -> FileSaver.Outcome {
        try FileSaver.replace(original: url, with: best, preservePermissions: settings.preservePermissions, preserveDates: settings.preserveDates)
    }
}
