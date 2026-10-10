import SwiftUI

struct DropZoneView: View {
    let onChoose: () -> Void

    @Bindable private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 148, height: 148)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 8) {
                Text("Drop images to shrink them")
                    .font(.title2.weight(.semibold))
                Text("PNG, JPEG, GIF and SVG files, or whole folders. Each file is replaced with a smaller copy and the original goes to the Trash. Everything runs on this Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            Button("Choose Images…", action: onChoose)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            HStack(spacing: 6) {
                Text("Optimization")
                    .foregroundStyle(.secondary)
                Picker("Optimization", selection: $settings.lossy) {
                    Text("Lossless").tag(false)
                    Text("Lossy").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Button("Settings…") { openSettings() }
                    .buttonStyle(.link)
                    .padding(.leading, 6)
            }
            .font(.callout)
            .help("Lossless keeps every pixel and only removes what you can't see. Lossy also re-encodes images above the quality levels in Settings for much smaller files.")
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
