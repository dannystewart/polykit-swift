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
        id = UUID()
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
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Creates a new log buffer with the specified capacity.
    ///
    /// - Parameter capacity: Maximum number of entries to retain. Oldest entries are
    ///   dropped when the buffer is full. Defaults to 5000.
    public init(capacity: Int = LogBuffer.defaultCapacity) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    /// Appends a new entry to the buffer, dropping the oldest if at capacity.
    public func append(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }

        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append(entry)
    }

    /// Returns all captured entries in chronological order.
    public func allEntries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Clears all entries from the buffer.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
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
///     static let ui = LogGroup("ui", emoji: "🎨")
/// }
/// ```
public struct LogGroup: Hashable, Sendable {
    public let identifier: String
    public let emoji: String?

    public init(_ identifier: String, emoji: String? = nil) {
        self.identifier = identifier
        self.emoji = emoji
    }
}

// MARK: - PolyLog

/// Class for logging messages to the console and system log with optional group-based filtering.
///
/// Supports categorizing logs into groups that can be individually enabled/disabled at runtime.
/// All group functionality is optional - logs without groups are always printed.
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
    /// By default, only debug messages are filterable. Warnings, errors, and faults always print.
    /// You can customize this per-logger instance if needed.
    public var filterableLevels: Set<LogLevel> = [.debug]

    /// Registered groups for this logger.
    /// Apps can register their groups here for easy management via UI, persistence, etc.
    public var registeredGroups: [LogGroup] = []

    #if canImport(os)
        private let osLogger: Logger
    #endif

    /// Thread-safe storage for enabled/disabled groups
    private let groupLock: NSLock = .init()
    private var disabledGroups: Set<LogGroup> = []

    /// Optional log buffer for in-app console capture.
    /// Nil by default (no memory overhead). Call `enableCapture()` to activate.
    private var logBuffer: LogBuffer?

    /// Returns whether log capture is currently enabled.
    public var isCaptureEnabled: Bool {
        groupLock.lock()
        defer { groupLock.unlock() }
        return logBuffer != nil
    }

    /// Returns the number of captured entries.
    public var capturedEntryCount: Int {
        groupLock.lock()
        let buffer = logBuffer
        groupLock.unlock()

        return buffer?.count ?? 0
    }

    public nonisolated init() {
        #if canImport(os)
            /// Use the app's bundle identifier
            let subsystem = Bundle.main.bundleIdentifier ?? "com.unknown.app.polylog"
            osLogger = Logger(subsystem: subsystem, category: "PolyLog")
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
        groupLock.lock()
        defer { groupLock.unlock() }

        if logBuffer == nil {
            logBuffer = LogBuffer(capacity: capacity)
        }
    }

    /// Disables log capture and clears the buffer.
    public func disableCapture() {
        groupLock.lock()
        defer { groupLock.unlock() }

        logBuffer = nil
    }

    /// Returns all captured log entries in chronological order.
    ///
    /// Returns an empty array if capture is not enabled.
    public func capturedEntries() -> [LogEntry] {
        groupLock.lock()
        let buffer = logBuffer
        groupLock.unlock()

        return buffer?.allEntries() ?? []
    }

    /// Clears all captured log entries.
    public func clearCapturedEntries() {
        groupLock.lock()
        let buffer = logBuffer
        groupLock.unlock()

        buffer?.clear()
    }

    /// Exports all captured entries as plain text.
    ///
    /// - Returns: A string containing all log entries, or an empty string if capture is disabled.
    public func exportCapturedEntries() -> String {
        groupLock.lock()
        let buffer = logBuffer
        groupLock.unlock()

        return buffer?.exportAsText() ?? ""
    }

    // MARK: Public Logging Methods

    public func debug(_ message: String, group: LogGroup? = nil) {
        log(message, level: .debug, group: group)
    }

    public func info(_ message: String, group: LogGroup? = nil) {
        log(message, level: .info, group: group)
    }

    public func warning(_ message: String, group: LogGroup? = nil) {
        log(message, level: .warning, group: group)
    }

    public func error(_ message: String, group: LogGroup? = nil) {
        log(message, level: .error, group: group)
    }

    public func fault(_ message: String, group: LogGroup? = nil) {
        log(message, level: .fault, group: group)
    }

    // MARK: Group Management

    /// Disables logging for a specific group.
    /// - Parameter group: The group to disable.
    public func disableGroup(_ group: LogGroup) {
        groupLock.lock()
        defer { groupLock.unlock() }
        disabledGroups.insert(group)
    }

    /// Enables logging for a specific group.
    /// - Parameter group: The group to enable.
    public func enableGroup(_ group: LogGroup) {
        groupLock.lock()
        defer { groupLock.unlock() }
        disabledGroups.remove(group)
    }

    /// Disables multiple groups at once.
    /// - Parameter groups: The groups to disable.
    public func disableGroups(_ groups: [LogGroup]) {
        groupLock.lock()
        defer { groupLock.unlock() }
        disabledGroups.formUnion(groups)
    }

    /// Enables multiple groups at once.
    /// - Parameter groups: The groups to enable.
    public func enableGroups(_ groups: [LogGroup]) {
        groupLock.lock()
        defer { groupLock.unlock() }
        groups.forEach { disabledGroups.remove($0) }
    }

    /// Checks if an group is currently enabled.
    /// - Parameter group: The group to check.
    /// - Returns: `true` if the group is enabled (not disabled).
    public func isGroupEnabled(_ group: LogGroup) -> Bool {
        groupLock.lock()
        defer { groupLock.unlock() }
        return !disabledGroups.contains(group)
    }

    /// Returns all currently disabled groups.
    /// - Returns: A set of disabled groups.
    public func getDisabledGroups() -> Set<LogGroup> {
        groupLock.lock()
        defer { groupLock.unlock() }
        return disabledGroups
    }

    /// Enables all groups (clears the disabled list).
    public func enableAllGroups() {
        groupLock.lock()
        defer { groupLock.unlock() }
        disabledGroups.removeAll()
    }

    // MARK: Persistence

    /// Saves the currently enabled groups to UserDefaults.
    /// Only saves groups from `registeredGroups` that are currently enabled.
    ///
    /// - Parameter key: The UserDefaults key to use. Defaults to "EnabledLogGroups".
    public func saveEnabledGroups(key: String = "EnabledLogGroups") {
        groupLock.lock()
        let disabled = disabledGroups
        groupLock.unlock()

        // Find which registered groups are enabled (not in disabled set)
        let enabledIdentifiers = registeredGroups
            .filter { !disabled.contains($0) }
            .map(\.identifier)

        UserDefaults.standard.set(enabledIdentifiers, forKey: key)
    }

    /// Loads persisted group states from UserDefaults and applies them.
    /// Groups found in UserDefaults are enabled, all others from `registeredGroups` are disabled.
    ///
    /// - Parameters:
    ///   - key: The UserDefaults key to read from. Defaults to "EnabledLogGroups".
    ///   - defaultToDisabled: If `true`, groups not in UserDefaults are disabled (opt-in).
    ///                        If `false`, groups not in UserDefaults are enabled (opt-out).
    ///                        Defaults to `true` (opt-in behavior).
    public func loadPersistedStates(key: String = "EnabledLogGroups", defaultToDisabled: Bool = true) {
        let enabledIdentifiers = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

        for group in registeredGroups {
            if enabledIdentifiers.contains(group.identifier) {
                enableGroup(group)
            } else if defaultToDisabled {
                disableGroup(group)
            }
            // If !defaultToDisabled and not in saved set, leave as-is (enabled by default)
        }
    }

    /// Applies different group configurations based on build type.
    /// In DEBUG: Loads persisted states (opt-in by default).
    /// In RELEASE: Disables all registered groups for performance.
    ///
    /// - Parameter key: The UserDefaults key to use. Defaults to "EnabledLogGroups".
    public func applyBuildConfiguration(key: String = "EnabledLogGroups") {
        #if DEBUG
            loadPersistedStates(key: key, defaultToDisabled: true)
        #else
            // Disable all groups in release builds for performance
            disableGroups(registeredGroups)
        #endif
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
            groupLock.lock()
            let isDisabled = disabledGroups.contains(group)
            groupLock.unlock()

            if isDisabled {
                return // Skip logging for disabled groups (filterable levels only)
            }
        }

        let now = Date()
        let formattedMessage = formatConsoleMessage(message, level: level, group: group, timestamp: now)

        // Capture to buffer if enabled (always capture, even if console output is filtered)
        groupLock.lock()
        let buffer = logBuffer
        groupLock.unlock()

        if let buffer {
            let plainText = formatPlainMessage(message, level: level, group: group, timestamp: now)
            let entry = LogEntry(
                timestamp: now,
                level: level,
                message: message,
                group: group,
                formattedText: plainText,
            )
            buffer.append(entry)
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

    /// Formats a message for console output in DEBUG builds.
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
        let timestampString = formatTimestamp(timestamp)

        if PolyTerm.supportsANSI() {
            let timestampFormatted = "\(ANSIColor.reset.rawValue)\(ANSIColor.gray.rawValue)\(timestampString)\(ANSIColor.reset.rawValue) "
            let levelFormatted = "\(ANSIColor.bold.rawValue)\(level.color.rawValue)\(level.displayText)\(ANSIColor.reset.rawValue)"

            // Add group tag if present - use emoji if available, otherwise identifier in brackets
            let groupFormatted = if let group {
                if let emoji = group.emoji {
                    // Use emoji directly (no brackets, no color needed - emoji is already colorful)
                    "\(emoji) "
                } else {
                    // Fall back to identifier in brackets with color
                    "\(ANSIColor.cyan.rawValue)[\(group.identifier)]\(ANSIColor.reset.rawValue) "
                }
            } else {
                ""
            }

            let messageFormatted = "\(level.color.rawValue)\(message)\(ANSIColor.reset.rawValue)"
            return "\(timestampFormatted)\(levelFormatted)\(groupFormatted)\(messageFormatted)"
        } else {
            return formatPlainMessage(message, level: level, group: group, timestamp: timestamp)
        }
    }

    /// Formats a message as plain text (no ANSI codes) for capture and export.
    private func formatPlainMessage(
        _ message: String,
        level: LogLevel,
        group: LogGroup?,
        timestamp: Date,
    ) -> String {
        let timestampString = formatTimestamp(timestamp)

        // Use emoji if present, otherwise identifier in brackets
        let groupTag = if let group {
            if let emoji = group.emoji {
                "\(emoji) "
            } else {
                "[\(group.identifier)] "
            }
        } else {
            ""
        }

        return "\(timestampString) \(level.displayText)\(groupTag)\(message)"
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
