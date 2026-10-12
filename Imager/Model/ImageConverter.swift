import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a raster image in another format. HEIC, JPEG and PNG come from ImageIO. AVIF goes
/// through the bundled `avif-encode` helper (libavif + libaom) because Apple's AVIF encoder splits
/// anything over 512 px into a grid of tiles, which Firefox cannot display. Vector files (SVG) and
/// animations (multi-frame GIFs) are left to the optimizers.
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

    /// libavif's effort setting: 0 is slowest and best, 10 fastest. 6 matches avifenc's default.
    static let avifSpeed = 6

    /// - Parameters:
    ///   - quality: 1…100 for lossy targets; ignored for PNG.
    ///   - stripMetadata: drop EXIF, GPS and the like; the orientation is always carried over.
    /// - Returns: the converted file, or nil when the source is animated and should stay as it is.
    static func convert(_ url: URL, to format: ConvertFormat, quality: Int, stripMetadata: Bool, lowPriority: Bool = false) async throws -> TempFile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable
        }
        if CGImageSourceGetCount(source) > 1 { return nil }
        if format == .avif {
            return try await encodeAVIF(source, quality: quality, lowPriority: lowPriority)
        }
        return try encodeWithImageIO(source, to: format, quality: quality, stripMetadata: stripMetadata)
    }

    // MARK: - ImageIO (HEIC, JPEG, PNG)

    private static func encodeWithImageIO(_ source: CGImageSource, to format: ConvertFormat, quality: Int, stripMetadata: Bool) throws -> TempFile? {
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

    // MARK: - AVIF (libavif)

    /// Decodes to 8-bit sRGB with the EXIF orientation applied, hands the pixels to avif-encode,
    /// and returns its single-item AVIF. Metadata is not carried over.
    private static func encodeAVIF(_ source: CGImageSource, quality: Int, lowPriority: Bool) async throws -> TempFile? {
        // The "thumbnail" API is the one that applies the orientation while decoding.
        let size = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).map {
            max(($0[kCGImagePropertyPixelWidth] as? Int) ?? 0, ($0[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        } ?? 0
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data as UnsafeMutableRawPointer? else {
            throw Failure.unreadable
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let raw = TempFile.makeURL(tool: "avif-pixels", extension: "rgba")
        try Data(bytesNoCopy: pixels, count: width * height * 4, deallocator: .none).write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }

        let output = TempFile.makeURL(tool: "convert", extension: "avif")
        let helper = try ToolProcess.helper("avif-encode")
        let result = try await ToolProcess.run(helper, arguments: [
            raw.path, "\(width)", "\(height)", "\(max(1, min(100, quality)))", "\(avifSpeed)", output.path, "premultiplied",
        ], lowPriority: lowPriority)
        guard result.status == 0, let file = TempFile(url: output) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.encodeFailed("AVIF (\(result.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "status \(result.status)"))")
        }
        return file
    }

    /// Whether this Mac can write the format: AVIF needs the bundled helper, the rest ImageIO.
    static func canEncode(_ format: ConvertFormat) -> Bool {
        guard format != .keep else { return false }
        if format == .avif { return (try? ToolProcess.helper("avif-encode")) != nil }
        guard let types = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return false }
        return types.contains(format.typeIdentifier)
    }
}
