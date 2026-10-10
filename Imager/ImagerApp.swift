import AppKit
import SwiftUI

@main
struct ImagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var updater = AppUpdater()
    @State private var queue = OptimizationQueue.shared

    init() {
        TempFile.cleanUpLeftovers()
    }

    var body: some Scene {
        Window("Imager", id: "main") {
            MainView()
                .environment(updater)
                .environment(queue)
                .frame(minWidth: 620, minHeight: 360)
        }
        .defaultSize(width: 840, height: 520)
        .commands {
            AppCommands(updater: updater, queue: queue)
        }

        Settings {
            SettingsView()
                .environment(updater)
                .environment(queue)
        }
        .windowResizability(.contentSize)
    }
}

/// Receives images opened from the Finder, the Dock icon, the Services menu, or `open -a Imager`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        OptimizationQueue.shared.add(urls)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        OptimizationQueue.shared.cleanUp()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self

        #if DEBUG
        // Development aid: IMAGER_DEBUG_OPEN=/path/a.png:/path/b.jpg adds files at launch without the Finder.
        if let list = ProcessInfo.processInfo.environment["IMAGER_DEBUG_OPEN"] {
            OptimizationQueue.shared.add(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        // Development aid: IMAGER_SNAPSHOT=/path/to.png writes a picture of the main window a few seconds after launch.
        if let path = ProcessInfo.processInfo.environment["IMAGER_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["IMAGER_SNAPSHOT_DELAY"] ?? "") ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSLog("snapshot: no window"); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSLog("snapshot: wrote %@", path)
                } catch {
                    NSLog("snapshot failed: %@", String(describing: error))
                }
                if ProcessInfo.processInfo.environment["IMAGER_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
            }
        }
        #endif
    }

    /// The "Optimize with Imager" item in the Finder's Services menu.
    @objc func optimizeFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        OptimizationQueue.shared.add(urls)
        NSApp.activate()
    }
}
