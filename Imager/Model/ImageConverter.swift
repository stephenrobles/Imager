import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a raster image in another format with ImageIO, which on macOS 26 writes AVIF and
/// HEIC natively. Vector files (SVG) and animations (multi-frame GIFs) are left to the optimizers.
nonisolated enum ImageConverter {
    enum Failure: Error, LocalizedError {
        case unreadable
        case animated
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The image couldn't be decoded"
            case .animated: "Animated images are kept in their own format"
            case .encodeFailed(let format): "Couldn't encode the image as \(format)"
            }
        }
    }

    /// - Parameters:
    ///   - quality: 1…100 for lossy targets; ignored for PNG.
    ///   - stripMetadata: drop EXIF, GPS and the like; the orientation is always carried over.
    /// - Returns: the converted file, or nil when the source is animated and should stay as it is.
    static func convert(_ url: URL, to format: ConvertFormat, quality: Int, stripMetadata: Bool) throws -> TempFile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable
        }
        if CGImageSourceGetCount(source) > 1 { return nil }

        let output = TempFile.makeURL(tool: "convert", extension: format.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw Failure.encodeFailed(format.title)
        }

        var options: [CFString: Any] = [:]
        if format.isLossy {
            options[kCGImageDestinationLossyCompressionQuality] = Double(max(1, min(100, quality))) / 100
        }
        if stripMetadata {
            // Decode to pixels and write only the orientation back, so the file is fresh.
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw Failure.unreadable
            }
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let orientation = properties[kCGImagePropertyOrientation] {
                options[kCGImagePropertyOrientation] = orientation
            }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        } else {
            // Copy straight from the source so metadata (EXIF, color profile) comes along.
            CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.encodeFailed(format.title)
        }
        guard let file = TempFile(url: output) else { throw Failure.encodeFailed(format.title) }
        return file
    }

    /// Whether this Mac's ImageIO can write the format (it can on macOS 26, but check once).
    static func canEncode(_ format: ConvertFormat) -> Bool {
        guard format != .keep, let types = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return false }
        return types.contains(format.typeIdentifier)
    }
}
