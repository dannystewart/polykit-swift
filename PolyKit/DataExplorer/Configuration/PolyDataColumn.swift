//
//  PolyDataColumn.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

#if canImport(AppKit)
    import AppKit

    public typealias PolyColor = NSColor
#elseif canImport(UIKit)
    import UIKit

    public typealias PolyColor = UIColor
#endif

// MARK: - PolyDataColumn

/// Describes a column for displaying entity data in the Data Explorer.
///
/// Columns define how a specific property of a model is displayed, including
/// its title, width constraints, value extraction, and optional styling.
///
/// - Note: The `Model` generic parameter ensures type safety when extracting values.
public struct PolyDataColumn<Model> {
    /// Unique identifier for this column.
    public let id: String

    /// Display title shown in the column header.
    public let title: String

    /// Default width of the column in points.
    public let width: CGFloat

    /// Minimum allowed width when resizing.
    public let minWidth: CGFloat

    /// Maximum allowed width when resizing.
    public let maxWidth: CGFloat

    /// Whether this column can be used for sorting.
    public let isSortable: Bool

    /// Closure that extracts the display value from a model instance.
    public let getValue: (Model) -> String

    /// Optional closure that determines the text color for a cell.
    ///
    /// - Parameters:
    ///   - model: The model instance being displayed.
    ///   - report: Optional integrity report for highlighting issues.
    /// - Returns: The color to use, or nil to use the default label color.
    public let getTextColor: ((Model, PolyDataIntegrityReport?) -> PolyColor?)?

    /// Optional closure that returns a badge to display on iOS (where space is limited).
    ///
    /// Badges provide quick visual indicators for status fields. This is particularly
    /// useful on iOS where showing all columns isn't practical. Return nil to show no badge.
    ///
    /// Example:
    /// ```swift
    /// getBadge: { message, _ in
    ///     message.deleted ? PolyDataBadge(text: "Deleted", color: .systemRed) : nil
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - model: The model instance being displayed.
    ///   - report: Optional integrity report for context.
    /// - Returns: A badge to display, or nil for no badge.
    public let getBadge: ((Model, PolyDataIntegrityReport?) -> PolyDataBadge?)?

    // MARK: Initialization

    /// Creates a new column configuration.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for this column.
    ///   - title: Display title for the column header.
    ///   - width: Default width in points. Default is 100.
    ///   - minWidth: Minimum width. Default is 40.
    ///   - maxWidth: Maximum width. Default is 500.
    ///   - isSortable: Whether sorting by this column is allowed. Default is true.
    ///   - getValue: Closure to extract the display value from a model.
    ///   - getTextColor: Optional closure for custom text coloring.
    ///   - getBadge: Optional closure for badge display on iOS. Default is nil.
    public init(
        id: String,
        title: String,
        width: CGFloat = 100,
        minWidth: CGFloat = 40,
        maxWidth: CGFloat = 500,
        isSortable: Bool = true,
        getValue: @escaping (Model) -> String,
        getTextColor: ((Model, PolyDataIntegrityReport?) -> PolyColor?)? = nil,
        getBadge: ((Model, PolyDataIntegrityReport?) -> PolyDataBadge?)? = nil,
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.isSortable = isSortable
        self.getValue = getValue
        self.getTextColor = getTextColor
        self.getBadge = getBadge
    }
}
