//
//  PolyDataExplorerDataSource.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - PolyDataExplorerDataSource

/// Shared data source for the Data Explorer, managing fetch, sort, and filter logic.
///
/// This class maintains the current state of entity selection, sorting, filtering,
/// and provides methods to fetch and manipulate records.
@MainActor
public final class PolyDataExplorerDataSource {
    /// The explorer configuration.
    public let configuration: PolyDataExplorerConfiguration

    /// The SwiftData model context.
    public let modelContext: ModelContext

    /// The context object passed to actions.
    public let context: PolyDataExplorerContext

    /// Index of the currently selected entity.
    public private(set) var currentEntityIndex: Int

    /// Current filter, if any.
    public private(set) var currentFilter: PolyDataFilter?

    /// Current search text.
    public private(set) var searchText: String = ""

    /// Whether to show only records with integrity issues.
    public private(set) var showOnlyIssues: Bool = false

    /// Cached integrity report.
    public private(set) var cachedIntegrityReport: PolyDataIntegrityReport?

    /// Per-entity sort state: [entityID: (sortFieldID, ascending)]
    private var sortState: [String: (String, Bool)] = [:]

    /// The currently selected entity.
    public var currentEntity: AnyPolyDataEntity? {
        self.configuration.entity(at: self.currentEntityIndex)
    }

    /// Current sort field ID for the current entity.
    public var currentSortFieldID: String {
        guard let entity = currentEntity else { return "" }
        return self.sortState[entity.id]?.0 ?? entity.defaultSortFieldID
    }

    /// Whether current sort is ascending.
    public var currentSortAscending: Bool {
        guard let entity = currentEntity else { return true }
        if let state = sortState[entity.id] {
            return state.1
        }
        // Find default from sort field
        for i in 0 ..< entity.sortFieldCount {
            if entity.sortFieldID(i) == entity.defaultSortFieldID {
                return entity.sortFieldDefaultAscending(i)
            }
        }
        return true
    }

    // MARK: Initialization

    public init(configuration: PolyDataExplorerConfiguration, modelContext: ModelContext) {
        self.configuration = configuration
        self.modelContext = modelContext
        self.currentEntityIndex = configuration.defaultEntityIndex
        self.context = PolyDataExplorerContext(
            modelContext: modelContext,
            currentEntityIndex: configuration.defaultEntityIndex,
        )
    }

    // MARK: Entity Selection

    /// Selects an entity by index.
    public func selectEntity(at index: Int) {
        guard index >= 0, index < self.configuration.entities.count else { return }
        self.currentEntityIndex = index
        self.context.setCurrentEntityIndex(index)

        // Clear filter if it doesn't apply to the new entity
        // (This could be made smarter based on entity relationships)
        self.currentFilter = nil
        self.showOnlyIssues = false
    }

    /// Selects an entity by ID.
    public func selectEntity(withID id: String) {
        if let index = configuration.entityIndex(withID: id) {
            self.selectEntity(at: index)
        }
    }

    // MARK: Sorting

    /// Sets the sort configuration for the current entity.
    public func setSort(fieldID: String, ascending: Bool) {
        guard let entity = currentEntity else { return }
        self.sortState[entity.id] = (fieldID, ascending)
    }

    /// Toggles the sort field. If already selected, toggles direction.
    public func toggleSort(fieldID: String) {
        guard let entity = currentEntity else { return }

        if self.currentSortFieldID == fieldID {
            // Toggle direction
            self.sortState[entity.id] = (fieldID, !self.currentSortAscending)
        } else {
            // Find default ascending for this field
            var defaultAscending = true
            for i in 0 ..< entity.sortFieldCount {
                if entity.sortFieldID(i) == fieldID {
                    defaultAscending = entity.sortFieldDefaultAscending(i)
                    break
                }
            }
            self.sortState[entity.id] = (fieldID, defaultAscending)
        }
    }

    // MARK: Filtering

    /// Sets the current filter.
    public func setFilter(_ filter: PolyDataFilter?) {
        self.currentFilter = filter
        self.showOnlyIssues = false
    }

    /// Sets the search text.
    public func setSearchText(_ text: String) {
        self.searchText = text
    }

    /// Clears the current filter and issue filter.
    public func clearFilter() {
        self.currentFilter = nil
        self.showOnlyIssues = false
    }

    /// Enables or disables the "show only issues" filter.
    public func setIssueFilter(enabled: Bool) {
        self.showOnlyIssues = enabled
        if enabled {
            self.currentFilter = nil
        }
    }

    // MARK: Data Fetching

    /// Fetches records for the current entity with current sort/filter settings.
    public func fetchCurrentRecords() -> [AnyObject] {
        guard let entity = currentEntity else { return [] }

        // Fetch with search and sort
        var records = entity.fetchRecords(
            self.modelContext,
            self.searchText.isEmpty ? nil : self.searchText,
            self.currentSortFieldID,
            self.currentSortAscending,
        )

        // Apply filter if set
        if let filter = currentFilter {
            records = records.filter { entity.recordMatchesFilter($0, filter) }
        }

        // Apply issue filter if enabled
        if self.showOnlyIssues, let report = getIntegrityReport() {
            records = records.filter { record in
                let recordID = entity.recordID(record)
                return report.hasIssue(entityID: entity.id, recordID: recordID)
            }
        }

        return records
    }

    /// Fetches statistics for all entities.
    public func fetchStats() -> PolyDataExplorerStats {
        PolyDataExplorerStats.fetch(from: self.configuration, context: self.modelContext)
    }

    // MARK: Integrity

    /// Analyzes data integrity using the configured checker.
    public func analyzeDataIntegrity() -> PolyDataIntegrityReport {
        guard let checker = configuration.integrityChecker else {
            return .empty
        }

        let report = checker.analyze(context: self.modelContext)
        self.cachedIntegrityReport = report
        return report
    }

    /// Returns the cached integrity report, or analyzes if not cached.
    public func getIntegrityReport() -> PolyDataIntegrityReport? {
        if let cached = cachedIntegrityReport {
            return cached
        }
        guard self.configuration.integrityChecker != nil else {
            return nil
        }
        return self.analyzeDataIntegrity()
    }

    /// Invalidates the cached integrity report.
    public func invalidateIntegrityCache() {
        self.cachedIntegrityReport = nil
    }

    // MARK: CRUD Operations

    /// Deletes a record.
    public func deleteRecord(_ record: AnyObject) async {
        guard let entity = currentEntity else { return }
        let context = self.modelContext
        await entity.deleteRecord(record, context)
    }

    /// Saves the model context.
    public func save() {
        try? self.modelContext.save()
    }
}
