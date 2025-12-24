//
//  PolyDataBadge.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

// MARK: - PolyDataBadge

/// Visual badge that can be displayed on data rows (iOS only, for space efficiency).
///
/// Badges provide quick visual indicators for status fields like "Deleted", "Archived",
/// "Unread", etc. On iOS where horizontal space is limited, badges are more effective
/// than showing every column.
///
/// Example:
/// ```swift
/// let badge = PolyDataBadge(
///     text: "Archived",
///     color: .systemOrange
/// )
/// ```
public struct PolyDataBadge: Sendable {
    /// The text to display in the badge.
    public let text: String

    /// The color for the badge (used for both text and background tint).
    public let color: PolyColor

    // MARK: Initialization

    /// Creates a badge with the given text and color.
    ///
    /// - Parameters:
    ///   - text: The text to display. Keep it short (e.g., "Deleted", "Archived").
    ///   - color: The color to use for the badge.
    public init(text: String, color: PolyColor) {
        self.text = text
        self.color = color
    }
}
