# PolyDataExplorer

A portable, configuration-driven SwiftData debugging tool for iOS and macOS.

## Overview

PolyDataExplorer provides a complete database inspection and debugging UI that can be dropped into any SwiftData project. Rather than hardcoding entity types, it uses a configuration-based approach where you define your entities, columns, and actions declaratively.

## Quick Start

### 1. Define Your Entities

```swift
import PolyKit
import SwiftData

let userEntity = PolyDataEntity<User>(
    id: "users",
    displayName: "Users",
    pluralName: "Users",
    iconName: "person.fill",

    columns: [
        PolyDataColumn(id: "name", title: "Name", width: 200) { user in
            user.name
        },
        PolyDataColumn(id: "email", title: "Email", width: 250) { user in
            user.email
        }
    ],

    sortFields: [
        .string(id: "name", displayName: "Name", keyPath: \.name),
        .date(id: "created", displayName: "Created", keyPath: \.createdAt)
    ],

    fetch: { context, searchText, sortDescriptors in
        var descriptor = FetchDescriptor<User>(sortBy: sortDescriptors)
        if let search = searchText, !search.isEmpty {
            descriptor.predicate = #Predicate { $0.name.localizedStandardContains(search) }
        }
        return (try? context.fetch(descriptor)) ?? []
    },

    searchMatches: { user, searchText in
        user.name.localizedCaseInsensitiveContains(searchText)
    },

    delete: { user, context in
        context.delete(user)
        try? context.save()
    },

    detailFields: [
        PolyDataField(label: "Name") { user in user.name },
        PolyDataField(label: "Email") { user in user.email }
    ]
)
```

### 2. Create Configuration

```swift
let configuration = PolyDataExplorerConfiguration(
    entities: [
        AnyPolyDataEntity(userEntity),
        AnyPolyDataEntity(postEntity)
    ]
)
```

### 3. Launch the Explorer

**macOS:**

```swift
let windowController = macOSPolyDataExplorerWindowController(
    configuration: configuration,
    modelContext: AppModelContainer.shared.mainContext
)
windowController.showWindow()
```

**iOS:**

```swift
let viewController = iOSPolyDataExplorerViewController(
    configuration: configuration,
    modelContext: AppModelContainer.shared.mainContext
)
present(viewController, animated: true)
```

## Configuration Types

### PolyDataEntity<Model>

Defines how a SwiftData model appears in the explorer.

| Property | Type | Description |
| -------- | ---- | ----------- |
| `id` | `String` | Unique identifier for this entity |
| `displayName` | `String` | Singular display name |
| `pluralName` | `String` | Plural display name (for counts) |
| `iconName` | `String` | SF Symbol name |
| `columns` | `[PolyDataColumn]` | Table columns |
| `sortFields` | `[PolyDataSortField<Model>]` | Available sort options |
| `fetch` | Closure | Fetch records from context |
| `searchMatches` | Closure | Filter records by search text |
| `delete` | `@MainActor` Closure | Delete a record |
| `detailFields` | `[PolyDataField]` | Fields shown in detail view |
| `detailRelationships` | `[PolyDataRelationship]` | Navigable relationships |
| `recordID` | Closure | Extract ID from record |
| `integrityLabel` | Closure | Label for integrity warnings |

### PolyDataColumn

Defines a table column.

```swift
PolyDataColumn(
    id: "status",
    title: "Status",
    width: 100,
    getValue: { record in record.status.displayName },
    getTextColor: { record in record.isActive ? .green : .gray },
    getBadge: { record in record.isActive ? nil : PolyDataBadge(text: "Inactive", color: .systemRed) }
)
```

#### Badge Support (iOS)

Columns can define badges that appear on iOS where horizontal space is limited. Badges provide quick visual indicators for status fields:

```swift
PolyDataColumn(
    id: "deleted",
    title: "Del",
    width: 40,
    getValue: { $0.deleted ? "Yes" : "No" },
    getTextColor: { message, _ in message.deleted ? .systemRed : nil },
    getBadge: { message, _ in
        message.deleted ? PolyDataBadge(text: "Deleted", color: .systemRed) : nil
    }
)
```

**Badge Design Guidelines:**

- **Keep text short**: 1-2 words maximum (e.g., "Deleted", "Archived", "Unread")
- **Only show when true**: Return `nil` when the condition is false
- **Use consistent colors**:
  - `.systemRed` for deleted/critical
  - `.systemOrange` for ignored/archived/warnings
  - `.systemBlue` for unread/default/info
  - `.systemPurple` for test/placeholder/custom
  - `.systemTeal` for dynamic/companion/active
- **Don't badge everything**: Only important status indicators

The iOS cell automatically collects and displays all badges from columns that define them.

### PolyDataSortField<Model>

Defines a sortable field with convenience builders:

```swift
// String fields
.string(id: "name", displayName: "Name", keyPath: \.name)

// Optional strings
.optionalString(id: "nickname", displayName: "Nickname", keyPath: \.nickname)

// Dates
.date(id: "created", displayName: "Created", keyPath: \.createdAt)

// Optional dates
.optionalDate(id: "modified", displayName: "Modified", keyPath: \.modifiedAt)

// Integers
.int(id: "count", displayName: "Count", keyPath: \.itemCount)
```

### PolyDataField

Defines a field in the detail view:

```swift
// Read-only field
PolyDataField(label: "ID") { record in record.id }

// Editable field
PolyDataField(
    label: "Name",
    getValue: { record in record.name },
    isEditable: true,
    onEdit: { record, newValue in
        record.name = newValue
        try? record.modelContext?.save()
    }
)

// Toggle field
PolyDataField(
    label: "Active",
    getValue: { record in record.isActive ? "Yes" : "No" },
    isToggleable: true,
    onToggle: { record in
        record.isActive.toggle()
        try? record.modelContext?.save()
    }
)
```

### PolyDataRelationship

Enables navigation to related records:

```swift
PolyDataRelationship(
    label: "Author",
    targetEntityID: "users",
    getValue: { post in post.author?.name ?? "None" },
    getTargetID: { post in post.author?.id }
)
```

## Toolbar Actions

Add custom actions to the toolbar:

```swift
let configuration = PolyDataExplorerConfiguration(
    modelContext: context,
    entities: [...],
    toolbarSections: [
        PolyDataToolbarSection(
            title: "Tools",
            iconName: "wrench",
            actions: [
                PolyDataToolbarAction(
                    title: "Export Database",
                    iconName: "square.and.arrow.up"
                ) { context in
                    await exportDatabase()
                },
                PolyDataToolbarAction(
                    title: "Clear Cache",
                    iconName: "trash"
                ) { context in
                    await clearCache()
                    context.reloadData()
                }
            ]
        )
    ]
)
```

### PolyDataExplorerContext

The context passed to toolbar actions:

| Method | Description |
| ------ | ----------- |
| `reloadData()` | Refresh the table view |
| `showAlert(title:message:)` | Show an alert dialog |
| `showProgress(message:)` | Show a progress indicator |
| `hideProgress()` | Hide the progress indicator |
| `switchToEntity(id:)` | Switch to a different entity type |

## Integrity Checking

Implement `PolyDataIntegrityChecker` to highlight problematic records:

```swift
struct MyIntegrityChecker: PolyDataIntegrityChecker {
    @MainActor
    func analyze(context: ModelContext) -> PolyDataIntegrityReport {
        var issues: [PolyDataIntegrityIssue] = []

        // Find orphaned posts (no author)
        let posts = (try? context.fetch(FetchDescriptor<Post>())) ?? []
        for post in posts where post.author == nil {
            issues.append(PolyDataIntegrityIssue(
                type: "orphaned",
                displayName: "Orphaned Record",
                entityID: "posts",
                recordID: post.id,
                details: "Post has no author"
            ))
        }

        return PolyDataIntegrityReport(issues: issues)
    }

    @MainActor
    func fix(issues: [PolyDataIntegrityIssue], context: ModelContext) async -> Int {
        var fixed = 0
        for issue in issues {
            // Handle each issue type
            if issue.type == "orphaned" {
                // Delete or reassign orphaned records
                fixed += 1
            }
        }
        return fixed
    }
}

let configuration = PolyDataExplorerConfiguration(
    modelContext: context,
    entities: [...],
    integrityChecker: MyIntegrityChecker()
)
```

Records with integrity issues display a warning badge in the table.

## Badges (iOS)

Badges provide visual status indicators on iOS where horizontal space is limited. Unlike macOS which shows all columns, iOS uses the first 3 columns for title/subtitle/detail and displays status information as colored badges.

### Basic Usage

Add the `getBadge` parameter to any column definition:

```swift
PolyDataColumn(
    id: "ignored",
    title: "Ign",
    width: 40,
    getValue: { $0.ignored ? "Yes" : "No" },
    getTextColor: { message, _ in message.ignored ? .systemOrange : nil },
    getBadge: { message, _ in
        message.ignored ? PolyDataBadge(text: "Ignored", color: .systemOrange) : nil
    }
)
```

The cell automatically collects badges from all columns and displays them on the right side of the row.

### Complete Example

```swift
// Messages with multiple status badges
private static var messageColumns: [PolyDataColumn<Message>] {
    [
        // First 3 columns used for cell title/subtitle/detail
        PolyDataColumn(id: "id", title: "ID", width: 205, getValue: { $0.id }),
        PolyDataColumn(
            id: "role",
            title: "Role",
            width: 70,
            getValue: { $0.role },
            getTextColor: { message, _ in
                switch message.role {
                case "user": .systemGreen
                case "assistant": .systemBlue
                default: nil
                }
            }
        ),
        PolyDataColumn(
            id: "content",
            title: "Content",
            width: 250,
            getValue: { $0.content.prefix(100) }
        ),

        // Status columns with badges (columns 3+ show as badges on iOS)
        PolyDataColumn(
            id: "deleted",
            title: "Del",
            width: 40,
            getValue: { $0.deleted ? "Yes" : "No" },
            getTextColor: { msg, _ in msg.deleted ? .systemRed : nil },
            getBadge: { msg, _ in
                msg.deleted ? PolyDataBadge(text: "Deleted", color: .systemRed) : nil
            }
        ),
        PolyDataColumn(
            id: "ignored",
            title: "Ign",
            width: 40,
            getValue: { $0.ignored ? "Yes" : "No" },
            getTextColor: { msg, _ in msg.ignored ? .systemOrange : nil },
            getBadge: { msg, _ in
                msg.ignored ? PolyDataBadge(text: "Ignored", color: .systemOrange) : nil
            }
        ),
        PolyDataColumn(
            id: "isRead",
            title: "Read",
            width: 40,
            getValue: { $0.isRead ? "Yes" : "No" },
            getBadge: { msg, _ in
                msg.isRead ? nil : PolyDataBadge(text: "Unread", color: .systemBlue)
            }
        ),
    ]
}
```

### Badge vs Text Color

Both `getTextColor` and `getBadge` can be used together:

- **`getTextColor`**: Colors the column text on both macOS and iOS
- **`getBadge`**: Shows a colored badge on iOS only (where columns 3+ aren't visible)

On macOS, all columns are visible in the table. On iOS, only the first 3 columns are used for the cell layout, so badges provide visibility for status fields.

### Color Consistency

Use consistent colors across your entities for better visual scanning:

| Color | Use Case | Example |
| ----- | -------- | ------- |
| `.systemRed` | Deleted, Critical | `PolyDataBadge(text: "Deleted", color: .systemRed)` |
| `.systemOrange` | Ignored, Archived, Warnings | `PolyDataBadge(text: "Archived", color: .systemOrange)` |
| `.systemBlue` | Unread, Default, Info | `PolyDataBadge(text: "Unread", color: .systemBlue)` |
| `.systemPurple` | Test, Placeholder, Custom | `PolyDataBadge(text: "Test", color: .systemPurple)` |
| `.systemTeal` | Dynamic, Companion, Active | `PolyDataBadge(text: "Dynamic", color: .systemTeal)` |
| `.systemGreen` | Success, Verified | `PolyDataBadge(text: "Verified", color: .systemGreen)` |

### Conditional Logic

Return `nil` when the badge shouldn't be shown:

```swift
getBadge: { message, _ in
    // Only show badge when deleted is TRUE
    message.deleted ? PolyDataBadge(text: "Deleted", color: .systemRed) : nil
}
```

Or combine multiple conditions:

```swift
getBadge: { message, _ in
    if message.deleted {
        return PolyDataBadge(text: "Deleted", color: .systemRed)
    } else if message.ignored {
        return PolyDataBadge(text: "Ignored", color: .systemOrange)
    }
    return nil
}
```

### Using Integrity Report

The `report` parameter can be used to show different badges based on data integrity:

```swift
getBadge: { conversation, report in
    if let report, report.hasIssue(entityID: "conversations", recordID: conversation.id) {
        return PolyDataBadge(text: "⚠️ Issue", color: .systemRed)
    }
    return conversation.archived ? PolyDataBadge(text: "Archived", color: .systemOrange) : nil
}
```

**Note**: Integrity issues are automatically shown as badges by the cell. This example is for when you want custom badge text based on integrity state.

### Display Behavior

- **Automatic Collection**: The iOS cell iterates through all columns and collects badges
- **Multiple Badges**: A row can show multiple badges if multiple columns define them
- **Overflow Handling**: Badge stack uses horizontal layout with wrapping if needed
- **Integrity Issues**: Shown in addition to status badges (not replacing them)

## Configuration Options

```swift
PolyDataExplorerConfiguration(
    modelContext: context,
    entities: [...],
    toolbarSections: [...],
    integrityChecker: MyIntegrityChecker(),
    showStats: true,              // Show record counts in toolbar
    windowTitle: "Data Explorer"  // macOS window title
)
```

## Platform-Specific Notes

### macOS

- Window controller manages the toolbar and split view
- Toolbar uses icon-only mode by default
- Detail panel appears in the right split
- Supports keyboard shortcuts for refresh

### iOS

- Uses `UISegmentedControl` for entity switching
- Detail view is pushed onto navigation stack
- Supports swipe-to-delete
- Tools appear in a `UIMenu` on the navigation bar

## Type Safety

The configuration uses generics and type erasure:

1. `PolyDataEntity<Model>` is generic over your SwiftData model
2. `AnyPolyDataEntity` wraps entities for heterogeneous storage
3. Closures maintain type safety within each entity definition

### Sendable Conformance

All configuration types are `Sendable`. When using KeyPaths in sort fields, they're constrained to `& Sendable`:

```swift
.string(id: "name", displayName: "Name", keyPath: \.name)
// The keyPath parameter is: KeyPath<Model, String> & Sendable
```

### MainActor Isolation

Delete closures are marked `@MainActor` since they modify `ModelContext`:

```swift
delete: { user, context in  // This runs on MainActor
    context.delete(user)
    try? context.save()
}
```

## Example: Complete Integration

```swift
// MyAppDataExplorer.swift

import PolyKit
import SwiftData

enum MyAppDataExplorer {

    static func configuration() -> PolyDataExplorerConfiguration {
        PolyDataExplorerConfiguration(
            modelContext: AppContainer.shared.mainContext,
            entities: [
                AnyPolyDataEntity(Self.userEntity),
                AnyPolyDataEntity(Self.postEntity),
                AnyPolyDataEntity(Self.commentEntity)
            ],
            toolbarSections: [
                Self.toolsSection
            ],
            integrityChecker: MyIntegrityChecker(),
            showStats: true,
            windowTitle: "Database Explorer"
        )
    }

    #if os(macOS)
    static func show() {
        let windowController = macOSPolyDataExplorerWindowController(
            configuration: configuration()
        )
        windowController.showWindow(nil)
        windowController.window?.center()
    }
    #endif

    #if os(iOS)
    static func makeViewController(modelContext: ModelContext) -> UIViewController {
        let vc = iOSPolyDataExplorerViewController(
            configuration: configuration(),
            modelContext: modelContext
        )
        return vc
    }
    #endif

    // MARK: - Entity Definitions

    private static var userEntity: PolyDataEntity<User> {
        PolyDataEntity(
            id: "users",
            displayName: "User",
            pluralName: "Users",
            iconName: "person.fill",
            columns: [...],
            sortFields: [...],
            fetch: { ... },
            searchMatches: { ... },
            delete: { ... },
            detailFields: [...]
        )
    }

    // ... more entities

    // MARK: - Toolbar

    private static var toolsSection: PolyDataToolbarSection {
        PolyDataToolbarSection(
            title: "Tools",
            iconName: "wrench",
            actions: [
                PolyDataToolbarAction(title: "Export", iconName: "square.and.arrow.up") { ctx in
                    // Export logic
                },
                PolyDataToolbarAction(title: "Reset", iconName: "arrow.counterclockwise") { ctx in
                    // Reset logic
                    ctx.reloadData()
                }
            ]
        )
    }
}
```

## File Structure

```text
PolyKit/DataExplorer/
├── Configuration/
│   ├── PolyDataBadge.swift
│   ├── PolyDataColumn.swift
│   ├── PolyDataSortField.swift
│   ├── PolyDataField.swift
│   ├── PolyDataRelationship.swift
│   ├── PolyDataIntegrity.swift
│   ├── PolyDataToolbarAction.swift
│   ├── PolyDataEntity.swift
│   ├── AnyPolyDataEntity.swift
│   └── PolyDataExplorerConfiguration.swift
├── Core/
│   ├── PolyDataExplorerContext.swift
│   └── PolyDataExplorerDataSource.swift
├── iOS/
│   ├── iOSPolyDataExplorerViewController.swift
│   ├── iOSPolyDataExplorerDetailController.swift
│   └── iOSPolyDataExplorerCell.swift
└── macOS/
    ├── macOSPolyDataExplorerWindowController.swift
    ├── macOSPolyDataExplorerSplitViewController.swift
    ├── macOSPolyDataExplorerViewController.swift
    └── macOSPolyDataExplorerDetailPanel.swift
```
