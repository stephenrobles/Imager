import AppKit
import SwiftUI

struct AppCommands: Commands {
    let updater: AppUpdater
    let queue: OptimizationQueue
    private var settings = AppSettings.shared

    init(updater: AppUpdater, queue: OptimizationQueue) {
        self.updater = updater
        self.queue = queue
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button("Add Images…") { queue.openPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .saveItem) {
            Button("Show in Finder") { queue.showInFinder(queue.selection) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(queue.selection.isEmpty)
            Divider()
            Button("Remove from List") { queue.remove(queue.selection) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(queue.selection.isEmpty)
        }

        CommandMenu("Optimize") {
            Button("Optimize Again") { queue.optimizeAgain() }
                .keyboardShortcut("r")
                .disabled(!queue.canOptimizeAgain)
            Button("Optimize Again (Only Optimized Files)") { queue.optimizeAgain(onlyOptimized: true) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!queue.canOptimizeOptimizedAgain)
            Button("Stop") { queue.selection.isEmpty ? queue.stopAll() : queue.stop(queue.selection) }
                .keyboardShortcut(".")
                .disabled(!queue.canStop)
            Button("Revert to Original") { queue.revert(queue.selection) }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!queue.canRevert)
            Divider()
            Button("Clear Finished") { queue.clearFinished() }
                .keyboardShortcut("k")
                .disabled(!queue.canClearFinished)
            Divider()
            Picker("Mode", selection: Binding(get: { settings.lossy }, set: { settings.lossy = $0 })) {
                Text("Lossless").tag(false)
                Text("Lossy").tag(true)
            }
            .pickerStyle(.inline)
            Picker("Convert To", selection: Binding(get: { settings.convertFormat }, set: { settings.convertFormat = $0 })) {
                ForEach(ConvertFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Quick Look") { quickLook() }
                .keyboardShortcut("y")
                .disabled(queue.selection.isEmpty)
            Divider()
        }
    }

    private func quickLook() {
        // The table handles the space bar itself; the menu item reaches it through the same path.
        NSApp.sendAction(#selector(NSResponder.quickLookPreviewItems(_:)), to: nil, from: nil)
    }
}
