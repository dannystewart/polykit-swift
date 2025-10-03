import Foundation
import os

// MARK: - PolyLog

/// Class for logging messages to the console and system log.
///
/// In DEBUG builds, logs are formatted and printed to console with colors and timestamps.
/// In production builds, all logs go directly to the unified logging system.
public final class PolyLog: @unchecked Sendable {
    private let osLogger: Logger
    private var seqSink: PolySeq?

    public nonisolated init(seqSink: PolySeq? = nil) {
        self.seqSink = seqSink

        // Use the app's bundle identifier
        let subsystem = Bundle.main.bundleIdentifier ?? "com.unknown.app.polylog"
        osLogger = Logger(subsystem: subsystem, category: "PolyLog")
    }

    /// Enables Seq logging by setting the SeqSink. Can be called after initialization.
    public func setSeqSink(_ sink: PolySeq?) {
        seqSink = sink
    }

    /// Creates a PolyLog instance with Seq support that will be enabled later.
    ///
    /// Use this when you need a logger immediately but want to enable Seq asynchronously.
    /// Call `setSeqSink()` later to enable Seq logging.
    public static func withSeqSupport() -> PolyLog {
        PolyLog(seqSink: nil)
    }

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
        #if DEBUG
            // DEBUG: Console output (only using colors if in a real TTY)
            let formattedMessage = formatConsoleMessage(message, level: level)
            switch level {
            case .debug, .info:
                print(formattedMessage)
            case .warning, .error, .fault:
                fputs(formattedMessage + "\n", stderr)
            }
        #else
            // Production: System logger only
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

        // Send to Seq if configured
        if let seqSink {
            Task {
                await seqSink.log(message, level: level)
            }
        }
    }

    /// Formats a message for console output in DEBUG builds.
    ///
    /// - Parameters:
    ///   - message: The message to format.
    ///   - level:   The level of the message.
    /// - Returns: The formatted message with colors (if real terminal) and timestamps.
    private func formatConsoleMessage(_ message: String, level: LogLevel) -> String {
        let useColors = shouldUseColors()

        if useColors {
            let timestampFormatted = "\(TextColor.reset.rawValue)\(TextColor.gray.rawValue)\(timestamp())\(TextColor.reset.rawValue) "
            let levelFormatted = "\(TextColor.bold.rawValue)\(level.color.rawValue)\(level.displayText)\(TextColor.reset.rawValue)"
            let messageFormatted = "\(level.color.rawValue)\(message)\(TextColor.reset.rawValue)"
            return "\(timestampFormatted)\(levelFormatted)\(messageFormatted)"
        } else {
            return "\(timestamp()) \(level.displayText)\(message)"
        }
    }

    /// Determines if we should use ANSI colors based on the environment.
    ///
    /// - Returns: True if we're in a real terminal that supports colors, false if in Xcode or other non-color environment.
    private func shouldUseColors() -> Bool {
        // Check if we're running in Xcode by looking for Xcode-specific environment variables
        if ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil ||
            ProcessInfo.processInfo.environment["XCODE_VERSION_MAJOR"] != nil { return false }

        // Check if stdout is a TTY and we have a TERM environment variable
        return isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != nil
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

// MARK: - LogLevel

/// Enum representing various log levels.
public enum LogLevel: String, CaseIterable, Sendable {
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
        case .debug: "   [DEBUG] "
        case .info: "    [INFO] "
        case .warning: " [WARNING] "
        case .error: "  ![ERROR] "
        case .fault: "  !![CRIT] "
        }
    }
}
