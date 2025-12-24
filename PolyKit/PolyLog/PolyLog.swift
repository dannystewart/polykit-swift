//
//  PolyLog.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

#if canImport(os)
    import os
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - LogEntry

/// A captured log entry for in-app console display.
public struct LogEntry: Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
    public let group: LogGroup?

    /// Pre-formatted plain text for display (no ANSI codes).
    public let formattedText: String

    public init(
        timestamp: Date,
        level: LogLevel,
        message: String,
        group: LogGroup?,
        formattedText: String,
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.group = group
        self.formattedText = formattedText
    }
}

// MARK: - LogBuffer

/// Thread-safe circular buffer for capturing log entries.
///
/// Used by `PolyLog` when capture is enabled to store recent log entries
/// for display in an in-app console.
public final class LogBuffer: @unchecked Sendable {
    /// Default capacity for the log buffer.
    public static let defaultCapacity = 5000

    private let lock: NSLock = .init()
    private var entries: [LogEntry] = []
    private let capacity: Int

    /// Returns the number of entries currently in the buffer.
    public var count: Int {
        self.lock.lock()
        defer { lock.unlock() }
        return self.entries.count
    }

    /// Creates a new log buffer with the specified capacity.
    ///
    /// - Parameter capacity: Maximum number of entries to retain. Oldest entries are
    ///   dropped when the buffer is full. Defaults to 5000.
    public init(capacity: Int = LogBuffer.defaultCapacity) {
        self.capacity = capacity
        self.entries.reserveCapacity(capacity)
    }

    /// Appends a new entry to the buffer, dropping the oldest if at capacity.
    public func append(_ entry: LogEntry) {
        self.lock.lock()
        defer { lock.unlock() }

        if self.entries.count >= self.capacity {
            self.entries.removeFirst()
        }
        self.entries.append(entry)
    }

    /// Returns all captured entries in chronological order.
    public func allEntries() -> [LogEntry] {
        self.lock.lock()
        defer { lock.unlock() }
        return self.entries
    }

    /// Clears all entries from the buffer.
    public func clear() {
        self.lock.lock()
        defer { lock.unlock() }
        self.entries.removeAll(keepingCapacity: true)
    }

    /// Exports all entries as plain text, one entry per line.
    ///
    /// - Returns: A string containing all log entries formatted for export.
    public func exportAsText() -> String {
        let allEntries = allEntries()
        return allEntries.map(\.formattedText).joined(separator: "\n")
    }
}

// MARK: - LogGroup

/// Type-safe identifier for logging groups. Allows categorization of logs for filtering.
///
/// Example usage:
/// ```swift
/// extension LogGroup {
///     static let networking = LogGroup("networking", emoji: "🌐")
///     static let database = LogGroup("database", emoji: "💾")
///     static let verboseUI = LogGroup("verbose-ui", emoji: "🎨", defaultEnabled: false)
/// }
/// ```
public struct LogGroup: Hashable, Sendable {
    public let identifier: String
    public let emoji: String?
    public let defaultEnabled: Bool

    public init(_ identifier: String, emoji: String? = nil, defaultEnabled: Bool = true) {
        self.identifier = identifier
        self.emoji = emoji
        self.defaultEnabled = defaultEnabled
    }
}

// MARK: - PolyLog

/// Class for logging messages to the console and system log with optional group-based filtering.
///
/// Supports categorizing logs into groups that can be individually enabled/disabled at runtime.
/// All group functionality is optional - logs without groups are always printed.
///
/// ## Group Configuration
///
/// Define your log groups with their default states:
///
/// ```swift
/// extension LogGroup {
///     static let networking = LogGroup("networking", emoji: "🌐")
///     static let verboseDB = LogGroup("verbose-db", emoji: "💾", defaultEnabled: false)
/// }
/// ```
///
/// Then configure the logger at startup:
///
/// ```swift
/// logger.registeredGroups = [.networking, .verboseDB]
/// logger.applyDefaultStates()       // Apply per-group defaults
/// logger.loadPersistedStates()      // Override with saved user preferences
/// ```
///
/// ## In-App Console Capture
///
/// To enable capturing logs for an in-app console:
///
/// ```swift
/// logger.enableCapture()  // Call once at app startup
///
/// // Later, retrieve captured logs:
/// let entries = logger.capturedEntries()
/// ```
///
/// Capture is disabled by default to avoid memory overhead in CLI tools or apps that don't need it.
public final class PolyLog: @unchecked Sendable {
    /// Shared timestamp formatter for consistent formatting.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss.SSS a"
        return formatter
    }()

    /// Log levels that can be filtered by disabled groups.
    /// By default, debug and info messages are filterable. Warnings, errors, and faults always print.
    /// You can customize this per-logger instance if needed.
    public var filterableLevels: Set<LogLevel> = [.debug, .info]

    /// Registered groups for this logger.
    /// Apps can register their groups here for easy management via UI, persistence, etc.
    public var registeredGroups: [LogGroup] = []

    /// Optional callback invoked for each log entry.
    ///
    /// Used by external services (like LogRemote in PolyBase) to receive log entries
    /// for remote streaming. The callback is invoked synchronously, so implementations
    /// should buffer entries and process them asynchronously.
    ///
    /// - Note: This callback is invoked AFTER group filtering, so disabled groups
    ///   won't trigger the callback for filterable log levels.
    public var onLogEntry: (@Sendable (LogEntry) -> Void)?

    #if canImport(os)
        private let osLogger: Logger
    #endif

    /// Thread-safe storage for enabled/disabled groups
    private let groupLock: NSLock = .init()
    private var disabledGroups: Set<LogGroup> = []

    /// Optional log buffer for in-app console capture.
    /// Nil by default (no memory overhead). Call `enableCapture()` to activate.
    private var logBuffer: LogBuffer?

    /// Optional log persistence service for writing logs to disk.
    /// Nil by default (no disk I/O). Call `enablePersistence()` to activate.
    private var persistence: LogPersistence?

    /// Returns whether log capture is currently enabled.
    public var isCaptureEnabled: Bool {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        return self.logBuffer != nil
    }

    /// Returns whether log persistence is currently enabled.
    public var isPersistenceEnabled: Bool {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        return self.persistence != nil
    }

    /// Returns the number of captured entries.
    public var capturedEntryCount: Int {
        self.groupLock.lock()
        let buffer = self.logBuffer
        self.groupLock.unlock()

        return buffer?.count ?? 0
    }

    public nonisolated init() {
        #if canImport(os)
            /// Use the app's bundle identifier
            let subsystem = Bundle.main.bundleIdentifier ?? "com.unknown.app.polylog"
            self.osLogger = Logger(subsystem: subsystem, category: "PolyLog")
        #endif
    }

    // MARK: - Capture Control

    /// Enables log capture for in-app console display.
    ///
    /// Call this once at app startup if you want to show logs in an in-app console.
    /// Captured logs are stored in memory (up to `capacity` entries).
    ///
    /// - Parameter capacity: Maximum number of entries to retain. Defaults to 5000.
    public func enableCapture(capacity: Int = LogBuffer.defaultCapacity) {
        self.groupLock.lock()
        defer { groupLock.unlock() }

        if self.logBuffer == nil {
            self.logBuffer = LogBuffer(capacity: capacity)
        }
    }

    /// Disables log capture and clears the buffer.
    public func disableCapture() {
        self.groupLock.lock()
        defer { groupLock.unlock() }

        self.logBuffer = nil
    }

    // MARK: - Persistence Control

    /// Enables log persistence to disk with session-based file management.
    ///
    /// Call this once at app startup if you want logs to persist across app launches.
    /// Logs are written to Application Support/Logs/ with automatic session rotation.
    ///
    /// - Parameters:
    ///   - directoryName: Directory name relative to Application Support. Defaults to "Logs".
    ///   - maxSessions: Maximum number of session files to retain. Defaults to 10.
    public func enablePersistence(directoryName: String = "Logs", maxSessions: Int = 10) {
        self.groupLock.lock()
        defer { groupLock.unlock() }

        if self.persistence == nil {
            let service = LogPersistence(directoryName: directoryName, maxSessions: maxSessions)
            service.startNewSession()
            self.persistence = service
        }
    }

    /// Disables log persistence and ends the current session.
    public func disablePersistence() {
        self.groupLock.lock()
        defer { groupLock.unlock() }

        self.persistence?.endSession()
        self.persistence = nil
    }

    /// Flushes all buffered log entries to disk.
    ///
    /// Normally logs are flushed automatically, but you can call this to ensure
    /// critical logs are written immediately (e.g., before app termination).
    public func flushPersistence() {
        self.groupLock.lock()
        let service = self.persistence
        self.groupLock.unlock()

        service?.flush()
    }

    /// Returns the logs directory URL if persistence is enabled.
    ///
    /// - Returns: URL of the logs directory, or nil if persistence is not enabled.
    public func getLogsDirectoryURL() -> URL? {
        self.groupLock.lock()
        let service = self.persistence
        self.groupLock.unlock()

        return service?.getLogsDirectoryURL()
    }

    /// Returns all available session files if persistence is enabled.
    ///
    /// Files are sorted by creation date (newest first).
    ///
    /// - Returns: Array of session file URLs.
    public func getSessionFiles() -> [URL] {
        self.groupLock.lock()
        let service = self.persistence
        self.groupLock.unlock()

        return service?.getSessionFiles() ?? []
    }

    /// Returns the current session file URL if persistence is enabled.
    ///
    /// - Returns: The current session file URL, or nil if persistence is not enabled.
    public func getCurrentSessionFile() -> URL? {
        self.groupLock.lock()
        let service = self.persistence
        self.groupLock.unlock()

        return service?.getCurrentSessionFile()
    }

    /// Reads the contents of a session file.
    ///
    /// - Parameter fileURL: The session file to read.
    /// - Returns: The file contents as a string, or nil if reading fails.
    public func readSessionFile(_ fileURL: URL) -> String? {
        self.groupLock.lock()
        let service = self.persistence
        self.groupLock.unlock()

        return service?.readSessionFile(fileURL)
    }

    /// Creates a zip archive of all log files.
    ///
    /// - Returns: URL of the created zip file in the temporary directory.
    /// - Throws: Error if zip creation fails or persistence is not enabled.
    public func createLogsArchive() throws -> URL {
        self.groupLock.lock()
        let service = self.persistence
        self.groupLock.unlock()

        guard let service else {
            throw NSError(
                domain: "PolyLog",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Log persistence is not enabled"],
            )
        }

        return try service.createLogsArchive()
    }

    /// Returns all captured log entries in chronological order.
    ///
    /// Returns an empty array if capture is not enabled.
    public func capturedEntries() -> [LogEntry] {
        self.groupLock.lock()
        let buffer = self.logBuffer
        self.groupLock.unlock()

        return buffer?.allEntries() ?? []
    }

    /// Clears all captured log entries.
    public func clearCapturedEntries() {
        self.groupLock.lock()
        let buffer = self.logBuffer
        self.groupLock.unlock()

        buffer?.clear()
    }

    /// Exports all captured entries as plain text.
    ///
    /// - Returns: A string containing all log entries, or an empty string if capture is disabled.
    public func exportCapturedEntries() -> String {
        self.groupLock.lock()
        let buffer = self.logBuffer
        self.groupLock.unlock()

        return buffer?.exportAsText() ?? ""
    }

    // MARK: Public Logging Methods

    public func debug(_ message: String, group: LogGroup? = nil) {
        self.log(message, level: .debug, group: group)
    }

    public func info(_ message: String, group: LogGroup? = nil) {
        self.log(message, level: .info, group: group)
    }

    public func warning(_ message: String, group: LogGroup? = nil) {
        self.log(message, level: .warning, group: group)
    }

    public func error(_ message: String, group: LogGroup? = nil) {
        self.log(message, level: .error, group: group)
    }

    public func fault(_ message: String, group: LogGroup? = nil) {
        self.log(message, level: .fault, group: group)
    }

    // MARK: Group Management

    /// Disables logging for a specific group.
    /// - Parameter group: The group to disable.
    public func disableGroup(_ group: LogGroup) {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        self.disabledGroups.insert(group)
    }

    /// Enables logging for a specific group.
    /// - Parameter group: The group to enable.
    public func enableGroup(_ group: LogGroup) {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        self.disabledGroups.remove(group)
    }

    /// Disables multiple groups at once.
    /// - Parameter groups: The groups to disable.
    public func disableGroups(_ groups: [LogGroup]) {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        self.disabledGroups.formUnion(groups)
    }

    /// Enables multiple groups at once.
    /// - Parameter groups: The groups to enable.
    public func enableGroups(_ groups: [LogGroup]) {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        groups.forEach { self.disabledGroups.remove($0) }
    }

    /// Checks if an group is currently enabled.
    /// - Parameter group: The group to check.
    /// - Returns: `true` if the group is enabled (not disabled).
    public func isGroupEnabled(_ group: LogGroup) -> Bool {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        return !self.disabledGroups.contains(group)
    }

    /// Returns all currently disabled groups.
    /// - Returns: A set of disabled groups.
    public func getDisabledGroups() -> Set<LogGroup> {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        return self.disabledGroups
    }

    /// Enables all groups (clears the disabled list).
    public func enableAllGroups() {
        self.groupLock.lock()
        defer { groupLock.unlock() }
        self.disabledGroups.removeAll()
    }

    /// Applies default enabled/disabled states based on `registeredGroups` and their `defaultEnabled` property.
    ///
    /// Call this during app initialization to set up initial group states. Groups with `defaultEnabled: false`
    /// will be disabled, while groups with `defaultEnabled: true` (the default) will be enabled.
    ///
    /// Typical workflow:
    /// ```swift
    /// logger.registeredGroups = [.networking, .database, .verboseUI]
    /// logger.applyDefaultStates()  // Apply defaults
    /// logger.loadPersistedStates() // Override with user preferences if available
    /// ```
    public func applyDefaultStates() {
        self.groupLock.lock()
        defer { groupLock.unlock() }

        for group in self.registeredGroups {
            if group.defaultEnabled {
                self.disabledGroups.remove(group)
            } else {
                self.disabledGroups.insert(group)
            }
        }
    }

    // MARK: Persistence

    /// Saves the currently enabled groups to UserDefaults.
    /// Only saves groups from `registeredGroups` that are currently enabled.
    ///
    /// - Parameter key: The UserDefaults key to use. Defaults to "EnabledLogGroups".
    public func saveEnabledGroups(key: String = "EnabledLogGroups") {
        self.groupLock.lock()
        let disabled = self.disabledGroups
        self.groupLock.unlock()

        // Find which registered groups are enabled (not in disabled set)
        let enabledIdentifiers = self.registeredGroups
            .filter { !disabled.contains($0) }
            .map(\.identifier)

        UserDefaults.standard.set(enabledIdentifiers, forKey: key)
    }

    /// Loads persisted group states from UserDefaults and applies them.
    ///
    /// If saved preferences exist, they are treated as authoritative - groups in the saved list
    /// are enabled, groups not in the list are disabled. If no saved preferences exist, the
    /// current state (e.g., from `applyDefaultStates()`) is left unchanged.
    ///
    /// Typical workflow:
    /// ```swift
    /// logger.applyDefaultStates()    // Apply per-group defaults
    /// logger.loadPersistedStates()   // Override with user preferences if saved
    /// ```
    ///
    /// - Parameter key: The UserDefaults key to read from. Defaults to "EnabledLogGroups".
    public func loadPersistedStates(key: String = "EnabledLogGroups") {
        // Check if saved preferences exist
        guard let savedIdentifiers = UserDefaults.standard.stringArray(forKey: key) else {
            // No saved preferences - leave current state (from applyDefaultStates) unchanged
            return
        }

        let enabledIdentifiers = Set(savedIdentifiers)

        // Saved preferences exist - treat them as authoritative
        for group in self.registeredGroups {
            if enabledIdentifiers.contains(group.identifier) {
                self.enableGroup(group)
            } else {
                self.disableGroup(group)
            }
        }
    }

    /// Logs a message at the specified level.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - level:   The level of the message.
    ///   - group:    Optional group for categorization and filtering.
    ///
    /// - Note: By default, only debug messages are filtered by disabled groups.
    ///         Warnings, errors, and faults always print. You can customize this via `filterableLevels`.
    private func log(_ message: String, level: LogLevel, group: LogGroup? = nil) {
        // Check if this group is disabled (but only for filterable levels)
        if let group, filterableLevels.contains(level) {
            self.groupLock.lock()
            let isDisabled = self.disabledGroups.contains(group)
            self.groupLock.unlock()

            if isDisabled {
                return // Skip logging for disabled groups (filterable levels only)
            }
        }

        let now = Date()
        let formattedMessage = self.formatConsoleMessage(message, level: level, group: group, timestamp: now)

        // Get optional outputs
        self.groupLock.lock()
        let buffer = self.logBuffer
        let persistenceService = self.persistence
        let entryCallback = self.onLogEntry
        self.groupLock.unlock()

        // Create LogEntry if any consumer needs it (buffer or remote callback)
        let entry: LogEntry?
        if buffer != nil || entryCallback != nil {
            let plainText = self.formatPlainMessage(message, level: level, group: group, timestamp: now)
            entry = LogEntry(
                timestamp: now,
                level: level,
                message: message,
                group: group,
                formattedText: plainText,
            )
        } else {
            entry = nil
        }

        // Capture to buffer if enabled
        if let buffer, let entry {
            buffer.append(entry)
        }

        // Send to remote callback if enabled
        if let entryCallback, let entry {
            entryCallback(entry)
        }

        // Write to persistence if enabled
        if let persistenceService {
            let plainText = entry?.formattedText ?? self.formatPlainMessage(message, level: level, group: group, timestamp: now)
            persistenceService.write(plainText)
        }

        // Print to console if we're in a real terminal (supports ANSI colors)
        if PolyTerm.supportsANSI() {
            print(formattedMessage)
        }

        #if canImport(os)
            // Always log to unified logging system
            switch level.osLogType {
            case .debug:
                osLogger.debug("\(formattedMessage, privacy: .public)")
            case .info:
                osLogger.info("\(formattedMessage, privacy: .public)")
            case .default:
                osLogger.notice("\(formattedMessage, privacy: .public)")
            case .error:
                osLogger.error("\(formattedMessage, privacy: .public)")
            case .fault:
                osLogger.fault("\(formattedMessage, privacy: .public)")
            default:
                osLogger.log("\(formattedMessage, privacy: .public)")
            }
        #endif
    }

    /// Formats a message for console output with ANSI colors.
    ///
    /// Uses compact emoji-based format with pipe separator for visual clarity.
    /// Format: `timestamp level-emoji | [group-emoji] message`
    ///
    /// - Parameters:
    ///   - message: The message to format.
    ///   - level:   The level of the message.
    ///   - group:    Optional group identifier.
    ///   - timestamp: The timestamp for the log entry.
    /// - Returns: The formatted message with colors (if real terminal) and timestamps.
    private func formatConsoleMessage(
        _ message: String,
        level: LogLevel,
        group: LogGroup? = nil,
        timestamp: Date,
    ) -> String {
        let timestampString = self.formatTimestamp(timestamp)

        if PolyTerm.supportsANSI() {
            // Format: timestamp level-emoji | [group-emoji] message
            let timestampFormatted = "\(ANSIColor.gray.rawValue)\(timestampString)\(ANSIColor.reset.rawValue)"
            let levelFormatted = "\(ANSIColor.bold.rawValue)\(level.color.rawValue)\(level.displayText)\(ANSIColor.reset.rawValue)"

            // Pipe separator
            let separator = " |"

            // Group emoji or spacing for alignment
            let groupFormatted = if let group, let emoji = group.emoji {
                // Has group emoji: space + emoji + space
                " \(emoji) "
            } else if let group {
                // No emoji? Use colored identifier in brackets (fallback)
                " \(ANSIColor.cyan.rawValue)[\(group.identifier)]\(ANSIColor.reset.rawValue) "
            } else {
                // No group: 3 spaces for alignment (accounts for missing emoji + surrounding spaces)
                "   "
            }

            let messageFormatted = "\(level.color.rawValue)\(message)\(ANSIColor.reset.rawValue)"
            return "\(timestampFormatted) \(levelFormatted)\(separator)\(groupFormatted)\(messageFormatted)"
        } else {
            return self.formatPlainMessage(message, level: level, group: group, timestamp: timestamp)
        }
    }

    /// Formats a message as plain text (no ANSI codes) for capture and export.
    ///
    /// Uses compact emoji-based format with pipe separator matching console output.
    /// Format: `timestamp level-emoji | [group-emoji] message`
    ///
    /// Example:
    /// ```
    /// 12:11:11.243 PM ✅ | 💾 PolyBaseRegistry: Registered Message
    /// 12:11:11.354 PM 🛠️ |   BackgroundQueryActor initialized
    /// ```
    private func formatPlainMessage(
        _ message: String,
        level: LogLevel,
        group: LogGroup?,
        timestamp: Date,
    ) -> String {
        let timestampString = self.formatTimestamp(timestamp)

        // Pipe separator
        let separator = "|"

        // Group emoji or spacing for alignment
        let groupPart = if let group, let emoji = group.emoji {
            // Has group emoji: space + emoji + space
            " \(emoji) "
        } else if let group {
            // Fallback: use identifier if no emoji
            " [\(group.identifier)] "
        } else {
            // No group: 3 spaces for alignment
            "   "
        }

        return "\(timestampString) \(level.displayText)\(separator)\(groupPart)\(message)"
    }

    /// Formats a date for use in log messages.
    private func formatTimestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }
}

// MARK: - LoggableError

/// Protocol for errors that can be logged and thrown.
public protocol LoggableError: Error { var logMessage: String { get }}

/// Extension for PolyLog to add logging and throwing capabilities.
public extension PolyLog {
    func logAndThrow(_ error: some LoggableError) throws {
        self.error(error.logMessage)
        throw error
    }

    func logAndExit(_ error: some LoggableError) -> Never {
        self.error(error.logMessage)
        exit(1)
    }
}

// MARK: - LogLevel

/// Enum representing various log levels.
public enum LogLevel: String, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
    case fault

    #if canImport(os)
        var osLogType: OSLogType {
            switch self {
            case .debug: .default
            case .info: .default
            case .warning: .default
            case .error: .error
            case .fault: .fault
            }
        }
    #endif

    var color: ANSIColor {
        switch self {
        case .debug: .gray
        case .info: .green
        case .warning: .yellow
        case .error: .red
        case .fault: .magenta
        }
    }

    var displayText: String {
        switch self {
        case .debug: "🛠️ "
        case .info: "✅ "
        case .warning: "⚠️ "
        case .error: "❌ "
        case .fault: "🔥 "
        }
    }
}
