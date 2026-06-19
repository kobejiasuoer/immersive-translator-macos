import Foundation

enum DiagnosticLogger {
    private static let queue = DispatchQueue(label: "local.immersive-translator.diagnostic-logger")

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        queue.async {
            do {
                let url = logFileURL()
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if let data = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        let handle = try FileHandle(forWritingTo: url)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } else {
                        try data.write(to: url, options: [.atomic])
                    }
                }
            } catch {
                NSLog("Failed to write diagnostic log: \(error.localizedDescription)")
            }
        }
    }

    static func logFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("ImmersiveTranslator", isDirectory: true)
            .appendingPathComponent("diagnostic.log")
    }
}
