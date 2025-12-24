import Foundation

// MARK: - PolyDataField

/// Describes a field for the detail view in the Data Explorer.
///
/// Fields represent individual properties that can be viewed and optionally edited
/// in the detail panel when a record is selected.
public struct PolyDataField {
    /// Display label for the field.
    public let label: String

    /// Closure to extract the display value from the record.
    public let getValue: (AnyObject) -> String

    /// Whether this field can be edited.
    public let isEditable: Bool

    /// Whether this field is displayed as a toggle switch.
    public let isToggle: Bool

    /// Whether this field uses a multiline text view for editing.
    public let isMultiline: Bool

    /// Action to perform when the field value is edited (for text fields).
    public let editAction: ((AnyObject, String) -> Void)?

    /// Action to perform when a toggle is changed.
    public let toggleAction: ((AnyObject, Bool) -> Void)?

    /// Optional getter for toggle initial value (only for toggle fields).
    public let getToggleValue: ((AnyObject) -> Bool)?

    // MARK: Initialization

    /// Creates a read-only field.
    public static func readOnly(
        label: String,
        getValue: @escaping (AnyObject) -> String
    ) -> PolyDataField {
        PolyDataField(
            label: label,
            getValue: getValue,
            isEditable: false,
            isToggle: false,
            isMultiline: false,
            editAction: nil,
            toggleAction: nil,
            getToggleValue: nil
        )
    }

    /// Creates an editable text field.
    public static func editable(
        label: String,
        getValue: @escaping (AnyObject) -> String,
        isMultiline: Bool = false,
        editAction: @escaping (AnyObject, String) -> Void
    ) -> PolyDataField {
        PolyDataField(
            label: label,
            getValue: getValue,
            isEditable: true,
            isToggle: false,
            isMultiline: isMultiline,
            editAction: editAction,
            toggleAction: nil,
            getToggleValue: nil
        )
    }

    /// Creates a toggle field.
    public static func toggle(
        label: String,
        getValue: @escaping (AnyObject) -> Bool,
        toggleAction: @escaping (AnyObject, Bool) -> Void
    ) -> PolyDataField {
        PolyDataField(
            label: label,
            getValue: { _ in "" },
            isEditable: false,
            isToggle: true,
            isMultiline: false,
            editAction: nil,
            toggleAction: toggleAction,
            getToggleValue: getValue
        )
    }

    /// Full memberwise initializer.
    public init(
        label: String,
        getValue: @escaping (AnyObject) -> String,
        isEditable: Bool,
        isToggle: Bool,
        isMultiline: Bool,
        editAction: ((AnyObject, String) -> Void)?,
        toggleAction: ((AnyObject, Bool) -> Void)?,
        getToggleValue: ((AnyObject) -> Bool)?
    ) {
        self.label = label
        self.getValue = getValue
        self.isEditable = isEditable
        self.isToggle = isToggle
        self.isMultiline = isMultiline
        self.editAction = editAction
        self.toggleAction = toggleAction
        self.getToggleValue = getToggleValue
    }
}

// MARK: - PolyDataRelationship

/// Describes a relationship link in the detail view.
///
/// Relationships allow navigation between related entities,
/// such as viewing all messages in a conversation.
public struct PolyDataRelationship {
    /// Display label for the relationship.
    public let label: String

    /// Closure to get the display value (e.g., count or name).
    public let getValue: (AnyObject) -> String

    /// Action to navigate to related records.
    public let navigateAction: (AnyObject, PolyDataExplorerContext) -> Void

    // MARK: Initialization

    public init(
        label: String,
        getValue: @escaping (AnyObject) -> String,
        navigateAction: @escaping (AnyObject, PolyDataExplorerContext) -> Void
    ) {
        self.label = label
        self.getValue = getValue
        self.navigateAction = navigateAction
    }
}
