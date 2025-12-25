//
//  PolyBaseUtilities.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase

// MARK: - AnyJSON Extensions

/// Convenient accessors for extracting typed values from AnyJSON.
public extension AnyJSON {
    /// Check whether this value is `.null`.
    ///
    /// Note: Supabase's `AnyJSON` already provides `isNil`.
    /// We keep `isNull` as a semantic alias (and to preserve existing call sites),
    /// but we intentionally do **not** duplicate Supabase's `stringValue`/`boolValue`/etc
    /// accessors to avoid ambiguity when apps import both `Supabase` and `PolyBase`.
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Extract integer value from AnyJSON.
    var integerValue: Int? {
        if case let .integer(value) = self { return value }
        // Also handle double that might be a whole number
        if case let .double(value) = self { return Int(value) }
        return nil
    }

    /// Extract double value from AnyJSON, accepting both `.double` and `.integer`.
    ///
    /// Supabase's `AnyJSON.doubleValue` only returns a value for `.double`.
    /// This helper preserves PolyBase's historical behavior of treating integer JSON numbers as valid doubles.
    var numericDoubleValue: Double? {
        if case let .double(value) = self { return value }
        if case let .integer(value) = self { return Double(value) }
        return nil
    }
}

// MARK: - Array Chunking

public extension Array {
    /// Split array into chunks of specified size.
    ///
    /// Useful for batch operations with APIs that have limits:
    /// ```swift
    /// let batches = largeArray.chunked(into: 100)
    /// for batch in batches {
    ///     try await api.process(batch)
    /// }
    /// ```
    ///
    /// - Parameter size: Maximum size of each chunk.
    /// - Returns: Array of arrays, each with at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - PolyISO8601

/// Thread-safe ISO8601 date formatters for Supabase.
///
/// Supabase can return dates in multiple formats:
/// - With fractional seconds: `2024-12-22T10:00:00.123456Z`
/// - Without fractional seconds: `2024-12-22T10:00:00Z`
/// - With space instead of T: `2024-12-22 10:00:00Z`
public enum PolyISO8601 {
    /// Formatter with fractional seconds (most common from Supabase).
    ///
    /// - Note: `nonisolated(unsafe)` is used because `ISO8601DateFormatter` is thread-safe
    ///   for parsing/formatting after configuration, but isn't marked as `Sendable`.
    public nonisolated(unsafe) static let formatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formatter without fractional seconds (fallback).
    ///
    /// - Note: `nonisolated(unsafe)` is used because `ISO8601DateFormatter` is thread-safe
    ///   for parsing/formatting after configuration, but isn't marked as `Sendable`.
    public nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse an ISO8601 date string from Supabase, handling multiple formats.
    public static func parse(_ value: String) -> Date? {
        // Try with fractional seconds first (most common from Supabase)
        if let date = formatterWithFractional.date(from: value) { return date }

        // Try without fractional seconds
        if let date = formatter.date(from: value) { return date }

        // Try with space normalized to T
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        if let date = formatterWithFractional.date(from: normalized) { return date }
        return self.formatter.date(from: normalized)
    }

    /// Format a date as ISO8601 string for Supabase (without fractional seconds).
    public static func format(_ date: Date) -> String {
        self.formatter.string(from: date)
    }
}

public extension Date {
    /// Format date as ISO8601 string for Supabase.
    var iso8601String: String {
        PolyISO8601.format(self)
    }

    /// Parse ISO8601 string from Supabase, handling multiple formats.
    init?(iso8601String: String) {
        guard let date = PolyISO8601.parse(iso8601String) else {
            return nil
        }
        self = date
    }
}
