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
    /// Extract string value from AnyJSON.
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Extract integer value from AnyJSON.
    var integerValue: Int? {
        if case let .integer(value) = self { return value }
        // Also handle double that might be a whole number
        if case let .double(value) = self { return Int(value) }
        return nil
    }

    /// Extract bool value from AnyJSON.
    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// Extract double value from AnyJSON.
    var doubleValue: Double? {
        if case let .double(value) = self { return value }
        if case let .integer(value) = self { return Double(value) }
        return nil
    }

    /// Extract array value from AnyJSON.
    var arrayValue: [AnyJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// Extract object value from AnyJSON.
    var objectValue: [String: AnyJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Check if this is null.
    var isNull: Bool {
        if case .null = self { return true }
        return false
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

// MARK: - ISO8601 Date Helpers

public extension Date {
    /// Format date as ISO8601 string for Supabase.
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }

    /// Parse ISO8601 string from Supabase.
    init?(iso8601String: String) {
        guard let date = ISO8601DateFormatter().date(from: iso8601String) else {
            return nil
        }
        self = date
    }
}
