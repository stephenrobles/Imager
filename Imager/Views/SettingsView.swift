import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(AppUpdater.self) private var updater
    @Environment(OptimizationQueue.self) private var queue
    @State private var forgotCache = false

    /// Tall enough to show a tab without scrolling on a big display, never taller than the screen.
    private var windowHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(600, screen - 110)
    }

    var body: some View {
        @Bindable var updater = updater
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Section("Optimization") {
                        Picker("Mode", selection: $settings.lossy) {
                            Text("Lossless").tag(false)
                            Text("Lossy").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        Text("Lossless never changes a pixel: only invisible metadata is removed and the data is recompressed, so it is safe to run on any file as often as you like. Lossy also re-encodes images that are above the quality levels in the Quality tab, which usually still looks fine and gives much smaller files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Files") {
                        Toggle("Preserve file permissions, attributes and hard links", isOn: $settings.preservePermissions)
                        Toggle("Preserve creation and modification dates", isOn: $settings.preserveDates)
                        Text("Originals go to the Trash so a file can be reverted. Preserving permissions rewrites the file in place instead of replacing it, which keeps ownership, extended attributes and hard links intact.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("When Finished") {
                        Toggle("Bounce the Dock icon", isOn: $settings.bounceDockWhenDone)
                        Toggle("Show a notification", isOn: $settings.notifyWhenDone)
                            .onChange(of: settings.notifyWhenDone) { _, on in
                                if on { Notifier.requestPermission() }
                            }
                        Text("Only when Imager is in the background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Updates") {
                        Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                        HStack {
                            Button("Check Now…") { updater.checkForUpdates() }
                                .disabled(!updater.canCheckForUpdates)
                            Spacer()
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Quality", systemImage: "slider.horizontal.3") {
                Form {
                    Section("Lossy Quality") {
                        QualitySlider(title: "JPEG", value: $settings.jpegQuality)
                        QualitySlider(title: "PNG", value: $settings.pngQuality)
                        QualitySlider(title: "GIF", value: $settings.gifQuality)
                        Text(settings.lossy
                             ? "Images above these levels are re-encoded down to them; images already below are left alone. 80% is hard to tell from the original on most photos and screenshots."
                             : "These apply when the mode is set to Lossy in the General tab or the toolbar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!settings.lossy)
                    Section("Metadata") {
                        Toggle("Strip PNG metadata (gamma, color profiles, comments)", isOn: $settings.stripPNGMetadata)
                        Toggle("Strip JPEG metadata (EXIF, color profiles, GPS, rotation)", isOn: $settings.stripJPEGMetadata)
                        Text("Stripping PNG gamma and color profiles makes colors consistent across browsers, which don't all honor them. JPEG metadata includes the camera, exposure, location and any embedded copyright notice; the image stays protected by copyright either way. A JPEG that relies on its EXIF orientation flag will appear rotated once the flag is gone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver") {
                Form {
                    Section("Effort") {
                        LabeledContent("Optimization level") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Slider(value: Binding(get: { Double(settings.level) }, set: { settings.level = Int($0.rounded()) }),
                                       in: Double(AppSettings.levelRange.lowerBound)...Double(AppSettings.levelRange.upperBound), step: 1)
                                    .frame(width: 220)
                                Text(AppSettings.levelName(settings.level))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("The fastest level takes seconds per image. Slower levels compress a little better but take much longer; large PNGs can take minutes at the top. Running a file a second time raises the level by one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("PNG") {
                        Toggle("Zopfli", isOn: $settings.zopfliEnabled)
                        Toggle("OptiPNG", isOn: $settings.optipngEnabled)
                        Toggle("AdvPNG", isOn: $settings.advpngEnabled)
                        Toggle("pngcrush", isOn: $settings.pngcrushEnabled)
                        Toggle("pngquant (lossy mode only)", isOn: $settings.pngquantEnabled)
                        Text("Zopfli is the best compressor and the slowest. Zopfli and OptiPNG also clear the color of fully transparent pixels; turn them off for files whose alpha channel means something other than transparency.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("JPEG") {
                        Toggle("jpegoptim", isOn: $settings.jpegoptimEnabled)
                        Toggle("MozJPEG (jpegtran)", isOn: $settings.jpegtranEnabled)
                    }
                    Section("GIF") {
                        Toggle("Gifsicle", isOn: $settings.gifsicleEnabled)
                    }
                    Section("SVG") {
                        Toggle("SVGO", isOn: $settings.svgoEnabled)
                        Text("Lossless mode only tidies the markup. Lossy mode uses SVGO's default preset, which also rewrites paths and removes ids, titles and hidden elements.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Performance") {
                        Toggle("Run at low priority", isOn: $settings.lowPriority)
                        LabeledContent("Memory of optimized files") {
                            Button(forgotCache ? "Forgotten" : "Forget…") {
                                Task { await queue.cache.forgetAll() }
                                forgotCache = true
                            }
                            .disabled(forgotCache)
                        }
                        Text("Low priority keeps the Mac responsive during big batches but takes longer. Files that couldn't be shrunk are remembered so they are skipped next time; forget them to try again with new tool versions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 560, height: windowHeight)
    }
}

struct QualitySlider: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                       in: Double(AppSettings.qualityRange.lowerBound)...Double(AppSettings.qualityRange.upperBound), step: 5)
                Text("\(value)%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}
