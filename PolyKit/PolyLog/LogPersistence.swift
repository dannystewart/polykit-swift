//
//  LogPersistence.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - LogPersistence

/// Service for persisting log entries to disk with session-based file management.
///
/// Provides crash-safe, async logging with rolling session files. Each app launch creates
/// a new session file, and old sessions are automatically pruned based on retention policy.
///
/// ## Usage
///
/// ```swift
/// let persistence = LogPersistence(
///     directory: "Logs",
///     maxSessions: 10
/// )
/// persistence.startNewSession()
/// persistence.write("Log message")
/// persistence.flush() // Force write pending logs
/// ```
///
/// Thread-safe and designed for high-frequency logging without blocking.
public final class LogPersistence: @unchecked Sendable {
    // MARK: - Configuration

    /// Directory name relative to Application Support.
    private let directoryName: String

    /// Maximum number of session files to retain.
    private let maxSessions: Int

    /// Current session file path.
    private var currentSessionFile: URL?

    /// File handle for current session (nil until first write).
    private var fileHandle: FileHandle?

    /// Lock for thread-safe access.
    private let lock: NSLock = .init()

    /// Buffer for pending writes (reduces disk I/O).
    private var writeBuffer: [String] = []

    /// Maximum buffer size before automatic flush (in lines).
    private let bufferFlushThreshold = 10

    /// Periodic flush interval for near-real-time log streaming.
    ///
    /// This keeps session files updating while the app is active without requiring call sites to
    /// manually flush on lifecycle events. The flush is a no-op when the buffer is empty.
    private let flushInterval: TimeInterval = 0.15

    /// Timer that flushes pending writes to disk on `flushInterval`.
    private var flushTimer: DispatchSourceTimer?

    /// Queue used for periodic flush to avoid doing any I/O on the main thread.
    private let flushQueue: DispatchQueue = .init(label: "com.dannystewart.PolyKit.LogPersistence.flush", qos: .utility)

    /// Whether persistence is currently enabled.
    private var isEnabled = false

    // MARK: - Initialization

    /// Creates a new log persistence service.
    ///
    /// - Parameters:
    ///   - directoryName: Directory name relative to Application Support. Defaults to "Logs".
    ///   - maxSessions: Maximum number of session files to retain. Defaults to 10.
    public init(directoryName: String = "Logs", maxSessions: Int = 10) {
        self.directoryName = directoryName
        self.maxSessions = maxSessions
    }

    deinit {
        flushTimer?.cancel()
        flushTimer = nil
        try? fileHandle?.close()
    }

    // MARK: - Session Management

    /// Starts a new logging session.
    ///
    /// Creates a new session file and optionally prunes old sessions based on retention policy.
    /// Safe to call multiple times - subsequent calls are no-ops.
    public func startNewSession() {
        self.lock.lock()
        defer { lock.unlock() }

        guard !self.isEnabled else { return }

        do {
            let logsDirectory = try getLogsDirectory()
            let sessionFile = try createSessionFile(in: logsDirectory)

            self.currentSessionFile = sessionFile
            self.isEnabled = true
            self.startFlushTimerUnsafe()

            // Prune old sessions in the background
            Task.detached { [weak self] in
                self?.pruneOldSessions()
            }
        } catch {
            // Silently fail - logging persistence is optional
            print("LogPersistence: Failed to start session: \(error)")
        }
    }

    /// Ends the current logging session and flushes all pending writes.
    public func endSession() {
        self.lock.lock()
        defer { lock.unlock() }

        self.flushBufferUnsafe()
        self.stopFlushTimerUnsafe()

        try? self.fileHandle?.close()
        self.fileHandle = nil
        self.currentSessionFile = nil
        self.isEnabled = false
    }

    // MARK: - Writing

    /// Writes a log entry to the current session file.
    ///
    /// Writes are buffered for performance and flushed periodically or when buffer is full.
    ///
    /// - Parameter entry: The log entry text to write (should include timestamp and formatting).
    public func write(_ entry: String) {
        self.lock.lock()
        defer { lock.unlock() }

        guard self.isEnabled else { return }

        self.writeBuffer.append(entry)

        // Auto-flush when buffer is full
        if self.writeBuffer.count >= self.bufferFlushThreshold {
            self.flushBufferUnsafe()
        }
    }

    /// Flushes all buffered log entries to disk.
    ///
    /// Safe to call multiple times. Called automatically on a timer and before app termination.
    public func flush() {
        self.lock.lock()
        defer { lock.unlock() }
        self.flushBufferUnsafe()
    }

    // MARK: - Public Utilities

    /// Returns the URL of the logs directory.
    ///
    /// - Returns: The logs directory URL, or nil if it cannot be determined.
    public func getLogsDirectoryURL() -> URL? {
        try? self.getLogsDirectory()
    }

    /// Returns all available session files, sorted by creation date (newest first).
    ///
    /// - Returns: Array of session file URLs.
    public func getSessionFiles() -> [URL] {
        guard let logsDirectory = try? getLogsDirectory() else { return [] }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: logsDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles],
            )

            // Sort by creation date (newest first)
            return files.sorted { file1, file2 in
                let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 > date2
            }
        } catch {
            return []
        }
    }

    /// Returns the current session file URL.
    ///
    /// - Returns: The current session file URL, or nil if no session is active.
    public func getCurrentSessionFile() -> URL? {
        self.lock.lock()
        defer { lock.unlock() }
        return self.currentSessionFile
    }

    /// Reads the contents of a session file.
    ///
    /// - Parameter fileURL: The session file to read.
    /// - Returns: The file contents as a string, or nil if reading fails.
    public func readSessionFile(_ fileURL: URL) -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Creates a zip archive of all log files.
    ///
    /// - Returns: URL of the created zip file in the temporary directory.
    /// - Throws: Error if zip creation fails.
    public func createLogsArchive() throws -> URL {
        let logsDirectory = try getLogsDirectory()

        // Create temporary zip file
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let zipFileName = "logs-\(timestamp).zip"
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(zipFileName)

        // Remove existing zip if present
        try? FileManager.default.removeItem(at: zipURL)

        // Create zip using Cocoa compression
        #if os(macOS) || os(iOS)
            try FileManager.default.zipItem(at: logsDirectory, to: zipURL)
        #else
            throw NSError(domain: "LogPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: "Zip not supported on this platform"])
        #endif

        return zipURL
    }

    // MARK: - Periodic Flush

    /// Starts the periodic flush timer (must be called with `lock` held).
    private func startFlushTimerUnsafe() {
        guard self.flushTimer == nil else { return }
        guard self.isEnabled else { return }

        let timer = DispatchSource.makeTimerSource(queue: self.flushQueue)
        timer.schedule(deadline: .now() + self.flushInterval, repeating: self.flushInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        self.flushTimer = timer
    }

    /// Stops the periodic flush timer (must be called with `lock` held).
    private func stopFlushTimerUnsafe() {
        self.flushTimer?.cancel()
        self.flushTimer = nil
    }

    /// Internal flush implementation (must be called with lock held).
    private func flushBufferUnsafe() {
        guard !self.writeBuffer.isEmpty, self.isEnabled else { return }
        guard let sessionFile = currentSessionFile else { return }

        do {
            // Lazy open file handle on first write
            if self.fileHandle == nil {
                if !FileManager.default.fileExists(atPath: sessionFile.path) {
                    FileManager.default.createFile(atPath: sessionFile.path, contents: nil)
                }
                self.fileHandle = try FileHandle(forWritingTo: sessionFile)
                try self.fileHandle?.seekToEnd()
            }

            let content = self.writeBuffer.joined(separator: "\n") + "\n"
            if let data = content.data(using: .utf8) {
                try self.fileHandle?.write(contentsOf: data)

                #if os(macOS) || os(iOS)
                    try self.fileHandle?.synchronize() // Force write to disk
                #endif
            }

            self.writeBuffer.removeAll(keepingCapacity: true)
        } catch {
            // Silently fail - don't crash app due to logging issues
            print("LogPersistence: Failed to write logs: \(error)")
        }
    }

    // MARK: - File Management

    /// Returns the logs directory URL, creating it if necessary.
    private func getLogsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )

        #if os(macOS)
            /// On macOS, Application Support is per-app
            let logsDir = appSupport.appendingPathComponent(self.directoryName, isDirectory: true)
        #elseif os(iOS)
            /// On iOS, Application Support is already app-scoped
            let logsDir = appSupport.appendingPathComponent(self.directoryName, isDirectory: true)
        #else
            let logsDir = appSupport.appendingPathComponent(self.directoryName, isDirectory: true)
        #endif

        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir
    }

    /// Creates a new session file with timestamp-based naming.
    private func createSessionFile(in directory: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())

        // Add short random suffix to prevent collisions during rapid restarts
        let suffix = String(format: "%06x", Int.random(in: 0 ..< 0xFFFFFF))
        let filename = "session-\(timestamp)-\(suffix).log"

        return directory.appendingPathComponent(filename)
    }

    /// Prunes old session files based on retention policy.
    private func pruneOldSessions() {
        do {
            let logsDirectory = try getLogsDirectory()
            let files = try FileManager.default.contentsOfDirectory(
                at: logsDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles],
            )

            // Sort by creation date (oldest first)
            let sortedFiles = files.sorted { file1, file2 in
                let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 < date2
            }

            // Remove oldest files if we exceed maxSessions
            let filesToRemove = sortedFiles.prefix(max(0, sortedFiles.count - self.maxSessions))
            for file in filesToRemove {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            // Silently fail - pruning is a maintenance operation
            print("LogPersistence: Failed to prune old sessions: \(error)")
        }
    }
}

// MARK: - FileManager Extension

private extension FileManager {
    /// Zips a directory using macOS/iOS compression APIs.
    func zipItem(at sourceURL: URL, to destinationURL: URL) throws {
        #if os(macOS) || os(iOS)
            // Use Cocoa's built-in compression
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?

            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: [.forUploading],
                error: &coordinationError,
            ) { zipURL in
                do {
                    try FileManager.default.copyItem(at: zipURL, to: destinationURL)
                } catch {
                    copyError = error
                }
            }

            if let coordinationError {
                throw coordinationError
            }

            if let copyError {
                throw copyError
            }
        #endif
    }
}
