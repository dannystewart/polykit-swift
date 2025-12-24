import Foundation

// MARK: - PolyDataToolbarAction

/// Describes a toolbar action in the Data Explorer.
///
/// Toolbar actions appear in the tools menu (iOS) or toolbar (macOS)
/// and can perform operations like export, import, or cleanup.
public struct PolyDataToolbarAction: Sendable {
    /// Unique identifier for this action.
    public let id: String

    /// Display title for the action.
    public let title: String

    /// SF Symbol name for the action icon.
    public let iconName: String

    /// Whether this action is destructive (shown in red).
    public let isDestructive: Bool

    /// The action to perform when triggered.
    ///
    /// The action receives a context with access to the model context,
    /// current entity, and UI helpers for showing alerts/progress.
    public let action: @Sendable (PolyDataExplorerContext) async -> Void

    // MARK: Initialization

    public init(
        id: String,
        title: String,
        iconName: String,
        isDestructive: Bool = false,
        action: @escaping @Sendable (PolyDataExplorerContext) async -> Void
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.isDestructive = isDestructive
        self.action = action
    }
}

// MARK: - PolyDataToolbarSection

/// A group of related toolbar actions.
///
/// Sections are used to visually separate groups of actions in menus.
public struct PolyDataToolbarSection: Sendable {
    /// The actions in this section.
    public let actions: [PolyDataToolbarAction]

    // MARK: Initialization

    public init(actions: [PolyDataToolbarAction]) {
        self.actions = actions
    }

    /// Creates a section with a single action.
    public init(_ action: PolyDataToolbarAction) {
        self.actions = [action]
    }
}
