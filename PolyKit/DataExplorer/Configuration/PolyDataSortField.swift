//
//  PolyDataSortField.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import SwiftData

// MARK: - PolyDataSortField

/// Describes a sortable field for an entity in the Data Explorer.
///
/// Sort fields define how records can be ordered, including the display name
/// shown in sort menus and the logic to create appropriate sort descriptors.
///
/// - Note: The `Model` generic parameter must conform to `PersistentModel`.
public struct PolyDataSortField<Model: PersistentModel>: Sendable {
    /// Unique identifier for this sort field.
    public let id: String

    /// Display name shown in sort menus.
    public let displayName: String

    /// Whether the default sort direction is ascending.
    public let defaultAscending: Bool

    /// Closure that creates a sort descriptor for the given order.
    public let makeSortDescriptor: @Sendable (SortOrder) -> SortDescriptor<Model>

    // MARK: Initialization

    /// Creates a new sort field configuration.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for this sort field.
    ///   - displayName: Display name for sort menus.
    ///   - defaultAscending: Whether ascending is the default. Default is true.
    ///   - makeSortDescriptor: Closure to create a sort descriptor.
    public init(
        id: String,
        displayName: String,
        defaultAscending: Bool = true,
        makeSortDescriptor: @escaping @Sendable (SortOrder) -> SortDescriptor<Model>,
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultAscending = defaultAscending
        self.makeSortDescriptor = makeSortDescriptor
    }
}

// MARK: - Convenience Extensions

public extension PolyDataSortField {
    /// Creates a sort field for a String keypath.
    static func string(
        id: String,
        displayName: String,
        keyPath: KeyPath<Model, String> & Sendable,
        defaultAscending: Bool = true,
    ) -> PolyDataSortField {
        PolyDataSortField(
            id: id,
            displayName: displayName,
            defaultAscending: defaultAscending,
            makeSortDescriptor: { order in
                SortDescriptor(keyPath, order: order)
            },
        )
    }

    /// Creates a sort field for an optional String keypath.
    static func optionalString(
        id: String,
        displayName: String,
        keyPath: KeyPath<Model, String?> & Sendable,
        defaultAscending: Bool = true,
    ) -> PolyDataSortField {
        PolyDataSortField(
            id: id,
            displayName: displayName,
            defaultAscending: defaultAscending,
            makeSortDescriptor: { order in
                SortDescriptor(keyPath, order: order)
            },
        )
    }

    /// Creates a sort field for a Date keypath.
    static func date(
        id: String,
        displayName: String,
        keyPath: KeyPath<Model, Date> & Sendable,
        defaultAscending: Bool = false,
    ) -> PolyDataSortField {
        PolyDataSortField(
            id: id,
            displayName: displayName,
            defaultAscending: defaultAscending,
            makeSortDescriptor: { order in
                SortDescriptor(keyPath, order: order)
            },
        )
    }

    /// Creates a sort field for an optional Date keypath.
    static func optionalDate(
        id: String,
        displayName: String,
        keyPath: KeyPath<Model, Date?> & Sendable,
        defaultAscending: Bool = false,
    ) -> PolyDataSortField {
        PolyDataSortField(
            id: id,
            displayName: displayName,
            defaultAscending: defaultAscending,
            makeSortDescriptor: { order in
                SortDescriptor(keyPath, order: order)
            },
        )
    }

    /// Creates a sort field for an Int keypath.
    static func int(
        id: String,
        displayName: String,
        keyPath: KeyPath<Model, Int> & Sendable,
        defaultAscending: Bool = true,
    ) -> PolyDataSortField {
        PolyDataSortField(
            id: id,
            displayName: displayName,
            defaultAscending: defaultAscending,
            makeSortDescriptor: { order in
                SortDescriptor(keyPath, order: order)
            },
        )
    }
}
