import Foundation
import os
import PolyText

/// Struct for logging messages to the console and system log.
///
/// - Parameters:
///   - simple: Whether to omit timestamps and level indicators. Defaults to false.
///   - color:  Whether to use colorized output. Defaults to true.
///   - debug:  Whether to log debug messages. Otherwise only logs info and above. Defaults to true.
public struct PolyLog: @unchecked Sendable {
    private let osLogger: Logger
    private let simple: Bool
    private let color: Bool
    private let debug: Bool

    public init(
        simple: Bool = false,
        color: Bool = true,
        debug: Bool = true
    ) {
        self.simple = simple
        self.color = color
        self.debug = debug

        let subsystem = Bundle.main.bundleIdentifier ?? "com.dannystewart.polylog"
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
        let formattedMessage = formatMessage(message, level: level)

        // Output to console for immediate visibility
        switch level {
        case .debug, .info:
            print(formattedMessage)
        case .warning, .error, .fault:
            FileHandle.standardError.write(Data((formattedMessage + "\n").utf8))
        }

        // Also log to system for Console.app and production debugging
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
    }

    /// Formats a message for the specified level.
    ///
    /// - Parameters:
    ///   - message: The message to format.
    ///   - level:   The level of the message.
    /// - Returns: The formatted message.
    private func formatMessage(_ message: String, level: LogLevel) -> String {
        if !color {
            return simple ? message : "\(timestamp()) \(level.displayText) \(message)"
        }

        let levelColor = level.color.rawValue
        let reset = TextColor.reset.rawValue
        let bold = TextColor.bold.rawValue
        let gray = TextColor.gray.rawValue

        if simple {
            let shouldBold = level != .debug && level != .info
            let boldPrefix = shouldBold ? bold : ""
            return "\(reset)\(boldPrefix)\(levelColor)\(message)\(reset)"
        }

        let timestampFormatted = "\(reset)\(gray)\(timestamp())\(reset) "
        let levelFormatted = "\(bold)\(levelColor)\(level.displayText)\(reset)"
        let messageFormatted = "\(levelColor)\(message)\(reset)"

        return "\(timestampFormatted)\(levelFormatted) \(messageFormatted)"
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

/// Enum representing various log levels.
public enum LogLevel: String, CaseIterable {
    case debug
    case info
    case warning
    case error
    case fault

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }

    var color: TextColor {
        switch self {
        case .debug: return .gray
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        case .fault: return .magenta
        }
    }

    var displayText: String {
        switch self {
        case .debug: return "[DEBUG]"
        case .info: return "[INFO]"
        case .warning: return "[WARN]"
        case .error: return "[ERROR]"
        case .fault: return "[FAULT]"
        }
    }
}
