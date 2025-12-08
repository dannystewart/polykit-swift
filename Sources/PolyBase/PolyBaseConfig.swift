//
//  PolyBaseConfig.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import PolyKit

// MARK: - PolyBaseConfig

/// Global configuration for PolyBase services.
///
/// Configure logging and other shared settings before using PolyBase services:
/// ```swift
/// PolyBaseConfig.configure(logger: logger, logGroup: .database)
/// ```
public final class PolyBaseConfig: @unchecked Sendable {
    /// Shared configuration instance.
    public static let shared: PolyBaseConfig = .init()

    /// Logger instance for PolyBase services. Set to `nil` to disable logging.
    public var logger: PolyLog?

    /// Log group for categorizing PolyBase logs. Set to `nil` for ungrouped logs.
    public var logGroup: LogGroup?

    private init() {}

    /// Configure PolyBase logging.
    ///
    /// - Parameters:
    ///   - logger: The PolyLog instance to use. Pass `nil` to disable logging.
    ///   - logGroup: Optional log group for categorization. Pass `nil` for ungrouped logs.
    public static func configure(logger: PolyLog?, logGroup: LogGroup? = nil) {
        shared.logger = logger
        shared.logGroup = logGroup
    }
}

// MARK: - Internal Logging Helpers

/// Internal logging functions for PolyBase services.
/// These respect the configured logger and log group.
func polyLog(_ message: String, level: LogLevel = .debug) {
    guard let logger = PolyBaseConfig.shared.logger else { return }
    let group = PolyBaseConfig.shared.logGroup

    switch level {
    case .debug:
        logger.debug(message, group: group)
    case .info:
        logger.info(message, group: group)
    case .warning:
        logger.warning(message, group: group)
    case .error:
        logger.error(message, group: group)
    case .fault:
        logger.fault(message, group: group)
    }
}

func polyDebug(_ message: String) { polyLog(message, level: .debug) }
func polyInfo(_ message: String) { polyLog(message, level: .info) }
func polyWarning(_ message: String) { polyLog(message, level: .warning) }
func polyError(_ message: String) { polyLog(message, level: .error) }
