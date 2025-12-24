import Foundation
import SwiftData

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

// MARK: - PolyDataExplorerContext

/// Context object passed to toolbar actions and navigation handlers.
///
/// Provides access to the model context, current state, and UI helpers
/// for performing operations in the Data Explorer.
@MainActor
public final class PolyDataExplorerContext {
    /// The SwiftData model context.
    public let modelContext: ModelContext

    /// The currently selected entity index.
    public private(set) var currentEntityIndex: Int

    /// Callback to reload the current data view.
    public var reloadData: (() -> Void)?

    /// Callback to show an alert with a title and message.
    public var showAlert: ((String, String) -> Void)?

    /// Callback to show a progress overlay with a message.
    public var showProgress: ((String) -> Void)?

    /// Callback to hide the progress overlay.
    public var hideProgress: (() -> Void)?

    /// Callback to update the progress message.
    public var updateProgress: ((String) -> Void)?

    /// Callback to switch to a different entity tab.
    public var switchToEntity: ((Int) -> Void)?

    /// Callback to apply a filter.
    public var applyFilter: ((PolyDataFilter) -> Void)?

    /// Callback to clear the current filter.
    public var clearFilter: (() -> Void)?

    /// Callback to dismiss the explorer (iOS modal).
    public var dismiss: (() -> Void)?

    // MARK: Initialization

    public init(modelContext: ModelContext, currentEntityIndex: Int = 0) {
        self.modelContext = modelContext
        self.currentEntityIndex = currentEntityIndex
    }

    // MARK: Methods

    /// Updates the current entity index.
    public func setCurrentEntityIndex(_ index: Int) {
        self.currentEntityIndex = index
    }
}

// MARK: - PolyDataFilter

/// Represents an active filter on the data explorer.
public struct PolyDataFilter: Sendable {
    /// The field being filtered.
    public let field: String

    /// The value to filter by.
    public let value: String

    /// Display text for the filter banner.
    public var displayText: String {
        "\(field) = \(value)"
    }

    // MARK: Initialization

    public init(field: String, value: String) {
        self.field = field
        self.value = value
    }
}
