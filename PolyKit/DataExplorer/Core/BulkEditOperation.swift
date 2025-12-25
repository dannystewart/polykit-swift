//
//  BulkEditOperation.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

// MARK: - BulkEditOperation

/// Describes a bulk edit operation: "Set field X to value Y where field Z equals value W".
public struct BulkEditOperation: Sendable {
    /// The entity to operate on.
    public let entityID: String

    /// The field to update (e.g., "persona_id").
    public let targetField: PolyDataField

    /// The new value to set.
    public let newValue: String

    /// The field to filter by (e.g., "conversation_id").
    public let whereField: PolyDataField

    /// The value to match in the where clause.
    public let whereValue: String

    /// Whether to increment the version field after updating.
    public let incrementVersion: Bool

    // MARK: Initialization

    public init(
        entityID: String,
        targetField: PolyDataField,
        newValue: String,
        whereField: PolyDataField,
        whereValue: String,
        incrementVersion: Bool,
    ) {
        self.entityID = entityID
        self.targetField = targetField
        self.newValue = newValue
        self.whereField = whereField
        self.whereValue = whereValue
        self.incrementVersion = incrementVersion
    }
}

// MARK: - BulkEditPreview

/// Represents a preview of records that will be affected by a bulk edit operation.
public struct BulkEditPreview: @unchecked Sendable {
    /// The records that match the filter.
    public let matchingRecords: [BulkEditPreviewRecord]

    /// Whether there were more matches than shown.
    public let hasMore: Bool

    /// Total count of matching records.
    public var totalCount: Int { self.matchingRecords.count }

    // MARK: Initialization

    public init(matchingRecords: [BulkEditPreviewRecord], hasMore: Bool) {
        self.matchingRecords = matchingRecords
        self.hasMore = hasMore
    }
}

// MARK: - BulkEditPreviewRecord

/// A single record in the bulk edit preview showing before/after values.
public struct BulkEditPreviewRecord: Identifiable {
    /// Unique identifier for this preview record.
    public let id: String

    /// Display name or identifier for the record (e.g., conversation name, message preview).
    public let displayName: String

    /// Current value of the target field.
    public let currentValue: String

    /// What the value will become after the edit.
    public let newValue: String

    /// The underlying record object (for execution).
    /// Note: Not Sendable, but safe because we only use it on @MainActor.
    public nonisolated(unsafe) let record: AnyObject

    // MARK: Initialization

    public init(
        id: String,
        displayName: String,
        currentValue: String,
        newValue: String,
        record: AnyObject,
    ) {
        self.id = id
        self.displayName = displayName
        self.currentValue = currentValue
        self.newValue = newValue
        self.record = record
    }
}

// MARK: - BulkEditResult

/// Result of executing a bulk edit operation.
public struct BulkEditResult: Sendable {
    /// Number of records successfully updated.
    public let updatedCount: Int

    /// Optional error message if the operation failed.
    public let error: String?

    /// Whether the operation succeeded.
    public var isSuccess: Bool { self.error == nil }

    // MARK: Initialization

    public init(updatedCount: Int, error: String? = nil) {
        self.updatedCount = updatedCount
        self.error = error
    }
}
