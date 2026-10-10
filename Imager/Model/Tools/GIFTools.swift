import Foundation

/// Gifsicle: frame optimization, and in lossy mode its LZW-friendly color blending.
nonisolated struct GifsicleTool: OptimizationTool {
    /// 100 means lossless.
    let quality: Int
    let interlace: Bool

    var name: String { lossy ? "Gifsicle lossy" : (interlace ? "Gifsicle interlaced" : "Gifsicle") }
    var settingsKey: String { "gifsicle:\(quality):\(interlace)" }
    var changesContent: Bool { lossy }

    private var lossy: Bool { quality < 100 }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        let output = TempFile.makeURL(tool: "gifsicle", extension: "gif")
        var arguments = [
            "-o", output.path, interlace ? "--interlace" : "--no-interlace", "-O3",
            "--careful", // Safari and Preview misdecode some aggressive optimizations.
            "--no-comments", "--no-names", "--same-delay", "--same-loopcount", "--no-warnings",
            "--", input.url.path,
        ]
        if lossy {
            var loss = Int(pow(Double(100 - quality), 1.8) / 5)
            if input.isSmall {
                loss = 1 + loss / 8 // go easy on icons
            } else if !input.isLarge {
                loss = 1 + loss / 2
            }
            arguments.insert("--lossy=\(loss)", at: 0)
        }
        _ = try await runHelper("gifsicle", arguments, options: options)
        guard let file = TempFile(url: output) else { return nil }
        if lossy {
            // Lossy only counts when it clearly beats what lossless would do.
            let required = Double(105 + (100 - quality) / 2) / 100
            if Double(file.size) * required >= Double(input.size) { return nil }
        }
        return file
    }
}
