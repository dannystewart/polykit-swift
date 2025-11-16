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

// MARK: - PolyLog

/// Class for logging messages to the console and system log.
public final class PolyLog: @unchecked Sendable {
    // MARK: Properties

    #if canImport(os)
        private let osLogger: Logger
    #endif

    // MARK: Lifecycle

    public nonisolated init() {
        #if canImport(os)
            /// Use the app's bundle identifier
            let subsystem = Bundle.main.bundleIdentifier ?? "com.unknown.app.polylog"
            osLogger = Logger(subsystem: subsystem, category: "PolyLog")
        #endif
    }

    // MARK: Functions

    public func debug(_ message: String) {
        log(message, level: .debug)
    }

    public func info(_ message: String) {
        log(message, level: .info)
    }

    public func warning(_ message: String) {
        log(message, level: .warning)
    }

    public func error(_ message: String) {
        log(message, level: .error)
    }

    public func fault(_ message: String) {
        log(message, level: .fault)
    }

    /// Logs a message at the specified level.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - level:   The level of the message.
    private func log(_ message: String, level: LogLevel) {
        let formattedMessage = formatConsoleMessage(message, level: level)

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
    // - Returns: The formatted message with colors (if real terminal) and timestamps.
    private func formatConsoleMessage(_ message: String, level: LogLevel) -> String {
        if PolyTerm.supportsANSI() {
            let timestampFormatted = "\(ANSIColor.reset.rawValue)\(ANSIColor.gray.rawValue)\(timestamp())\(ANSIColor.reset.rawValue) "
            let levelFormatted = "\(ANSIColor.bold.rawValue)\(level.color.rawValue)\(level.displayText)\(ANSIColor.reset.rawValue)"
            let messageFormatted = "\(level.color.rawValue)\(message)\(ANSIColor.reset.rawValue)"
            return "\(timestampFormatted)\(levelFormatted)\(messageFormatted)"
        } else {
            return "\(timestamp()) \(level.displayText)\(message)"
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
}
