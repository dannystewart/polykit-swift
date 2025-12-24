//
//  PolyDataIntegrity.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - PolyDataIntegrityIssue

/// Represents a single data integrity issue found during analysis.
public struct PolyDataIntegrityIssue: Sendable {
    /// A type identifier for the issue (e.g., "orphaned", "duplicate").
    public let type: String

    /// Human-readable name for this issue type.
    public let displayName: String

    /// The entity type this issue belongs to (matches entity ID).
    public let entityID: String

    /// The ID of the specific record with the issue.
    public let recordID: String

    /// Detailed description of the problem.
    public let details: String

    // MARK: Initialization

    public init(
        type: String,
        displayName: String,
        entityID: String,
        recordID: String,
        details: String,
    ) {
        self.type = type
        self.displayName = displayName
        self.entityID = entityID
        self.recordID = recordID
        self.details = details
    }
}

// MARK: - PolyDataIntegrityReport

/// Report containing all data integrity issues found during analysis.
public struct PolyDataIntegrityReport: Sendable {
    // MARK: Initialization

    /// Creates an empty report with no issues.
    public static let empty: PolyDataIntegrityReport = .init(issues: [])

    /// All issues found during analysis.
    public let issues: [PolyDataIntegrityIssue]

    /// Quick lookup: Set of record IDs with issues, keyed by entity ID.
    private let issuesByEntity: [String: Set<String>]

    /// Quick lookup: Issue type by (entityID, recordID).
    private let issueTypes: [String: String]

    /// Whether any issues were found.
    public var hasIssues: Bool { !self.issues.isEmpty }

    /// Total number of issues.
    public var issueCount: Int { self.issues.count }

    /// Gets the count of issues per entity type.
    public var issueCountsByEntity: [String: Int] {
        var counts = [String: Int]()
        for issue in self.issues {
            counts[issue.entityID, default: 0] += 1
        }
        return counts
    }

    /// Gets issues grouped by type.
    public var issuesByType: [String: [PolyDataIntegrityIssue]] {
        Dictionary(grouping: self.issues, by: \.type)
    }

    public init(issues: [PolyDataIntegrityIssue]) {
        self.issues = issues

        // Build lookup dictionaries
        var byEntity = [String: Set<String>]()
        var types = [String: String]()

        for issue in issues {
            byEntity[issue.entityID, default: []].insert(issue.recordID)
            let key = "\(issue.entityID):\(issue.recordID)"
            types[key] = issue.type
        }

        self.issuesByEntity = byEntity
        self.issueTypes = types
    }

    // MARK: Lookup Methods

    /// Checks if a specific record has any integrity issues.
    ///
    /// - Parameters:
    ///   - entityID: The entity type identifier.
    ///   - recordID: The record's unique identifier.
    /// - Returns: True if the record has issues.
    public func hasIssue(entityID: String, recordID: String) -> Bool {
        self.issuesByEntity[entityID]?.contains(recordID) ?? false
    }

    /// Gets the issue type for a specific record.
    ///
    /// - Parameters:
    ///   - entityID: The entity type identifier.
    ///   - recordID: The record's unique identifier.
    /// - Returns: The issue type string, or nil if no issue.
    public func issueType(entityID: String, recordID: String) -> String? {
        let key = "\(entityID):\(recordID)"
        return self.issueTypes[key]
    }

    /// Gets all issues for a specific entity type.
    ///
    /// - Parameter entityID: The entity type identifier.
    /// - Returns: Array of issues for that entity.
    public func issues(for entityID: String) -> [PolyDataIntegrityIssue] {
        self.issues.filter { $0.entityID == entityID }
    }
}

// MARK: - PolyDataIntegrityChecker

/// Protocol for injectable integrity checking in the Data Explorer.
///
/// Conforming types analyze the database for issues like orphaned records,
/// duplicate IDs, or missing required relationships.
public protocol PolyDataIntegrityChecker: Sendable {
    /// Analyzes the database for integrity issues.
    ///
    /// - Parameter context: The model context to analyze.
    /// - Returns: A report containing all found issues.
    @MainActor
    func analyze(context: ModelContext) -> PolyDataIntegrityReport

    /// Attempts to fix the specified issues.
    ///
    /// - Parameters:
    ///   - issues: The issues to fix.
    ///   - context: The model context to modify.
    /// - Returns: The number of issues successfully fixed.
    @MainActor
    func fix(issues: [PolyDataIntegrityIssue], context: ModelContext) async -> Int
}
