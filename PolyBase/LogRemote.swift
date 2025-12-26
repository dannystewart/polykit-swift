//
//  LogRemote.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Auth
import Foundation
import PolyKit
import Supabase
#if canImport(UIKit) && !os(macOS)
    import UIKit
#endif
#if canImport(WatchKit)
    import WatchKit
#endif
#if canImport(IOKit)
    import IOKit
#endif

// MARK: - LogRemote

/// Service for streaming log entries to Supabase in real-time.
///
/// Works alongside `LogPersistence` to provide remote log aggregation.
/// Logs are buffered in memory and pushed periodically to minimize network overhead.
///
/// ## Usage
///
/// Add `POLYLOGS_URL` and `POLYLOGS_KEY` to your app's Info.plist (via Secrets.xcconfig),
/// then simply call:
///
/// ```swift
/// LogRemote.shared.start()
/// ```
///
/// The credentials are read automatically from Info.plist. These use separate key names
/// from your app's own Supabase config to avoid conflicts. Alternatively, you can
/// configure explicitly via `LogRemoteConfig`.
///
/// Once started, all log entries from `logger` (the global PolyLog instance)
/// are automatically buffered and streamed to Supabase.
public final class LogRemote: @unchecked Sendable {
    // MARK: - Push

    /// Parameters for pushing log entries to Supabase.
    private struct PushEntriesParameters {
        let entries: [LogEntry]
        let client: SupabaseClient
        let tableName: String
        let deviceID: String
        let sessionID: String
        let appBundleID: String
    }

    // MARK: - Singleton

    /// Shared instance for remote logging.
    public static let shared: LogRemote = .init()

    /// Whether remote logging is currently active.
    public private(set) var isRunning = false

    // MARK: - Configuration

    /// Supabase client for remote operations.
    private var client: SupabaseClient?

    /// Configuration in use.
    private var config: LogRemoteConfig?

    /// Lock for thread-safe access.
    private let lock: NSLock = .init()

    /// Buffer for pending log entries.
    private var buffer: [LogEntry] = []

    /// Maximum buffer size before forced flush.
    private let bufferFlushThreshold = 10

    /// Periodic flush interval (matches LogPersistence).
    private let flushInterval: TimeInterval = 0.15

    /// Timer for periodic flush.
    private var flushTimer: DispatchSourceTimer?

    /// Queue for flush operations (background, utility priority).
    private let flushQueue: DispatchQueue = .init(
        label: "com.dannystewart.PolyKit.LogRemote.flush",
        qos: .utility,
    )

    // MARK: - Device Identity

    /// Stable device identifier based on hardware UUID.
    ///
    /// Uses IOPlatformUUID on macOS/iOS to ensure all apps on the same device
    /// share the same device ID. Falls back to a persistent ULID if hardware ID is unavailable.
    private lazy var deviceID: String = {
        // Try to get hardware-based device ID
        if let hardwareID = Self.getHardwareDeviceID() {
            return hardwareID
        }

        // Fall back to persistent ULID in UserDefaults (legacy behavior)
        let key = "com.dannystewart.PolyKit.LogRemote.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }

        // Generate new ULID as last resort
        let newID = ULIDGenerator.shared.next()
        UserDefaults.standard.set(newID, forKey: key)
        polyWarning("LogRemote: Unable to get hardware device ID, generated fallback: \(newID)")
        return newID
    }()

    /// Unique session identifier (changes on each app launch).
    /// ULID timestamp indicates when the session started.
    private let sessionID = ULIDGenerator.shared.next()

    /// App bundle identifier.
    private var appBundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    deinit {
        flushTimer?.cancel()
        flushTimer = nil
    }

    // MARK: - Initialization

    private init() {}

    /// Get a stable hardware-based device identifier.
    ///
    /// - macOS: Uses IOPlatformUUID (stable per-device, consistent across all apps)
    /// - iOS/tvOS/visionOS/watchOS: Uses identifierForVendor (stable per-device, per-vendor)
    ///
    /// Returns nil if unable to retrieve hardware ID.
    private static func getHardwareDeviceID() -> String? {
        #if os(macOS)
            return self.getIOPlatformUUID()
        #elseif os(watchOS)
            return self.getWatchVendorIdentifier()
        #elseif os(iOS) || os(tvOS) || os(visionOS)
            return self.getVendorIdentifier()
        #else
            return nil
        #endif
    }

    /// Retrieve IOPlatformUUID from IOKit (macOS only).
    ///
    /// This is the same UUID used by system profilers and is stable per-device.
    private static func getIOPlatformUUID() -> String? {
        #if canImport(IOKit)
            let platformExpert = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPlatformExpertDevice"),
            )

            guard platformExpert != 0 else { return nil }
            defer { IOObjectRelease(platformExpert) }

            guard
                let uuidCF = IORegistryEntryCreateCFProperty(
                    platformExpert,
                    "IOPlatformUUID" as CFString,
                    kCFAllocatorDefault,
                    0,
                )?.takeRetainedValue() else
            {
                return nil
            }

            return uuidCF as? String
        #else
            return nil
        #endif
    }

    /// Retrieve vendor identifier from UIDevice (iOS/tvOS/watchOS/visionOS).
    ///
    /// Stable per-device as long as at least one app from the same vendor remains installed.
    /// This is the officially sanctioned way to get a device identifier on iOS.
    private static func getVendorIdentifier() -> String? {
        #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
            return UIDevice.current.identifierForVendor?.uuidString
        #else
            return nil
        #endif
    }

    /// Retrieve vendor identifier from WKInterfaceDevice (watchOS).
    ///
    /// Stable per-device as long as at least one app from the same vendor remains installed.
    private static func getWatchVendorIdentifier() -> String? {
        #if canImport(WatchKit) && os(watchOS)
            return WKInterfaceDevice.current().identifierForVendor?.uuidString
        #else
            return nil
        #endif
    }

    /// Start remote logging.
    ///
    /// Credentials are loaded in this order:
    /// 1. `LogRemoteConfig.shared` if configured via `configure()` or `load()`
    /// 2. `POLYLOGS_URL` and `POLYLOGS_KEY` from the host app's Info.plist
    ///
    /// If no configuration is available, this method logs a warning and does nothing.
    public func start() {
        // Try shared config first
        if let config = LogRemoteConfig.shared {
            self.start(config: config)
            return
        }

        // Fall back to Info.plist
        guard let config = loadConfigFromInfoPlist() else {
            polyWarning("LogRemote: No configuration available. Add POLYLOGS_URL and POLYLOGS_KEY to Info.plist, or call LogRemoteConfig.configure().")
            return
        }
        self.start(config: config)
    }

    /// Start remote logging with explicit configuration.
    ///
    /// - Parameter config: The Supabase configuration to use.
    public func start(config: LogRemoteConfig) {
        // Check if logger is configured before acquiring lock
        guard let appLogger = PolyBaseConfig.shared.logger else {
            polyWarning("LogRemote: No logger configured in PolyBaseConfig. Call PolyBaseConfig.configure(logger:) first.")
            return
        }

        // Capture values for logging outside the lock (to avoid deadlock)
        let hostName: String
        let deviceIDValue: String
        let sessionIDValue: String
        let appBundleIDValue: String

        self.lock.lock()

        guard !self.isRunning else {
            self.lock.unlock()
            polyDebug("LogRemote: Already running")
            return
        }

        self.config = config
        self.client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: .init(
                auth: .init(
                    // Opt-in to new session behavior to silence deprecation warning
                    emitLocalSessionAsInitialSession: true,
                ),
            ),
        )

        // Hook into the configured logger
        appLogger.onLogEntry = { [weak self] entry in
            self?.bufferEntry(entry)
        }

        self.isRunning = true
        self.startFlushTimerUnsafe()

        // Capture values before unlocking
        hostName = config.supabaseURL.host ?? "unknown"
        deviceIDValue = self.deviceID
        sessionIDValue = self.sessionID
        appBundleIDValue = self.appBundleID

        self.lock.unlock()

        // Log AFTER releasing the lock to avoid deadlock
        polyInfo("LogRemote: Started streaming to \(hostName)")
        polyDebug("LogRemote: deviceID=\(deviceIDValue), sessionID=\(sessionIDValue), app=\(appBundleIDValue)")
    }

    /// Stop remote logging and flush remaining entries.
    public func stop() {
        self.lock.lock()
        defer { lock.unlock() }

        guard self.isRunning else { return }

        // Remove hook from logger
        PolyBaseConfig.shared.logger?.onLogEntry = nil

        // Flush remaining entries
        self.flushBufferUnsafe()

        self.stopFlushTimerUnsafe()

        self.client = nil
        self.config = nil
        self.isRunning = false

        polyInfo("LogRemote: Stopped")
    }

    /// Flush all buffered entries immediately.
    public func flush() {
        self.lock.lock()
        let entries = self.buffer
        self.buffer.removeAll(keepingCapacity: true)
        let currentClient = client
        let currentConfig = config
        self.lock.unlock()

        guard !entries.isEmpty, let client = currentClient, let config = currentConfig else {
            return
        }

        // Push asynchronously
        Task.detached { [weak self, deviceID, sessionID, appBundleID] in
            await self?.pushEntries(PushEntriesParameters(
                entries: entries,
                client: client,
                tableName: config.tableName,
                deviceID: deviceID,
                sessionID: sessionID,
                appBundleID: appBundleID,
            ))
        }
    }

    /// Load configuration from the host app's Info.plist.
    ///
    /// Looks for `POLYLOGS_URL` and `POLYLOGS_KEY` to avoid conflicts with
    /// an app's own Supabase configuration.
    private func loadConfigFromInfoPlist() -> LogRemoteConfig? {
        guard
            let infoDictionary = Bundle.main.infoDictionary,
            let urlString = infoDictionary["POLYLOGS_URL"] as? String,
            let supabaseURL = URL(string: urlString),
            let supabaseKey = infoDictionary["POLYLOGS_KEY"] as? String else
        {
            return nil
        }

        let tableName = infoDictionary["POLYLOGS_TABLE"] as? String ?? "polylogs"
        return LogRemoteConfig(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            tableName: tableName,
        )
    }

    // MARK: - Buffering

    /// Buffer a log entry for later push.
    private func bufferEntry(_ entry: LogEntry) {
        self.lock.lock()
        self.buffer.append(entry)
        let shouldFlush = self.buffer.count >= self.bufferFlushThreshold
        self.lock.unlock()

        if shouldFlush {
            self.flush()
        }
    }

    /// Flush buffer without lock (caller must hold lock).
    private func flushBufferUnsafe() {
        guard !self.buffer.isEmpty, let client, let config else { return }

        let entries = self.buffer
        self.buffer.removeAll(keepingCapacity: true)

        let deviceID = deviceID
        let sessionID = sessionID
        let appBundleID = appBundleID

        // Push asynchronously
        Task.detached { [weak self] in
            await self?.pushEntries(PushEntriesParameters(
                entries: entries,
                client: client,
                tableName: config.tableName,
                deviceID: deviceID,
                sessionID: sessionID,
                appBundleID: appBundleID,
            ))
        }
    }

    /// Push log entries to Supabase.
    private func pushEntries(_ params: PushEntriesParameters) async {
        guard !params.entries.isEmpty else { return }

        // Build records
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let records: [[String: AnyJSON]] = params.entries.map { entry in
            // Generate ULID from the log entry's timestamp (not push time)
            let ulid = ULID.generate(for: entry.timestamp)

            var record: [String: AnyJSON] = [
                "id": .string(ulid),
                "timestamp": .string(isoFormatter.string(from: entry.timestamp)),
                "level": .string(entry.level.rawValue),
                "message": .string(entry.message),
                "device_id": .string(params.deviceID),
                "session_id": .string(params.sessionID),
                "app_bundle_id": .string(params.appBundleID),
            ]

            if let group = entry.group {
                record["group_identifier"] = .string(group.identifier)
                if let emoji = group.emoji {
                    record["group_emoji"] = .string(emoji)
                }
            }

            return record
        }

        // Retry once on transient network errors (e.g., -1005 connection lost)
        var lastError: Error?
        for attempt in 1 ... 2 {
            do {
                try await params.client
                    .from(params.tableName)
                    .insert(records)
                    .execute()
                return // Success
            } catch {
                lastError = error
                let nsError = error as NSError
                let isTransient = nsError.domain == NSURLErrorDomain &&
                    [-1005, -1001, -1009].contains(nsError.code)

                if isTransient, attempt == 1 {
                    // Brief delay before retry
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                break
            }
        }

        // Log error but don't crash - remote logging is best-effort
        if let error = lastError {
            polyWarning("LogRemote: Push failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Timer

    /// Start the periodic flush timer (must hold lock).
    private func startFlushTimerUnsafe() {
        guard self.flushTimer == nil, self.isRunning || self.buffer.isEmpty == false else { return }

        let timer = DispatchSource.makeTimerSource(queue: self.flushQueue)
        timer.schedule(
            deadline: .now() + self.flushInterval,
            repeating: self.flushInterval,
            leeway: .milliseconds(50),
        )
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        self.flushTimer = timer
    }

    /// Stop the periodic flush timer (must hold lock).
    private func stopFlushTimerUnsafe() {
        self.flushTimer?.cancel()
        self.flushTimer = nil
    }
}
