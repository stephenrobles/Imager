import Foundation
import UniformTypeIdentifiers

/// The image formats Imager recognizes, told apart by the file's first bytes rather than its name.
/// PNG, JPEG, GIF and SVG can be optimized in place; every raster format can be converted.
nonisolated enum ImageKind: String, CaseIterable, Sendable {
    case png, jpeg, gif, svg
    case avif, heic, webp, tiff, bmp

    static func detect(_ data: Data, url: URL) -> ImageKind? {
        guard data.count >= 12 else { return nil }
        let head = [UInt8](data.prefix(16))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return .webp } // RIFF….WEBP
        if head.starts(with: [0x49, 0x49, 0x2A, 0x00]) || head.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if head.starts(with: [0x42, 0x4D]), url.pathExtension.lowercased() == "bmp" { return .bmp }
        if Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] { // ISO base media "ftyp": AVIF or HEIF
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if brand.hasPrefix("avi") { return .avif }
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
        }
        if url.pathExtension.lowercased() == "svg" { return .svg }
        // An SVG may start with a BOM, an XML declaration or a DOCTYPE before the root element.
        if let text = String(data: data.prefix(4096), encoding: .utf8), text.contains("<svg") { return .svg }
        return nil
    }

    /// Formats the optimizers handle in place.
    static let optimizableExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg"]
    /// Raster formats worth picking up from a folder when converting.
    static let convertibleExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif"]

    static let optimizableTypes: [UTType] = [.png, .jpeg, .gif, .svg]
    static let convertibleTypes: [UTType] = [.png, .jpeg, .gif, .svg, .heic, .heif, .webP, .tiff, .bmp] + [UTType("public.avif")].compactMap { $0 }

    static func isSupported(_ url: URL, converting: Bool) -> Bool {
        let ext = url.pathExtension.lowercased()
        return converting ? (convertibleExtensions.contains(ext) || ext == "svg") : optimizableExtensions.contains(ext)
    }

    var name: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .svg: "SVG"
        case .avif: "AVIF"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        }
    }

    /// Whether the optimizers have anything to do with this format.
    var isOptimizable: Bool {
        switch self {
        case .png, .jpeg, .gif, .svg: true
        default: false
        }
    }

    /// Whether ImageIO can decode it for conversion (SVG is vector, so no).
    var isConvertible: Bool { self != .svg }

    /// Big files get the faster settings of the slow tools.
    func isLarge(_ bytes: Int) -> Bool {
        self == .png ? bytes > 250 * 1024 : bytes > 1024 * 1024
    }

    /// Tiny files are cheap enough to try everything on.
    func isSmall(_ bytes: Int) -> Bool {
        self == .png ? bytes < 2048 : bytes < 10 * 1024
    }
}

/// What dropped images are converted to before optimizing. ImageIO on macOS 26 encodes all of these.
nonisolated enum ConvertFormat: String, CaseIterable, Codable, Sendable {
    case keep, avif, heic, jpeg, png

    var title: String {
        switch self {
        case .keep: "Keep Format"
        case .avif: "AVIF"
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }

    var kind: ImageKind? {
        switch self {
        case .keep: nil
        case .avif: .avif
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        }
    }

    var fileExtension: String {
        switch self {
        case .keep: ""
        case .avif: "avif"
        case .heic: "heic"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    var typeIdentifier: String {
        switch self {
        case .keep: ""
        case .avif: "public.avif"
        case .heic: "public.heic"
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        }
    }

    var isLossy: Bool { self == .avif || self == .heic || self == .jpeg }
}
