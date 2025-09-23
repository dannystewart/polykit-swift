//
//  PolyLog.swift
//  PolyLog
//
//  Created by Danny Stewart on 9/22/25.
//

import Foundation
import os

// MARK: PolyLog Main Class

public final class PolyLog: @unchecked Sendable {
    public static let _shared = PolyLog()
    private var loggers: [String: Logger] = [:]

    private init() {}

    public static func getLogger(
        _ name: String? = nil,
        level: LogLevel = .debug,
        simple: Bool = false,
        color: Bool = true
    ) -> PolyLogger {
        let loggerName = _getLoggerName(name)
        return _shared.createLogger(name: loggerName, level: level, simple: simple, color: color)
    }

    private static func _getLoggerName(_ name: String? = nil) -> String {
        if let name = name {
            return name
        }

        // Use Swift's built-in introspection to automatically determine logger name
        let fileID = #fileID  // e.g., "MyApp/MyClass.swift"
        let function = #function  // e.g., "myMethod()"

        // Extract module and file from fileID
        let components = fileID.split(separator: "/")
        if components.count >= 2 {
            let module = String(components[0])
            let fileName = String(components[1]).replacingOccurrences(of: ".swift", with: "")
            return "\(module).\(fileName)"
        }

        // Fallback to just the function name if we can't parse fileID
        return function
    }

    private func createLogger(
        name: String,
        level: LogLevel,
        simple: Bool,
        color: Bool
    ) -> PolyLogger {
        // Use a more specific subsystem for better visibility in Console.app
        let subsystem = Bundle.main.bundleIdentifier ?? "com.dannystewart.polylog"
        let osLogger = Logger(
            subsystem: subsystem,
            category: name
        )
        return PolyLogger(osLogger: osLogger, level: level, simple: simple, color: color)
    }
}

// MARK: PolyLogger Wrapper

public struct PolyLogger {
    private let osLogger: Logger
    private let level: LogLevel
    private let simple: Bool
    private let color: Bool

    init(osLogger: Logger, level: LogLevel, simple: Bool, color: Bool) {
        self.osLogger = osLogger
        self.level = level
        self.simple = simple
        self.color = color
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

    private func log(_ message: String, level: LogLevel) {
        let formattedMessage = formatMessage(message, level: level)

        // Output directly to the console for immediate visibility
        switch level {
        case .debug, .info:
            print(formattedMessage)
        case .warning, .error, .fault:
            // For error levels, write to stderr
            FileHandle.standardError.write(Data((formattedMessage + "\n").utf8))
        }

        // Also log to unified logging system for system logs
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

    private func formatMessage(_ message: String, level: LogLevel) -> String {
        if !color {
            return simple ? message : "\(timestamp()) \(level.displayText) \(message)"
        }

        let levelColor = level.color.rawValue
        let reset = LogColors.reset.rawValue
        let bold = LogColors.bold.rawValue
        let gray = LogColors.gray.rawValue

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

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: Date())
    }
}

// MARK: Log Levels

public enum LogLevel: String, CaseIterable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case fault = "fault"

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }

    var color: LogColors {
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

// MARK: Log Colors

public enum LogColors: String, CaseIterable {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case white = "\u{001B}[37m"
    case black = "\u{001B}[30m"
    case blue = "\u{001B}[34m"
    case cyan = "\u{001B}[36m"
    case gray = "\u{001B}[90m"
    case green = "\u{001B}[32m"
    case magenta = "\u{001B}[95m"
    case purple = "\u{001B}[35m"
    case red = "\u{001B}[31m"
    case yellow = "\u{001B}[33m"
    case brightBlue = "\u{001B}[94m"
    case brightCyan = "\u{001B}[96m"
    case brightGreen = "\u{001B}[92m"
    case brightRed = "\u{001B}[91m"
    case brightWhite = "\u{001B}[97m"
    case brightYellow = "\u{001B}[93m"
}
