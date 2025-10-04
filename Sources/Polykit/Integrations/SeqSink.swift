import Foundation
import os

// MARK: - PolySeq

/// A log sink that streams logs to a Seq server via the CLEF (Compact Log Event Format) over HTTP.
///
/// Batches logs to reduce network overhead and fails gracefully if the server is unreachable.
/// Enriches logs with contextual properties like app version, device info, and session ID.
public actor SeqSink {
    private let serverUrl: URL
    private let apiKey: String?
    private let batchSize: Int
    private let flushInterval: TimeInterval
    private var buffer: [SeqEvent] = []
    private var flushTask: Task<Void, Never>?
    private let session: URLSession
    private let sessionId: String
    private let enrichmentProperties: [String: String]

    /// Creates a new Seq sink for streaming logs.
    ///
    /// - Parameters:
    ///   - serverUrl: The base URL of your Seq server (e.g., "http://localhost:5341").
    ///   - apiKey: Optional API key for authentication.
    ///   - batchSize: Number of events to buffer before sending (default: 10).
    ///   - flushInterval: Maximum time to wait before sending partial batches (default: 5 seconds).
    public init(
        serverUrl: String,
        apiKey: String? = nil,
        batchSize: Int = 10,
        flushInterval: TimeInterval = 5.0,
    ) {
        // Ensure the URL doesn't have a trailing slash
        let cleanUrl = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        self.serverUrl = URL(string: "\(cleanUrl)/api/events/raw")!
        self.apiKey = apiKey
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        sessionId = UUID().uuidString

        // Configure URLSession for background operation
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)

        // Gather enrichment properties once at initialization
        var properties: [String: String] = [
            "Application": Bundle.main.bundleIdentifier ?? "unknown",
            "SessionId": sessionId,
        ]

        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            properties["Version"] = version
        }

        #if DEBUG
            properties["Environment"] = "Debug"
        #else
            properties["Environment"] = "Production"
        #endif

        // Add device info
        #if os(macOS)
            properties["Platform"] = "macOS"
            properties["OSVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
            properties["MachineName"] = ProcessInfo.processInfo.hostName
        #elseif os(iOS)
            properties["Platform"] = "iOS"
            properties["OSVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        enrichmentProperties = properties
    }

    /// Starts the periodic flush task. Must be called after initialization.
    public func start() {
        guard flushTask == nil else { return }
        startPeriodicFlush()
    }

    deinit {
        flushTask?.cancel()
    }

    /// Adds a log event to the buffer and sends it to Seq if batch size is reached.
    public func log(_ message: String, level: LogLevel, sourceContext: String? = nil) {
        let event = SeqEvent(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: level.seqLevel,
            messageTemplate: message,
            properties: enrichmentProperties.merging(
                sourceContext.map { ["SourceContext": $0] } ?? [:],
                uniquingKeysWith: { _, new in new },
            ),
        )

        buffer.append(event)

        if buffer.count >= batchSize {
            Task { await flush() }
        }
    }

    /// Immediately sends all buffered events to Seq.
    public func flush() async {
        guard !buffer.isEmpty else { return }

        let eventsToSend = buffer
        buffer.removeAll()

        await sendEvents(eventsToSend)
    }

    /// Sends a batch of events to Seq via HTTP POST.
    private func sendEvents(_ events: [SeqEvent]) async {
        // Convert events to CLEF format (newline-delimited JSON)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var clefLines: [String] = []
        for event in events {
            guard let jsonData = try? encoder.encode(event),
                  let jsonString = String(data: jsonData, encoding: .utf8)
            else {
                continue
            }
            clefLines.append(jsonString)
        }

        guard !clefLines.isEmpty else { return }

        let clefBody = clefLines.joined(separator: "\n")
        guard let bodyData = clefBody.data(using: .utf8) else { return }

        // Build request
        var request = URLRequest(url: serverUrl)
        request.httpMethod = "POST"
        request.setValue("application/vnd.serilog.clef", forHTTPHeaderField: "Content-Type")

        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Seq-ApiKey")
        }

        request.httpBody = bodyData

        // Send asynchronously and fail gracefully.
        do {
            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                    // Log failure to system logger (not console to avoid recursion)
                    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.polykit", category: "SeqSink")
                    logger.warning("Seq ingestion failed with status \(httpResponse.statusCode)")
                }
            }
        } catch {
            // Fail silently - we don't want Seq failures to crash the app.
            // Only log to system logger in debug builds.
            #if DEBUG
                let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.polykit", category: "SeqSink")
                logger.debug("Failed to send logs to Seq: \(error.localizedDescription)")
            #endif
        }
    }

    /// Starts a periodic timer to flush logs even if batch size isn't reached.
    private func startPeriodicFlush() {
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                await flush()
            }
        }
    }
}

// MARK: - SeqEvent

/// Represents a log event in Seq's CLEF format.
struct SeqEvent: Codable {
    let timestamp: String
    let level: String
    let messageTemplate: String
    let properties: [String: String]

    enum CodingKeys: String, CodingKey {
        case timestamp = "@t"
        case level = "@l"
        case messageTemplate = "@mt"
        case properties
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(level, forKey: .level)
        try container.encode(messageTemplate, forKey: .messageTemplate)

        // Flatten properties into the root object (Seq convention)
        var propertiesContainer = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in properties {
            try propertiesContainer.encode(value, forKey: DynamicKey(stringValue: key)!)
        }
    }
}

// MARK: - DynamicKey

/// Dynamic coding key for encoding arbitrary property names.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

// MARK: - LogLevel Extension

extension LogLevel {
    /// Maps PolyLog levels to Seq levels.
    var seqLevel: String {
        switch self {
        case .debug: "Debug"
        case .info: "Information"
        case .warning: "Warning"
        case .error: "Error"
        case .fault: "Fatal"
        }
    }
}
