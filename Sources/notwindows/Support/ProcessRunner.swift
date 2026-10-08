import Foundation

enum ProcessRunner {
    struct Failure: LocalizedError {
        let command: String
        let status: Int32
        let output: String

        var errorDescription: String? {
            let tail = output.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
            return "\(command) exited with status \(status)." + (tail.isEmpty ? "" : "\n\n\(tail)")
        }
    }

    /// Spawns a process. Output goes to `log` (appended) when given, otherwise it is discarded.
    @discardableResult
    static func start(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        log: URL? = nil,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory, directory.isDirectoryURL { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice

        if let log {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !log.exists { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log)
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        process.terminationHandler = { p in
            if let handle = p.standardOutput as? FileHandle, handle !== FileHandle.nullDevice {
                try? handle.close()
            }
            onExit?(p.terminationStatus)
        }
        try process.run()
        return process
    }

    /// Runs to completion and returns the exit status.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        log: URL? = nil
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try start(executable, arguments, environment: environment, directory: directory, log: log) { status in
                    continuation.resume(returning: status)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs to completion, capturing combined output, and throws on a non-zero exit.
    static func output(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil
    ) async throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            let collected = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let text = collected.string
                if p.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
                    continuation.resume(throwing: Failure(command: command, status: p.terminationStatus, output: text))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
