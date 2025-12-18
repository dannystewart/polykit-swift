//
//  PolyBaseDebouncedNotifier.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - PolyBaseDebouncedNotifier

/// Posts notifications with debouncing to prevent UI hammering during bulk syncs.
///
/// When multiple changes arrive rapidly (e.g., during a full sync or bulk update),
/// this notifier coalesces them into a single notification after a brief delay.
///
/// ## Usage
/// ```swift
/// let notifier = PolyBaseDebouncedNotifier()
///
/// // In your realtime handler - called many times rapidly
/// func handleMessageChange() {
///     // ... process the change ...
///     notifier.post(.messagesDidChange)  // Only fires once after 300ms of quiet
/// }
/// ```
@MainActor
public final class PolyBaseDebouncedNotifier {
    /// Default debounce interval
    public static let defaultInterval: Duration = .milliseconds(300)

    private var pendingNotifications: [Notification.Name: Task<Void, Never>] = [:]
    private let debounceInterval: Duration

    /// Number of currently pending notifications.
    public var pendingCount: Int {
        pendingNotifications.count
    }

    /// Create a debounced notifier.
    ///
    /// - Parameter debounceInterval: How long to wait after the last post before firing.
    ///                               Default is 300ms.
    public init(debounceInterval: Duration = defaultInterval) {
        self.debounceInterval = debounceInterval
    }

    // MARK: - Posting

    /// Post a notification with debouncing.
    ///
    /// If the same notification is posted again before the debounce interval,
    /// the timer resets. The notification only fires after the interval passes
    /// with no new posts.
    ///
    /// - Parameters:
    ///   - name: The notification name to post
    ///   - object: Optional object to include with the notification
    ///   - userInfo: Optional user info dictionary
    public func post(
        _ name: Notification.Name,
        object: Any? = nil,
        userInfo: [AnyHashable: Any]? = nil,
    ) {
        // Cancel any pending notification with this name
        pendingNotifications[name]?.cancel()

        // Schedule a new one
        pendingNotifications[name] = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
            pendingNotifications.removeValue(forKey: name)
        }
    }

    /// Post a notification immediately, canceling any pending debounced version.
    ///
    /// Use this when you need the notification to fire right away
    /// (e.g., user-initiated actions that should feel instant).
    public func postImmediately(
        _ name: Notification.Name,
        object: Any? = nil,
        userInfo: [AnyHashable: Any]? = nil,
    ) {
        pendingNotifications[name]?.cancel()
        pendingNotifications.removeValue(forKey: name)
        NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
    }

    /// Cancel a pending notification without posting it.
    public func cancel(_ name: Notification.Name) {
        pendingNotifications[name]?.cancel()
        pendingNotifications.removeValue(forKey: name)
    }

    /// Cancel all pending notifications.
    public func cancelAll() {
        for task in pendingNotifications.values {
            task.cancel()
        }
        pendingNotifications.removeAll()
    }

    /// Check if a notification is pending (scheduled but not yet fired).
    public func isPending(_ name: Notification.Name) -> Bool {
        pendingNotifications[name] != nil
    }
}

// MARK: - Convenience Extensions

public extension PolyBaseDebouncedNotifier {
    /// Post multiple notifications, all debounced.
    func post(_ names: Notification.Name...) {
        for name in names {
            post(name)
        }
    }

    /// Post multiple notifications immediately.
    func postImmediately(_ names: Notification.Name...) {
        for name in names {
            postImmediately(name)
        }
    }
}
