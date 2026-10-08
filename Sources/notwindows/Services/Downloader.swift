import Foundation

enum Downloader {
    /// Downloads `url` into the downloads folder, reporting progress in 0...1.
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode)): \(url.lastPathComponent)"])
        }
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let destination = Paths.downloads.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    static func string(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Request failed (HTTP \(http.statusCode)): \(url.absoluteString)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Request failed (HTTP \(http.statusCode)): \(url.absoluteString)"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Extracts a tarball (any compression bsdtar understands). `members` limits extraction to matching paths.
    static func extract(_ archive: URL, into directory: URL, members: [String] = []) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xf", archive.path, "-C", directory.path] + members
        )
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    private var lastReported = -1.0

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.005 || fraction >= 1 {
            lastReported = fraction
            progress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
