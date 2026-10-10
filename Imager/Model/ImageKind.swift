import Foundation
import UniformTypeIdentifiers

/// The image formats Imager can shrink, told apart by the file's first bytes rather than its name.
nonisolated enum ImageKind: String, CaseIterable, Sendable {
    case png, jpeg, gif, svg

    static func detect(_ data: Data, url: URL) -> ImageKind? {
        guard data.count >= 6 else { return nil }
        let head = [UInt8](data.prefix(6))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if url.pathExtension.lowercased() == "svg" { return .svg }
        // An SVG may start with a BOM, an XML declaration or a DOCTYPE before the root element.
        if let text = String(data: data.prefix(4096), encoding: .utf8), text.contains("<svg") { return .svg }
        return nil
    }

    static let fileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg"]
    static let contentTypes: [UTType] = [.png, .jpeg, .gif, .svg]

    static func isSupported(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    var name: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .gif: "GIF"
        case .svg: "SVG"
        }
    }

    /// Big files get the faster settings of the slow tools.
    func isLarge(_ bytes: Int) -> Bool {
        self == .png ? bytes > 250 * 1024 : bytes > 1024 * 1024
    }

    /// Tiny files are cheap enough to try everything on.
    func isSmall(_ bytes: Int) -> Bool {
        self == .png ? bytes < 2048 : bytes < 10 * 1024
    }
}
