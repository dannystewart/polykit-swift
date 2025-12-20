//
//  PolyBaseConfig.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import PolyKit
import SwiftData

// MARK: - PolyBaseConfig

/// Global configuration for PolyBase services.
///
/// Configure logging, model context, and other shared settings before using PolyBase services:
/// ```swift
/// PolyBaseConfig.configure(
///     logger: logger,
///     logGroup: .database,
///     modelContext: modelContext
/// )
/// ```
public final class PolyBaseConfig: @unchecked Sendable {
    /// Shared configuration instance.
    public static let shared: PolyBaseConfig = .init()

    /// Logger instance for PolyBase services. Set to `nil` to disable logging.
    public var logger: PolyLog?

    /// Log group for categorizing PolyBase logs. Set to `nil` for ungrouped logs.
    public var logGroup: LogGroup?

    /// Model context for SwiftData operations.
    /// Must be set before using sync services.
    public weak var modelContext: ModelContext?

    private init() {}

    /// Configure PolyBase with all settings.
    ///
    /// - Parameters:
    ///   - logger: The PolyLog instance to use. Pass `nil` to disable logging.
    ///   - logGroup: Optional log group for categorization. Pass `nil` for ungrouped logs.
    ///   - modelContext: The SwiftData model context for persistence operations.
    @MainActor
    public static func configure(
        logger: PolyLog?,
        logGroup: LogGroup? = nil,
        modelContext: ModelContext? = nil,
    ) {
        shared.logger = logger
        shared.logGroup = logGroup
        shared.modelContext = modelContext

        // Initialize the sync coordinator if model context is provided
        if let modelContext {
            PolySyncCoordinator.shared.initialize(with: modelContext)
        }
    }

    /// Configure PolyBase logging only.
    ///
    /// - Parameters:
    ///   - logger: The PolyLog instance to use. Pass `nil` to disable logging.
    ///   - logGroup: Optional log group for categorization. Pass `nil` for ungrouped logs.
    public static func configure(logger: PolyLog?, logGroup: LogGroup? = nil) {
        shared.logger = logger
        shared.logGroup = logGroup
    }

    /// Set the model context separately.
    ///
    /// Call this after app initialization when the model context becomes available.
    @MainActor
    public static func setModelContext(_ context: ModelContext) {
        shared.modelContext = context
        PolySyncCoordinator.shared.initialize(with: context)
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
