import Foundation
import JavaScriptCore

/// SVGO, run inside the app through JavaScriptCore from the bundled svgo.js. No Node.js needed.
nonisolated enum SVGOEngine {
    enum Failure: Error, LocalizedError {
        case missingScript
        case notText
        case javascript(String)

        var errorDescription: String? {
            switch self {
            case .missingScript: "svgo.js is missing from the app"
            case .notText: "The SVG isn't valid UTF-8 text"
            case .javascript(let message): "SVGO failed: \(message)"
            }
        }
    }

    /// Plugins that only tidy the markup: nothing visible changes and nothing meaningful is lost.
    static let losslessPlugins: [String] = [
        "cleanupAttrs", "cleanupListOfValues", "cleanupNumericValues", "convertColors",
        "convertStyleToAttrs", "minifyStyles", "moveGroupAttrsToElems", "removeComments",
        "removeDoctype", "removeEditorsNSData", "removeEmptyAttrs", "removeEmptyContainers",
        "removeEmptyText", "removeNonInheritableGroupAttrs", "removeXMLProcInst", "sortAttrs",
    ]

    /// Where a bundled script is used; a copy of the script's text, loaded once.
    private static let script: String? = {
        guard let url = Bundle.main.url(forResource: "svgo", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// - Parameter lossy: use SVGO's full default preset (paths rewritten, ids and titles removed,
    ///   hidden elements dropped); otherwise only the lossless plugins run.
    static func optimize(_ svg: String, lossy: Bool) throws -> String {
        guard let script else { throw Failure.missingScript }
        guard let context = JSContext() else { throw Failure.javascript("no JavaScript context") }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(script)
        if let exception { throw Failure.javascript(exception) }

        let plugins: [Any]
        if lossy {
            // The default preset, keeping viewBox so the image still scales, plus two safe extras.
            plugins = [
                ["name": "preset-default", "params": ["overrides": ["removeViewBox": false]]] as [String: Any],
                "cleanupListOfValues", "convertStyleToAttrs",
            ]
        } else {
            plugins = losslessPlugins
        }
        let config: [String: Any] = ["multipass": true, "plugins": plugins]

        guard let svgo = context.objectForKeyedSubscript("ImagerSVGO"),
              let optimize = svgo.objectForKeyedSubscript("optimize"),
              let result = optimize.call(withArguments: [svg, config]) else {
            throw Failure.javascript(exception ?? "optimize() did not return")
        }
        if let exception { throw Failure.javascript(exception) }
        guard let data = result.objectForKeyedSubscript("data"), data.isString, let text = data.toString(), !text.isEmpty else {
            throw Failure.javascript("no output")
        }
        return text
    }

    static var version: String? {
        guard let script, let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context.objectForKeyedSubscript("ImagerSVGO")?.objectForKeyedSubscript("version")?.toString()
    }
}
