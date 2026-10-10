import Foundation

/// SVGO, in-process through JavaScriptCore.
nonisolated struct SVGOTool: OptimizationTool {
    let lossy: Bool

    var name: String { lossy ? "SVGO" : "SVGO lite" }
    var settingsKey: String { "svgo:\(lossy)" }
    var changesContent: Bool { lossy }

    func run(_ input: ToolInput, options: ToolOptions) async throws -> TempFile? {
        let data = try Data(contentsOf: input.url)
        guard let text = String(data: data, encoding: .utf8) else { throw SVGOEngine.Failure.notText }
        try Task.checkCancellation()
        let optimized = try SVGOEngine.optimize(text, lossy: lossy)
        let output = TempFile.makeURL(tool: "svgo", extension: "svg")
        try optimized.write(to: output, atomically: true, encoding: .utf8)
        return TempFile(url: output)
    }
}
