import Foundation
import Observation

/// Everything a run of the optimizers depends on, captured when a file starts so settings changed
/// mid-run only affect files that start afterwards.
nonisolated struct SettingsSnapshot: Sendable, Hashable {
    var lossy: Bool
    var jpegQuality: Int
    var pngQuality: Int
    var gifQuality: Int
    var level: Int
    var stripPNGMetadata: Bool
    var stripJPEGMetadata: Bool
    var preservePermissions: Bool
    var preserveDates: Bool
    var zopfliEnabled: Bool
    var optipngEnabled: Bool
    var pngcrushEnabled: Bool
    var advpngEnabled: Bool
    var pngquantEnabled: Bool
    var jpegoptimEnabled: Bool
    var jpegtranEnabled: Bool
    var gifsicleEnabled: Bool
    var svgoEnabled: Bool
    var lowPriority: Bool
    var convertFormat: ConvertFormat
    var convertQuality: Int
    var keepOriginalWhenConverting: Bool

    var isConverting: Bool { convertFormat != .keep }

    var handlesPNG: Bool { zopfliEnabled || optipngEnabled || pngcrushEnabled || advpngEnabled || (lossy && pngquantEnabled) }
    var handlesJPEG: Bool { jpegoptimEnabled || jpegtranEnabled }
    var handlesGIF: Bool { gifsicleEnabled }
    var handlesSVG: Bool { svgoEnabled }

    func handles(_ kind: ImageKind) -> Bool {
        switch kind {
        case .png: handlesPNG
        case .jpeg: handlesJPEG
        case .gif: handlesGIF
        case .svg: handlesSVG
        default: false
        }
    }

    /// The lossy settings that are actually in effect, for the status bar.
    var lossySummary: String? {
        guard lossy else { return nil }
        var parts: [String] = []
        if jpegQuality < 100 { parts.append("JPEG \(jpegQuality)%") }
        if pngQuality < 100 { parts.append("PNG \(pngQuality)%") }
        if gifQuality < 100 { parts.append("GIF \(gifQuality)%") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// App-wide preferences, backed by UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let levelRange = 0...6
    static let qualityRange = 40...100

    private let defaults = UserDefaults.standard

    /// Off: pixels never change, only metadata and compression. On: images above the quality
    /// targets below are re-encoded at that quality for much smaller files.
    var lossy: Bool { didSet { defaults.set(lossy, forKey: "lossy") } }
    var jpegQuality: Int { didSet { defaults.set(jpegQuality, forKey: "jpegQuality") } }
    var pngQuality: Int { didSet { defaults.set(pngQuality, forKey: "pngQuality") } }
    var gifQuality: Int { didSet { defaults.set(gifQuality, forKey: "gifQuality") } }
    /// 0 (fastest) to 6 (insane); the tools get more iterations and tries as it goes up.
    var level: Int { didSet { defaults.set(level, forKey: "level") } }
    var stripPNGMetadata: Bool { didSet { defaults.set(stripPNGMetadata, forKey: "stripPNGMetadata") } }
    var stripJPEGMetadata: Bool { didSet { defaults.set(stripJPEGMetadata, forKey: "stripJPEGMetadata") } }
    var preservePermissions: Bool { didSet { defaults.set(preservePermissions, forKey: "preservePermissions") } }
    var preserveDates: Bool { didSet { defaults.set(preserveDates, forKey: "preserveDates") } }
    var zopfliEnabled: Bool { didSet { defaults.set(zopfliEnabled, forKey: "zopfliEnabled") } }
    var optipngEnabled: Bool { didSet { defaults.set(optipngEnabled, forKey: "optipngEnabled") } }
    var pngcrushEnabled: Bool { didSet { defaults.set(pngcrushEnabled, forKey: "pngcrushEnabled") } }
    var advpngEnabled: Bool { didSet { defaults.set(advpngEnabled, forKey: "advpngEnabled") } }
    var pngquantEnabled: Bool { didSet { defaults.set(pngquantEnabled, forKey: "pngquantEnabled") } }
    var jpegoptimEnabled: Bool { didSet { defaults.set(jpegoptimEnabled, forKey: "jpegoptimEnabled") } }
    var jpegtranEnabled: Bool { didSet { defaults.set(jpegtranEnabled, forKey: "jpegtranEnabled") } }
    var gifsicleEnabled: Bool { didSet { defaults.set(gifsicleEnabled, forKey: "gifsicleEnabled") } }
    var svgoEnabled: Bool { didSet { defaults.set(svgoEnabled, forKey: "svgoEnabled") } }
    /// Runs the tools at a lower priority so the Mac stays responsive during big batches.
    var lowPriority: Bool { didSet { defaults.set(lowPriority, forKey: "lowPriority") } }
    /// Dropped raster images are re-encoded in this format first; "keep" leaves them as they are.
    var convertFormat: ConvertFormat { didSet { defaults.set(convertFormat.rawValue, forKey: "convertFormat") } }
    var convertQuality: Int { didSet { defaults.set(convertQuality, forKey: "convertQuality") } }
    /// Leave the source file in place instead of trashing it after a conversion.
    var keepOriginalWhenConverting: Bool { didSet { defaults.set(keepOriginalWhenConverting, forKey: "keepOriginalWhenConverting") } }
    var bounceDockWhenDone: Bool { didSet { defaults.set(bounceDockWhenDone, forKey: "bounceDockWhenDone") } }
    var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone") } }

    private init() {
        let stored = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { stored.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { stored.object(forKey: key) as? Int ?? fallback }
        lossy = bool("lossy", false)
        jpegQuality = int("jpegQuality", 80)
        pngQuality = int("pngQuality", 80)
        gifQuality = int("gifQuality", 80)
        level = int("level", 4)
        stripPNGMetadata = bool("stripPNGMetadata", true)
        stripJPEGMetadata = bool("stripJPEGMetadata", true)
        preservePermissions = bool("preservePermissions", true)
        preserveDates = bool("preserveDates", false)
        zopfliEnabled = bool("zopfliEnabled", true)
        optipngEnabled = bool("optipngEnabled", true)
        pngcrushEnabled = bool("pngcrushEnabled", false)
        advpngEnabled = bool("advpngEnabled", true)
        pngquantEnabled = bool("pngquantEnabled", true)
        jpegoptimEnabled = bool("jpegoptimEnabled", true)
        jpegtranEnabled = bool("jpegtranEnabled", true)
        gifsicleEnabled = bool("gifsicleEnabled", true)
        svgoEnabled = bool("svgoEnabled", true)
        lowPriority = bool("lowPriority", false)
        convertFormat = ConvertFormat(rawValue: stored.string(forKey: "convertFormat") ?? "") ?? .keep
        convertQuality = int("convertQuality", 80)
        keepOriginalWhenConverting = bool("keepOriginalWhenConverting", false)
        bounceDockWhenDone = bool("bounceDockWhenDone", true)
        notifyWhenDone = bool("notifyWhenDone", false)
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            lossy: lossy, jpegQuality: jpegQuality, pngQuality: pngQuality, gifQuality: gifQuality,
            level: level, stripPNGMetadata: stripPNGMetadata, stripJPEGMetadata: stripJPEGMetadata,
            preservePermissions: preservePermissions, preserveDates: preserveDates,
            zopfliEnabled: zopfliEnabled, optipngEnabled: optipngEnabled, pngcrushEnabled: pngcrushEnabled,
            advpngEnabled: advpngEnabled, pngquantEnabled: pngquantEnabled, jpegoptimEnabled: jpegoptimEnabled,
            jpegtranEnabled: jpegtranEnabled, gifsicleEnabled: gifsicleEnabled, svgoEnabled: svgoEnabled,
            lowPriority: lowPriority, convertFormat: convertFormat, convertQuality: convertQuality,
            keepOriginalWhenConverting: keepOriginalWhenConverting
        )
    }

    static func levelName(_ level: Int) -> String {
        switch level {
        case 0: "Fastest"
        case 1: "Fast"
        case 2: "Quick"
        case 3: "Balanced"
        case 4: "Normal"
        case 5: "Slow"
        default: "Insane"
        }
    }
}
