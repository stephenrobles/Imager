import Foundation

/// pngquant: lossy palette conversion. Only used in lossy mode, always first.
nonisolated struct PngquantTool: OptimizationTool {
    let minQuality: Int
    let level: Int

    var name: String { "pngquant" }
    var settingsKey: String { "pngquant:\(minQuality)" }
    var changesContent: Bool { true }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        let maxQuality = min(100, minQuality + 20)
        let speed = max(1, min(3, 7 - level))
        let output = TempFile.makeURL(tool: "pngquant", extension: "png")
        // 98: the result would be larger. 99: quality would fall below the minimum. Both mean "skip".
        let result = try await runHelper("pngquant", [
            "--quality", "\(minQuality)-\(maxQuality)", "--speed", "\(speed)", "--skip-if-larger",
            "--output", output.path, "--", input.url.path,
        ], options: options, acceptedStatuses: [0, 98, 99])
        guard result.status == 0 else { return nil }
        return TempFile(url: output)
    }
}

/// OptiPNG: tries filters and zlib settings, reduces color types, drops metadata.
nonisolated struct OptiPNGTool: OptimizationTool {
    let level: Int
    let strip: Bool

    var name: String { "OptiPNG" }
    var settingsKey: String { "optipng:\(optimizationLevel):\(strip)" }
    var changesContent: Bool { strip }

    private var optimizationLevel: Int { max(1, min(level + 1, 7)) }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        var effort = optimizationLevel
        if input.isLarge { effort = min(effort, 5) }
        let output = TempFile.makeURL(tool: "optipng", extension: "png")
        var arguments = ["-o\(effort)", "-i0", "-quiet", "-out", output.path]
        if strip { arguments.insert(contentsOf: ["-strip", "all"], at: 0) }
        arguments += ["--", input.url.path]
        _ = try await runHelper("optipng", arguments, options: options)
        return TempFile(url: output)
    }
}

/// pngcrush: an older brute-force recompressor, off by default.
nonisolated struct PngcrushTool: OptimizationTool {
    let level: Int
    let strip: Bool

    var name: String { "pngcrush" }
    var settingsKey: String { "pngcrush:\(strip):\(level >= 6)" }
    var changesContent: Bool { strip }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        let output = TempFile.makeURL(tool: "pngcrush", extension: "png")
        var arguments = ["-nofilecheck", "-bail", "-blacken", "-reduce", "-cc"]
        if strip { arguments.insert(contentsOf: ["-rem", "alla"], at: 0) }
        if input.isSmall || (level >= 6 && !input.isLarge) { arguments.insert("-brute", at: 0) }
        arguments += ["--", input.url.path, output.path]
        _ = try await runHelper("pngcrush", arguments, options: options)
        // pngcrush occasionally writes only a header.
        guard let file = TempFile(url: output), file.size > 70 else { return nil }
        return file
    }
}

/// AdvPNG (AdvanceCOMP): recompresses the image data with 7-Zip's deflate.
nonisolated struct AdvPNGTool: OptimizationTool {
    let level: Int

    var name: String { "AdvPNG" }
    var settingsKey: String { "advpng:\(effort)" }
    var changesContent: Bool { false }

    private var effort: Int { level == 0 ? 4 : max(1, min(4, level)) }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        let scratch = try scratchCopy(of: input, tool: "advpng")
        _ = try await runHelper("advpng", ["-\(effort)", "-z", "-q", "--", scratch.path], options: options)
        return TempFile(url: scratch)
    }
}

/// Zopfli: the slowest and usually the best deflate. Cleans fully transparent pixels too.
nonisolated struct ZopfliTool: OptimizationTool {
    let level: Int
    let strip: Bool
    /// Different filters on a second run of the same file, in case they beat the first pass.
    let alternativeStrategy: Bool

    var name: String { "Zopfli" }
    var settingsKey: String { "zopfli:\(iterations):\(strip):\(alternativeStrategy)" }
    var changesContent: Bool { true }

    private var iterations: Int { 3 + 3 * level }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        var iterations = iterations
        var filters = "0pme"
        var limit = timeLimit(level: level, size: input.size)
        if input.isLarge {
            iterations = 5 + iterations / 3
            filters = "p"
        }
        if alternativeStrategy {
            limit *= 1.4
            filters = "bp"
        } else {
            limit *= 0.8
        }
        let output = TempFile.makeURL(tool: "zopfli", extension: "png")
        var arguments = ["--timelimit=\(Int(limit))", "--iterations=\(iterations)", "--filters=\(filters)", "--lossy_transparent", "-y"]
        if !strip {
            arguments.insert("--keepchunks=tEXt,zTXt,iTXt,gAMA,sRGB,iCCP,bKGD,pHYs,sBIT,tIME,oFFs,acTL,fcTL,fdAT,prVW,mkBF,mkTS,mkBS,mkBT,eXIf,cHRM", at: 0)
        }
        arguments += [input.url.path, output.path]
        _ = try await runHelper("zopflipng", arguments, options: options)
        guard let file = TempFile(url: output), file.size > 70 else { return nil }
        return file
    }
}
