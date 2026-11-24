import Foundation

/// Tiny append-only logger. Only called on lifecycle events (launch, clean, login item),
/// never on the sampling tick, so the file stays small.
public enum Log {
    private static let queue = DispatchQueue(label: "com.jvz.membar.log")
    private static let maxBytes = 256 * 1024
    private static var prepared = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            prepareIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            let url = AppInfo.logFileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        let url = AppInfo.logFileURL
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let attributes = (try? manager.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attributes[.size] as? Int) ?? 0
        if size > maxBytes {
            // Rotate once: keep the previous file instead of growing forever.
            let previous = url.appendingPathExtension("1")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: url, to: previous)
        }
    }
}