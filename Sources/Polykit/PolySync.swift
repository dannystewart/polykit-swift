import Foundation

// MARK: - PolySync

/// Simple concurrency utilities for common patterns.
/// This demonstrates basic Swift concurrency concepts in a safe, understandable way.
public enum PolySync {
    /// Executes multiple tasks concurrently and waits for all to complete. This is like Python's
    /// concurrent.futures.ThreadPoolExecutor but simpler.
    ///
    /// - Parameter tasks: Array of async closures to execute concurrently.
    /// - Returns: Array of results in the same order as input tasks.
    /// - Throws: Any error thrown by the tasks.
    public static func runConcurrently<T: Sendable>(
        _ tasks: [@Sendable () async throws -> T],
    ) async throws -> [T] {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add all tasks to the group
            for task in tasks {
                group.addTask {
                    try await task()
                }
            }

            // Collect results as they complete
            var results: [T] = []
            for try await result in group {
                results.append(result)
            }

            return results
        }
    }

    /// Executes multiple tasks concurrently with a timeout. This demonstrates how to handle timeouts in
    /// concurrent operations.
    ///
    /// - Parameters:
    ///   - tasks: Array of async closures to execute concurrently.
    ///   - timeoutSeconds: Maximum time to wait for all tasks.
    /// - Returns: Array of results, or nil if timeout occurred.
    /// - Throws: Any error thrown by the tasks (except timeout).
    public static func runConcurrentlyWithTimeout<T: Sendable>(
        _ tasks: [@Sendable () async throws -> T],
        timeoutSeconds: Double,
    ) async throws -> [T]? {
        try await withThrowingTaskGroup(of: [T]?.self) { group in
            // Add the main work task
            group.addTask {
                try await runConcurrently(tasks)
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil // Timeout result
            }

            // Return the first result (either work completed or timeout)
            let result = try await group.next()!
            group.cancelAll() // Cancel any remaining tasks
            return result
        }
    }

    /// Demonstrates how to safely share data between concurrent tasks using actors. This is like a
    /// thread-safe class in Python, but the compiler enforces safety.
    public actor SafeCounter {
        private var count: Int = 0

        public init() {}

        public func increment() {
            count += 1
        }

        public func getCount() -> Int {
            count
        }

        public func reset() {
            count = 0
        }
    }

    /// Example of how to use the SafeCounter actor. This shows the key difference from Python threading - the
    /// compiler prevents race conditions.
    public static func demonstrateActor() async {
        let counter = SafeCounter()

        // These operations are automatically synchronized
        await counter.increment()
        await counter.increment()
        let count = await counter.getCount()
        Text.printColor("Counter value: \(count)", .cyan) // Will always be 2, no race conditions possible
    }
}

/// Extension to make common concurrency patterns easier to use.
public extension PolySync {
    /// Runs a task with a timeout, returning a default value if timeout occurs.
    ///
    /// - Parameters:
    ///   - timeoutSeconds: Maximum time to wait.
    ///   - defaultValue: Value to return if timeout occurs.
    ///   - task: The async task to execute.
    /// - Returns: Result of task or default value if timeout.
    static func withTimeout<T: Sendable>(
        timeoutSeconds: Double,
        defaultValue: T,
        task: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await task()
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw TimeoutError()
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is TimeoutError {
            return defaultValue
        }
    }
}

// MARK: - TimeoutError

/// Simple error type for timeouts.
private struct TimeoutError: Error {}
