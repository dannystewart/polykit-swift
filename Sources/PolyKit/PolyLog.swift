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
    // MARK: Properties

    public let identifier: String
    public let emoji: String?

    // MARK: Lifecycle

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
public final class PolyLog: @unchecked Sendable {
    // MARK: Properties

    #if canImport(os)
        private let osLogger: Logger
    #endif

    /// Thread-safe storage for enabled/disabled groups
    private let groupLock: NSLock = .init()
    private var disabledGroups: Set<LogGroup> = []

    // MARK: Lifecycle

    public nonisolated init() {
        #if canImport(os)
            /// Use the app's bundle identifier
            let subsystem = Bundle.main.bundleIdentifier ?? "com.unknown.app.polylog"
            osLogger = Logger(subsystem: subsystem, category: "PolyLog")
        #endif
    }

    // MARK: Functions

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

    /// Logs a message at the specified level.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - level:   The level of the message.
    ///   - group:    Optional group for categorization and filtering.
    ///
    /// - Note: Warnings, errors, and faults always print regardless of group filtering.
    ///         Only debug and info messages are filtered by disabled groups.
    private func log(_ message: String, level: LogLevel, group: LogGroup? = nil) {
        // Check if this group is disabled (but only for debug/info - warnings and above always print)
        if let group, level.isFilterable {
            groupLock.lock()
            let isDisabled = disabledGroups.contains(group)
            groupLock.unlock()

            if isDisabled {
                return // Skip logging for disabled groups (debug/info only)
            }
        }

        let formattedMessage = formatConsoleMessage(message, level: level, group: group)

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

    // Formats a message for console output in DEBUG builds.
    //
    // - Parameters:
    //   - message: The message to format.
    //   - level:   The level of the message.
    //   - group:    Optional group identifier.
    // - Returns: The formatted message with colors (if real terminal) and timestamps.
    private func formatConsoleMessage(_ message: String, level: LogLevel, group: LogGroup? = nil) -> String {
        if PolyTerm.supportsANSI() {
            let timestampFormatted = "\(ANSIColor.reset.rawValue)\(ANSIColor.gray.rawValue)\(timestamp())\(ANSIColor.reset.rawValue) "
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
            // Non-ANSI terminals: use emoji if present, otherwise identifier in brackets
            let groupTag = if let group {
                if let emoji = group.emoji {
                    "\(emoji) "
                } else {
                    "[\(group.identifier)] "
                }
            } else {
                ""
            }
            return "\(timestamp()) \(level.displayText)\(groupTag)\(message)"
        }
    }

    // Formats the current time for use in a log message.
    //
    // - Returns: The current timestamp in the format "h:mm:ss a".
    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss.SSS a"
        return formatter.string(from: Date())
    }
}

// MARK: - LoggableError

// Protocol for errors that can be logged and thrown.
public protocol LoggableError: Error { var logMessage: String { get }}

// Extension for PolyLog to add logging and throwing capabilities.
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

// Enum representing various log levels.
public enum LogLevel: String, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
    case fault

    // MARK: Computed Properties

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

    /// Whether this log level can be filtered by disabled groups.
    /// Warnings, errors, and faults always print regardless of group filtering.
    var isFilterable: Bool {
        switch self {
        case .debug, .info: true
        case .warning, .error, .fault: false
        }
    }
}
