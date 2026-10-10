import Foundation

/// jpegoptim: Huffman optimization, metadata stripping and, in lossy mode, re-encoding at a quality cap.
nonisolated struct JpegoptimTool: OptimizationTool {
    /// 100 means lossless.
    let maxQuality: Int
    let strip: Bool

    var name: String { lossy ? "jpegoptim \(maxQuality)%" : "jpegoptim" }
    var settingsKey: String { "jpegoptim:\(maxQuality):\(strip)" }
    var changesContent: Bool { lossy || strip }

    private var lossy: Bool { maxQuality > 10 && maxQuality < 100 }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        let scratch = try scratchCopy(of: input, tool: "jpegoptim")
        var arguments = [
            strip ? "--strip-all" : "--strip-none",
            // Lossless progressive is jpegtran's job; a lossy baseline would stop the two sharing work.
            lossy ? "--all-progressive" : "--all-normal",
            "-q", "--", scratch.path,
        ]
        if lossy { arguments.insert("-m\(maxQuality)", at: 0) }
        _ = try await runHelper("jpegoptim", arguments, options: options)
        guard let file = TempFile(url: scratch) else { return nil }
        // A lossy pass must pay for itself: at least 5% smaller, or the pixels stay untouched.
        if lossy, Double(file.size) > Double(input.size) * 0.95 { return nil }
        return file
    }
}

/// jpegtran from MozJPEG: lossless re-encoding with optimized progressive scans.
nonisolated struct JpegtranTool: OptimizationTool {
    let strip: Bool

    var name: String { "MozJPEG" }
    var settingsKey: String { "mozjpeg:\(strip)" }
    var changesContent: Bool { false }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        let output = TempFile.makeURL(tool: "jpegtran", extension: "jpg")
        _ = try await runHelper("jpegtran", ["-copy", strip ? "none" : "all", "-optimize", "-outfile", output.path, input.url.path], options: options)
        return TempFile(url: output)
    }
}
