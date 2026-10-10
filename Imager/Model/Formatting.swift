import Foundation

nonisolated enum Format {
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func size(_ count: Int) -> String {
        bytes.string(fromByteCount: Int64(count))
    }

    /// A fraction such as 0.273 as "27.3%".
    static func percent(_ fraction: Double) -> String {
        percent.string(from: NSNumber(value: fraction)) ?? "\(Int(fraction * 100))%"
    }
}
