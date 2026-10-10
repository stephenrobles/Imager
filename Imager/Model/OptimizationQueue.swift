import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

/// The list of files in the window and the machinery that runs them.
@Observable
final class OptimizationQueue {
    static let shared = OptimizationQueue()

    private(set) var jobs: [OptimizationJob] = []
    var selection: Set<OptimizationJob.ID> = []
    /// Folders still being walked for images.
    private(set) var pendingFolderScans = 0

    @ObservationIgnored let scheduler = CPUScheduler(limit: ProcessInfo.processInfo.activeProcessorCount)
    @ObservationIgnored let cache = ResultsCache()
    @ObservationIgnored private var jobsByPath: [String: OptimizationJob] = [:]
    @ObservationIgnored private var wasBusy = false

    private init() {}

    var isBusy: Bool { pendingFolderScans > 0 || jobs.contains { $0.isBusy } }

    var selectedJobs: [OptimizationJob] { jobs.filter { selection.contains($0.id) } }

    /// The selection, or everything when nothing is selected (how the toolbar buttons work).
    var targetJobs: [OptimizationJob] { selection.isEmpty ? jobs : selectedJobs }

    // MARK: - Adding files

    /// Files are added as they are; folders are searched for images in the background.
    func add(_ urls: [URL]) {
        var files: [URL] = []
        for raw in urls {
            let url = raw.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                scanFolder(url)
            } else {
                files.append(url)
            }
        }
        addFiles(files)
    }

    private func addFiles(_ urls: [URL]) {
        var added: [OptimizationJob] = []
        for url in urls {
            if let existing = jobsByPath[url.path] {
                // Dropping a file again re-runs it.
                if !existing.isBusy { existing.start(queue: self) }
                continue
            }
            let job = OptimizationJob(url: url)
            jobsByPath[url.path] = job
            added.append(job)
        }
        guard !added.isEmpty else { return }
        jobs.append(contentsOf: added)
        for job in added { job.start(queue: self) }
    }

    private func scanFolder(_ folder: URL) {
        pendingFolderScans += 1
        Task {
            for await batch in Self.imageBatches(in: folder) {
                addFiles(batch)
            }
            pendingFolderScans -= 1
            checkFinished()
        }
    }

    /// Walks a folder on a background thread, handing back images in growing batches so the
    /// first rows appear right away and a huge tree doesn't flood the main thread.
    nonisolated private static func imageBatches(in folder: URL) -> AsyncStream<[URL]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var batch: [URL] = []
                var batchSize = 16
                let keys: [URLResourceKey] = [.isRegularFileKey]
                if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    while let url = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }
                        guard ImageKind.isSupported(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                        batch.append(url)
                        if batch.count >= batchSize {
                            continuation.yield(batch)
                            batch.removeAll()
                            batchSize = min(256, batchSize * 4)
                        }
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = ImageKind.contentTypes + [.folder]
        panel.message = "Choose images or folders of images to shrink."
        panel.prompt = "Optimize"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    // MARK: - Actions

    /// Runs the selection (or everything) again. A second pass raises the effort level by one.
    func optimizeAgain(onlyOptimized: Bool = false) {
        var started = false
        var targets = selectedJobs
        if targets.count == 1, let only = targets.first, only.isBusy || !only.isOptimized, onlyOptimized {
            selection = []
            targets = jobs
        } else if targets.isEmpty {
            targets = jobs
        }
        for job in targets where !job.isBusy && (!onlyOptimized || job.isOptimized) {
            job.start(queue: self)
            started = true
        }
        if !started { NSSound.beep() }
    }

    var canOptimizeAgain: Bool {
        targetJobs.contains { !$0.isBusy }
    }

    var canOptimizeOptimizedAgain: Bool {
        targetJobs.contains { !$0.isBusy && $0.isOptimized }
    }

    func stop(_ ids: Set<OptimizationJob.ID>) {
        for job in jobs where ids.contains(job.id) { job.stop() }
    }

    func stopAll() {
        for job in jobs { job.stop() }
    }

    var canStop: Bool {
        (selection.isEmpty ? jobs : selectedJobs).contains { $0.isBusy }
    }

    func revert(_ ids: Set<OptimizationJob.ID>) {
        var failed = false
        for job in jobs where ids.contains(job.id) {
            if !job.revert() { failed = true }
        }
        if failed { NSSound.beep() }
    }

    var canRevert: Bool {
        selectedJobs.contains(where: \.canRevert)
    }

    func remove(_ ids: Set<OptimizationJob.ID>) {
        for job in jobs where ids.contains(job.id) {
            job.cleanUp()
            jobsByPath[job.url.path] = nil
        }
        jobs.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func clearFinished() {
        remove(Set(jobs.filter { !$0.isBusy }.map(\.id)))
    }

    var canClearFinished: Bool {
        jobs.contains { !$0.isBusy }
    }

    func showInFinder(_ ids: Set<OptimizationJob.ID>) {
        let urls = jobs.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func cleanUp() {
        for job in jobs { job.cleanUp() }
    }

    // MARK: - Finishing

    func jobDidFinish(_ job: OptimizationJob) {
        checkFinished()
    }

    private func checkFinished() {
        let busy = isBusy
        defer { wasBusy = busy }
        guard wasBusy, !busy else { return }
        let settings = AppSettings.shared
        if settings.bounceDockWhenDone, !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if settings.notifyWhenDone, !NSApp.isActive {
            Notifier.post(summary: summary)
        }
    }

    func noteBusy() {
        wasBusy = isBusy
    }

    // MARK: - Totals

    struct Summary {
        var files = 0
        var busy = 0
        var optimizedFiles = 0
        var originalBytes = 0
        var optimizedBytes = 0
        var bestSaving = 0.0
        var averageSaving = 0.0

        var savedBytes: Int { originalBytes - optimizedBytes }
        var overallSaving: Double { originalBytes > 0 ? 1 - Double(optimizedBytes) / Double(originalBytes) : 0 }
    }

    var summary: Summary {
        var summary = Summary()
        var savings = 0.0
        for job in jobs {
            summary.files += 1
            if job.isBusy { summary.busy += 1 }
            guard let original = job.originalSize, original > 0, let current = job.currentSize, current != original || job.status.isFinished else { continue }
            let saving = 1 - Double(current) / Double(original)
            summary.bestSaving = max(summary.bestSaving, saving)
            savings += saving
            summary.originalBytes += original
            summary.optimizedBytes += current
            summary.optimizedFiles += 1
        }
        if summary.optimizedFiles > 0 { summary.averageSaving = savings / Double(summary.optimizedFiles) }
        return summary
    }
}

/// A notification when a batch finishes while the app is in the background.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(summary: OptimizationQueue.Summary) {
        let content = UNMutableNotificationContent()
        content.title = "Images optimized"
        if summary.optimizedFiles > 0, summary.savedBytes > 0 {
            content.body = "Saved \(Format.size(summary.savedBytes)) across \(summary.optimizedFiles) files (\(Format.percent(summary.overallSaving)))."
        } else {
            content.body = "Finished \(summary.files) files."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
