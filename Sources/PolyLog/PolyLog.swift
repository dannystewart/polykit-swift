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
        _ name: String,
        level: LogLevel = .info,
        simple: Bool = false,
        color: Bool = true
    ) -> PolyLogger {
        return _shared.createLogger(name: name, level: level, simple: simple, color: color)
    }

    private func createLogger(
        name: String,
        level: LogLevel,
        simple: Bool,
        color: Bool
    ) -> PolyLogger {
        let osLogger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.dannystewart.polylog",
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
