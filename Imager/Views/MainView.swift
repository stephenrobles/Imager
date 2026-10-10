import AppKit
import QuickLook
import SwiftUI

struct MainView: View {
    @Environment(OptimizationQueue.self) private var queue
    @Bindable private var settings = AppSettings.shared
    @State private var dropTargeted = false
    @State private var quickLookURL: URL?

    var body: some View {
        @Bindable var queue = queue
        Table(queue.jobs, selection: $queue.selection) {
            TableColumn("File") { job in
                FileCell(job: job)
            }
            .width(min: 180, ideal: 300)

            TableColumn("Original") { job in
                SizeText(job.originalSize)
            }
            .width(min: 70, ideal: 84, max: 120)
            .alignment(.trailing)

            TableColumn("Optimized") { job in
                SizeText(job.isBusy || job.status.isFinished ? job.currentSize : nil)
            }
            .width(min: 70, ideal: 84, max: 120)
            .alignment(.trailing)

            TableColumn("Savings") { job in
                SavingsCell(job: job)
            }
            .width(min: 96, ideal: 130, max: 180)

            TableColumn("Best Tool") { job in
                Text(job.bestTool ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 170)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: OptimizationJob.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            quickLook(ids)
        }
        .onDeleteCommand { queue.remove(queue.selection) }
        .onKeyPress(.space) {
            quickLook(queue.selection)
            return .handled
        }
        .quickLookPreview($quickLookURL, in: queue.jobs.map(\.url))
        .overlay {
            if queue.jobs.isEmpty {
                DropZoneView(onChoose: queue.openPanel)
                    .background(.background)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Imager")
        .onChange(of: queue.isBusy, initial: true) { _, _ in queue.noteBusy() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { queue.openPanel() } label: {
                Label("Add Images", systemImage: "plus")
            }
            .help("Add images or folders (⌘O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(selection: $settings.convertFormat) {
                ForEach(ConvertFormat.allCases, id: \.self) { format in
                    Text(format == .keep ? "Keep Format" : "Convert to \(format.title)").tag(format)
                }
            } label: {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .pickerStyle(.menu)
            .help("Re-encode dropped images in another format (AVIF, HEIC, JPEG or PNG) before optimizing. Quality is set in Settings › Convert.")

            Toggle(isOn: $settings.lossy) {
                Label("Lossy", systemImage: "wand.and.sparkles")
            }
            .toggleStyle(.button)
            .help("Lossy re-encodes images above the quality levels in Settings for much smaller files. Off, every pixel stays the same.")

            if queue.isBusy {
                Button { queue.stopAll() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop optimizing; the best result so far is kept (⌘.)")
            }
            Button { queue.optimizeAgain() } label: {
                Label("Optimize Again", systemImage: "arrow.clockwise")
            }
            .disabled(!queue.canOptimizeAgain)
            .help("Run the selected files again, or every file when nothing is selected (⌘R)")
            Button { queue.clearFinished() } label: {
                Label("Clear Finished", systemImage: "xmark.circle")
            }
            .disabled(!queue.canClearFinished)
            .help("Remove finished files from the list (⌘K)")
        }
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<OptimizationJob.ID>) -> some View {
        let targets = queue.jobs.filter { ids.contains($0.id) }
        Button("Optimize Again") {
            queue.selection = ids
            queue.optimizeAgain()
        }
        .disabled(!targets.contains { !$0.isBusy })
        Button("Stop") { queue.stop(ids) }
            .disabled(!targets.contains(where: \.isBusy))
        Button("Revert to Original") { queue.revert(ids) }
            .disabled(!targets.contains(where: \.canRevert))
        Divider()
        Button("Show in Finder") { queue.showInFinder(ids) }
        Button("Quick Look") { quickLook(ids) }
        Divider()
        Button("Remove from List") { queue.remove(ids) }
    }

    private func quickLook(_ ids: Set<OptimizationJob.ID>) {
        guard let job = queue.jobs.first(where: { ids.contains($0.id) }) else { return }
        quickLookURL = job.url
    }
}

// MARK: - Cells

struct FileCell: View {
    let job: OptimizationJob

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: job.status)
                .frame(width: 16)
            Text(job.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(job.statusDescription)
    }
}

struct StatusIcon: View {
    let status: OptimizationJob.Status

    var body: some View {
        switch status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .inspecting, .running, .converting:
            ProgressView()
                .controlSize(.small)
        case .optimized, .converted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unchanged:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        case .reverted:
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

struct SizeText: View {
    let bytes: Int?

    init(_ bytes: Int?) { self.bytes = bytes }

    var body: some View {
        Text(bytes.map(Format.size) ?? "")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// The percentage saved with a small bar behind it that fills as tools find smaller results.
struct SavingsCell: View {
    let job: OptimizationJob

    var body: some View {
        if let savings = job.savings {
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(savings > 0 ? Color.green : (savings < 0 ? Color.orange : Color.secondary))
                            .frame(width: max(savings != 0 ? 3 : 0, geometry.size.width * min(1, abs(savings))))
                    }
                }
                .frame(height: 6)
                .frame(maxWidth: 70)
                // A conversion can make a file bigger (JPEG to PNG, say); show that honestly.
                Text(savings < 0 ? "+\(Format.percent(-savings))" : Format.percent(savings))
                    .monospacedDigit()
                    .foregroundStyle(savings > 0 ? .primary : (savings < 0 ? Color.orange : .secondary))
                    .frame(width: 52, alignment: .trailing)
                    .help(savings < 0 ? "The converted file is larger than the original" : "")
            }
            .animation(.default, value: savings)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(OptimizationQueue.self) private var queue
    private var settings = AppSettings.shared

    var body: some View {
        let summary = queue.summary
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if queue.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(text(for: summary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer()
                if settings.convertFormat != .keep {
                    Label(settings.convertFormat.isLossy ? "To \(settings.convertFormat.title) · \(settings.convertQuality)%" : "To \(settings.convertFormat.title)",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .help("Dropped images are converted to \(settings.convertFormat.title) first. Change this in the toolbar or Settings › Convert.")
                }
                if settings.lossy {
                    Label(settings.snapshot.lossySummary.map { "Lossy · \($0)" } ?? "Lossy", systemImage: "wand.and.sparkles")
                        .foregroundStyle(.secondary)
                        .help("Images above these quality levels are re-encoded. Change the levels in Settings › Quality.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }

    private func text(for summary: OptimizationQueue.Summary) -> String {
        if summary.optimizedFiles > 0, summary.savedBytes > 0 {
            let saved = Format.size(summary.savedBytes)
            let total = Format.size(summary.originalBytes)
            if summary.optimizedFiles == 1 {
                return "Saved \(saved) out of \(total) (\(Format.percent(summary.overallSaving)))"
            }
            // Show whichever figure tells the truer story: a few huge wins, or steady gains everywhere.
            if summary.overallSaving * 0.8 > summary.averageSaving {
                return "Saved \(saved) out of \(total). \(Format.percent(summary.overallSaving)) overall, up to \(Format.percent(summary.bestSaving)) per file"
            }
            return "Saved \(saved) out of \(total). \(Format.percent(summary.averageSaving)) per file on average, up to \(Format.percent(summary.bestSaving))"
        }
        if queue.pendingFolderScans > 0 {
            return "Looking for images…"
        }
        if summary.busy > 0 {
            return summary.busy == 1 ? "Optimizing 1 file…" : "Optimizing \(summary.busy) files…"
        }
        if summary.files > 0 {
            return "Nothing more to save"
        }
        return "Drop images or folders anywhere in this window"
    }
}
