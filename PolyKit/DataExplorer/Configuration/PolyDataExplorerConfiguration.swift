import Foundation
import SwiftData

// MARK: - PolyDataExplorerConfiguration

/// Main configuration for the Data Explorer.
///
/// This configuration defines all entities, toolbar actions, and options
/// for a Data Explorer instance. Create one configuration and pass it to
/// the platform-specific view controller.
///
/// Example usage:
/// ```swift
/// let config = PolyDataExplorerConfiguration(
///     entities: [personaEntity.eraseToAny(), conversationEntity.eraseToAny()],
///     defaultEntityIndex: 0,
///     toolbarSections: [
///         PolyDataToolbarSection(actions: [exportAction, importAction])
///     ],
///     integrityChecker: MyIntegrityChecker(),
///     showStats: true,
///     title: "Data Explorer"
/// )
/// ```
public struct PolyDataExplorerConfiguration {
    /// The entity types available in this explorer.
    public let entities: [AnyPolyDataEntity]

    /// Index of the entity to show by default.
    public let defaultEntityIndex: Int

    /// Toolbar action sections.
    public let toolbarSections: [PolyDataToolbarSection]

    /// Optional integrity checker for data validation.
    public let integrityChecker: (any PolyDataIntegrityChecker)?

    /// Whether to show entity count statistics.
    public let showStats: Bool

    /// Title for the explorer window/view.
    public let title: String

    // MARK: Initialization

    public init(
        entities: [AnyPolyDataEntity],
        defaultEntityIndex: Int = 0,
        toolbarSections: [PolyDataToolbarSection] = [],
        integrityChecker: (any PolyDataIntegrityChecker)? = nil,
        showStats: Bool = true,
        title: String = "Data Explorer"
    ) {
        self.entities = entities
        self.defaultEntityIndex = min(defaultEntityIndex, max(0, entities.count - 1))
        self.toolbarSections = toolbarSections
        self.integrityChecker = integrityChecker
        self.showStats = showStats
        self.title = title
    }

    // MARK: Convenience

    /// Returns the entity at the specified index, or nil if out of bounds.
    public func entity(at index: Int) -> AnyPolyDataEntity? {
        guard index >= 0, index < entities.count else { return nil }
        return entities[index]
    }

    /// Finds an entity by ID.
    public func entity(withID id: String) -> AnyPolyDataEntity? {
        entities.first { $0.id == id }
    }

    /// Finds the index of an entity by ID.
    public func entityIndex(withID id: String) -> Int? {
        entities.firstIndex { $0.id == id }
    }
}

// MARK: - PolyDataExplorerStats

/// Statistics about database contents.
public struct PolyDataExplorerStats {
    /// Counts per entity ID.
    public let counts: [String: Int]

    /// Display names per entity ID.
    public let displayNames: [String: String]

    // MARK: Initialization

    public init(counts: [String: Int], displayNames: [String: String]) {
        self.counts = counts
        self.displayNames = displayNames
    }

    /// Creates stats from a configuration and model context.
    @MainActor
    public static func fetch(
        from configuration: PolyDataExplorerConfiguration,
        context: ModelContext
    ) -> PolyDataExplorerStats {
        var counts = [String: Int]()
        var names = [String: String]()

        for entity in configuration.entities {
            counts[entity.id] = entity.recordCount(context)
            names[entity.id] = entity.displayName
        }

        return PolyDataExplorerStats(counts: counts, displayNames: names)
    }

    /// Formatted stats string (e.g., "Personas: 5  •  Conversations: 12").
    public var formattedString: String {
        displayNames.keys.sorted().compactMap { id in
            guard let name = displayNames[id], let count = counts[id] else { return nil }
            return "\(name): \(count)"
        }.joined(separator: "  •  ")
    }
}
