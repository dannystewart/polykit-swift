//
//  PolyBaseNetworkMonitor.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Network

// MARK: - PolyBaseNetworkMonitor

/// Monitors network connectivity and automatically processes the offline queue when connectivity returns.
///
/// This service is internal to PolyBase and starts automatically when PolyBase is configured.
/// Apps using PolyBase don't need to interact with this class directly.
final class PolyBaseNetworkMonitor: @unchecked Sendable {
    // MARK: - Singleton

    static let shared: PolyBaseNetworkMonitor = .init()

    // MARK: - State

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var isMonitoring = false
    private var wasConnected = true // Assume connected at start to avoid false positive on launch

    // MARK: - Initialization

    private init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.polybase.network-monitor", qos: .utility)
    }

    // MARK: - Public Interface

    /// Start monitoring network connectivity.
    ///
    /// Automatically called when PolyBase is configured. Safe to call multiple times.
    func startMonitoring() {
        guard !self.isMonitoring else { return }

        self.isMonitoring = true

        self.monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }

        self.monitor.start(queue: self.queue)
        polyDebug("PolyBaseNetworkMonitor: Started monitoring network connectivity")
    }

    /// Stop monitoring network connectivity.
    func stopMonitoring() {
        guard self.isMonitoring else { return }

        self.isMonitoring = false
        self.monitor.cancel()
        polyDebug("PolyBaseNetworkMonitor: Stopped monitoring network connectivity")
    }

    // MARK: - Network Path Handling

    private func handlePathUpdate(_ path: NWPath) {
        let isConnected = path.status == .satisfied

        // Only process queue on transition from disconnected → connected
        // Avoid processing on every path change (e.g., WiFi → Cellular)
        if isConnected, !self.wasConnected {
            polyInfo("PolyBaseNetworkMonitor: Network connectivity restored, processing offline queue")

            // Debounce: wait 2 seconds after connectivity returns before processing
            // This avoids thrashing if connection is flaky
            Task {
                try? await Task.sleep(for: .seconds(2))

                // Double-check we're still connected after the delay
                guard self.monitor.currentPath.status == .satisfied else {
                    polyDebug("PolyBaseNetworkMonitor: Network lost again during debounce, skipping queue processing")
                    return
                }

                await self.processQueueOnReconnect()
            }
        }

        self.wasConnected = isConnected
    }

    @MainActor
    private func processQueueOnReconnect() async {
        guard PolySyncCoordinator.shared.hasPendingOfflineOperations else {
            polyDebug("PolyBaseNetworkMonitor: No pending operations to process")
            return
        }

        let processed = await PolySyncCoordinator.shared.processOfflineQueue()

        if processed > 0 {
            polyInfo("PolyBaseNetworkMonitor: Processed \(processed) offline operations after reconnect")
        }
    }
}
