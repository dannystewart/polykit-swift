import Foundation
import os

// MARK: - PolyLog

/// Struct for logging messages to the console and system log.
///
/// - Parameters:
///   - simple: Whether to omit timestamps and level indicators. Defaults to false.
///   - color:  Whether to use colorized output. Defaults to true.
///   - debug:  Whether to log debug messages. Otherwise only logs info and above. Defaults to true.
public struct PolyLog: @unchecked Sendable {
    private let osLogger: Logger
    private let messageOnly: Bool
    private let color: Bool
    private let debug: Bool

    public init(
        simple: Bool = false,
        color: Bool = true,
        debug: Bool = true,
    ) {
        messageOnly = simple
        self.color = color
        self.debug = debug

        // Use the app's bundle identifier
        let subsystem = Bundle.main.bundleIdentifier ?? "com.unknown.app.polylog"
        osLogger = Logger(subsystem: subsystem, category: "PolyLog")
    }

    /// Logs a debug message.
    ///
    /// - Parameter message: The message to log.
    public func debug(_ message: String) {
        if debug {
            log(message, level: .debug)
        } else {
            let formattedMessage = formatMessage(message, level: .debug)
            osLogger.debug("\(formattedMessage, privacy: .public)")
        }
    }

    /// Logs an info message.
    ///
    /// - Parameter message: The message to log.
    public func info(_ message: String) {
        log(message, level: .info)
    }

    /// Logs a warning message.
    ///
    /// - Parameter message: The message to log.
    public func warning(_ message: String) {
        log(message, level: .warning)
    }

    /// Logs an error message.
    ///
    /// - Parameter message: The message to log.
    public func error(_ message: String) {
        log(message, level: .error)
    }

    /// Logs a fault message.
    ///
    /// - Parameter message: The message to log.
    public func fault(_ message: String) {
        log(message, level: .fault)
    }

    /// Logs a message at the specified level.
    ///
    /// - Parameters:
    ///   - message: The message to log.
    ///   - level:   The level of the message.
    private func log(_ message: String, level: LogLevel) {
        #if DEBUG // Xcode: show plain output for debug console
            let formattedMessage = messageOnly ? message : "\(timestamp()) \(level.displayText) \(message)"
            switch level {
            case .debug, .info:
                print(formattedMessage)
            case .warning, .error, .fault:
                fputs(formattedMessage + "\n", stderr)
            }
        #else // Production: send directly to unified logging
            switch level.osLogType {
            case .debug:
                osLogger.debug("\(message, privacy: .public)")
            case .info:
                osLogger.info("\(message, privacy: .public)")
            case .default:
                osLogger.notice("\(message, privacy: .public)")
            case .error:
                osLogger.error("\(message, privacy: .public)")
            case .fault:
                osLogger.fault("\(message, privacy: .public)")
            default:
                osLogger.log("\(message, privacy: .public)")
            }
        #endif
    }

    /// Formats a message for the specified level.
    ///
    /// - Parameters:
    ///   - message: The message to format.
    ///   - level:   The level of the message.
    /// - Returns: The formatted message.
    private func formatMessage(_ message: String, level: LogLevel) -> String {
        if !color { return messageOnly ? message : "\(timestamp()) \(level.displayText) \(message)" }

        let levelColor = level.color.rawValue
        let reset = TextColor.reset.rawValue
        let bold = TextColor.bold.rawValue
        let gray = TextColor.gray.rawValue

        if messageOnly {
            let shouldBold = level != .debug && level != .info
            let boldPrefix = shouldBold ? bold : ""
            return "\(reset)\(boldPrefix)\(levelColor)\(message)\(reset)"
        }

        let timestampFormatted = "\(reset)\(gray)\(timestamp())\(reset) "
        let levelFormatted = "\(bold)\(levelColor)\(level.displayText)\(reset)"
        let messageFormatted = "\(levelColor)\(message)\(reset)"

        return "\(timestampFormatted)\(levelFormatted)\(messageFormatted)"
    }

    /// Formats the current time for use in a log message.
    ///
    /// - Returns: The current timestamp in the format "h:mm:ss a".
    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: Date())
    }
}

// MARK: - LogLevel

/// Enum representing various log levels.
public enum LogLevel: String, CaseIterable {
    case debug
    case info
    case warning
    case error
    case fault

    var osLogType: OSLogType {
        switch self {
        case .debug: .default
        case .info: .default
        case .warning: .default
        case .error: .error
        case .fault: .fault
        }
    }

    var color: TextColor {
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
        case .debug: "[DEBUG] "
        case .info: ""
        case .warning: "[WARNING] "
        case .error: "[ERROR] "
        case .fault: "[CRITICAL] "
        }
    }
}

// MARK: - LoggableError

/// Protocol for errors that can be logged and thrown.
public protocol LoggableError: Error {
    var logMessage: String { get }
    var isWarning: Bool { get }
}

/// Extension for PolyLog to add logging and throwing capabilities.
public extension PolyLog {
    func logAndThrow(_ error: some LoggableError) throws {
        if error.isWarning {
            warning(error.logMessage)
        } else {
            self.error(error.logMessage)
        }
        throw error
    }

    func logAndExit(_ error: some LoggableError) -> Never {
        if error.isWarning {
            warning(error.logMessage)
        } else {
            self.error(error.logMessage)
        }
        Foundation.exit(1)
    }
}
