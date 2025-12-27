# PolyRefresh

A universal UI refresh coordination framework for SwiftUI and AppKit/UIKit applications.

## The Problem

Every app with real-time data faces the same challenge: when data changes (user edits, sync updates, background tasks), UI components need to refresh. The naive approach leads to:

- **Random UI bugs**: "This list didn't update when I deleted an item"
- **Scattered notification code**: `NotificationCenter.post()` everywhere
- **Performance issues**: Refreshing everything when one thing changes
- **Maintenance nightmares**: Adding new entity types means updating dozens of files

**PolyRefresh solves this once and for all.**

## The Solution

PolyRefresh provides:

1. **Observable signals** - Use Swift's `@Observable` for efficient change tracking
2. **Typed change details** - Know what changed (insert/update/delete) and which entities
3. **Hierarchical bubbling** - Child changes automatically cascade to parents
4. **Zero boilerplate** - Register entity types once at startup, then forget about it

## Quick Start

### 1. Register Your Entity Types

At app startup, register your entity types with optional parent relationships:

```swift
// In your app's initialization (e.g., AppDelegate.didFinishLaunching)
@MainActor
func configurePolyRefresh() {
    let coordinator = PolyRefreshCoordinator.shared

    // Simple entity with no parent
    coordinator.register("Task")

    // Hierarchical entities (child → parent)
    coordinator.register("Project")
    coordinator.register("Task", parent: "Project")
    coordinator.register("Comment", parent: "Task")
}
```

**Hierarchy rules:**

- When `Comment` changes → `Task` signal fires → `Project` signal fires
- This keeps list views, detail views, and summary views all in sync automatically

### 2. Notify When Data Changes

From your data coordinator, sync service, or anywhere data mutates:

```swift
// Single entity changed
PolyRefreshCoordinator.shared.notify(
    "Task",
    change: EntityChange(
        changeType: .update,
        entityID: task.id,
        parentID: task.projectID
    )
)

// Batch changes
PolyRefreshCoordinator.shared.notify(
    "Task",
    change: EntityChange(
        changeType: .insert,
        entityIDs: Set(newTasks.map(\.id)),
        parentID: projectID
    )
)

// No details available (e.g., after bulk sync)
PolyRefreshCoordinator.shared.notify("Project")

// Everything changed (sign-in, full resync, etc.)
PolyRefreshCoordinator.shared.notifyAll()
```

### 3. Observe in UI Components

In your view controllers or views, observe the signals:

```swift
class TaskListViewController: UIViewController {
    private var lastTaskSignal = 0
    private var lastProjectSignal = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        observeRefreshSignals()
    }

    private func observeRefreshSignals() {
        withObservationTracking {
            // Access the signals you care about
            _ = PolyRefreshCoordinator.shared.signal(for: "Task")
            _ = PolyRefreshCoordinator.shared.signal(for: "Project")
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleDataChanged()
                self?.observeRefreshSignals() // Re-subscribe
            }
        }
    }

    @MainActor
    private func handleDataChanged() {
        let coordinator = PolyRefreshCoordinator.shared

        // Check what actually changed
        let taskChanged = coordinator.signal(for: "Task") != lastTaskSignal
        let projectChanged = coordinator.signal(for: "Project") != lastProjectSignal

        // Update tracked values
        lastTaskSignal = coordinator.signal(for: "Task")
        lastProjectSignal = coordinator.signal(for: "Project")

        // Reload only what changed
        if taskChanged {
            reloadTasks()
        }
        if projectChanged {
            reloadProjectMetadata()
        }
    }
}
```

## Architecture Patterns

### Pattern 1: App-Specific Wrapper (Recommended)

Create a thin wrapper that provides type-safe, app-specific access:

```swift
// In your app's codebase
@MainActor
enum AppRefreshCoordinator {
    // MARK: - Configuration

    static func configure() {
        let coordinator = PolyRefreshCoordinator.shared
        coordinator.register("User")
        coordinator.register("Project", parent: "User")
        coordinator.register("Task", parent: "Project")
        coordinator.register("Tag")
    }

    // MARK: - Signal Accessors

    static var userSignal: Int {
        PolyRefreshCoordinator.shared.signal(for: "User")
    }

    static var projectSignal: Int {
        PolyRefreshCoordinator.shared.signal(for: "Project")
    }

    static var taskSignal: Int {
        PolyRefreshCoordinator.shared.signal(for: "Task")
    }

    static var tagSignal: Int {
        PolyRefreshCoordinator.shared.signal(for: "Tag")
    }

    // MARK: - Change Detail Accessors

    static var lastTaskChange: EntityChange? {
        PolyRefreshCoordinator.shared.lastChange(for: "Task")
    }

    // ... repeat for other entities

    // MARK: - Notify Methods

    static func notifyTasksChanged(_ change: EntityChange) {
        PolyRefreshCoordinator.shared.notify("Task", change: change)
    }

    static func notifyProjectsChanged(_ change: EntityChange) {
        PolyRefreshCoordinator.shared.notify("Project", change: change)
    }

    // ... repeat for other entities
}
```

**Benefits:**

- Type-safe access throughout your app
- Autocomplete-friendly
- Easy refactoring (rename entity types in one place)
- Matches existing code patterns (like `DataCoordinator.shared`)

**Usage:**

```swift
// Clean, app-specific API
AppRefreshCoordinator.notifyTasksChanged(change)

// In views
_ = AppRefreshCoordinator.taskSignal
```

### Pattern 2: Direct Access

For smaller apps or rapid prototyping, use PolyRefresh directly:

```swift
// Configure at startup
PolyRefreshCoordinator.shared.register("Task")
PolyRefreshCoordinator.shared.register("Project", parent: "Task")

// Notify
PolyRefreshCoordinator.shared.notify("Task", change: change)

// Observe
_ = PolyRefreshCoordinator.shared.signal(for: "Task")
```

## Change Details

`EntityChange` provides context about what changed:

```swift
public struct EntityChange: Sendable {
    public enum ChangeType: Sendable {
        case insert
        case update
        case delete
    }

    public let changeType: ChangeType
    public let entityIDs: Set<String>
    public let parentID: String?
}
```

**Use cases:**

```swift
// Check change type
if let change = PolyRefreshCoordinator.shared.lastChange(for: "Task") {
    switch change.changeType {
    case .insert:
        scrollToBottom()
    case .delete:
        updateEmptyState()
    case .update:
        // Just reload
    }
}

// Filter by affected entities
if let change = coordinator.lastChange(for: "Task"),
   change.entityIDs.contains(currentTaskID) {
    reloadCurrentTask()
}

// Check parent relationship
if let change = coordinator.lastChange(for: "Task"),
   change.parentID == currentProjectID {
    reloadProject()
}
```

## Integration with Data Coordinators

PolyRefresh works perfectly with centralized data coordinators:

```swift
@MainActor
final class DataCoordinator {
    static let shared = DataCoordinator()

    private var modelContext: ModelContext!

    func initialize(with context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Persistence

    func persistChange(_ task: Task) async throws {
        // 1. Increment version
        task.version += 1
        task.updatedAt = Date()

        // 2. Save to SwiftData
        try modelContext.save()

        // 3. Queue for remote sync (e.g., Supabase)
        try await syncService.push(task)

        // 4. Notify UI
        AppRefreshCoordinator.notifyTasksChanged(
            EntityChange(
                changeType: .update,
                entityID: task.id,
                parentID: task.projectID
            )
        )
    }

    func delete(_ task: Task) async throws {
        let taskID = task.id
        let projectID = task.projectID

        // Soft-delete
        task.deleted = true
        task.version += 1
        try modelContext.save()

        try await syncService.push(task)

        // Notify with delete type
        AppRefreshCoordinator.notifyTasksChanged(
            EntityChange(
                changeType: .delete,
                entityID: taskID,
                parentID: projectID
            )
        )
    }

    func persistNewTask(_ task: Task) async throws {
        modelContext.insert(task)
        try modelContext.save()

        try await syncService.push(task)

        AppRefreshCoordinator.notifyTasksChanged(
            EntityChange(
                changeType: .insert,
                entityID: task.id,
                parentID: task.projectID
            )
        )
    }
}
```

## Real-Time Sync Integration

PolyRefresh shines with real-time sync (WebSocket, Supabase Realtime, etc.):

```swift
// Real-time subscription handler
func handleRealtimeUpdate(record: [String: Any]) async {
    let entityType = record["table_name"] as? String
    let entityID = record["id"] as? String
    let parentID = record["parent_id"] as? String

    // Merge changes into local database
    await mergeRemoteChanges(record)

    // Notify UI
    if let entityType, let entityID {
        PolyRefreshCoordinator.shared.notify(
            entityType,
            change: EntityChange(
                changeType: .update,
                entityID: entityID,
                parentID: parentID
            )
        )
    }
}
```

**Benefits:**

- UI updates instantly when remote data changes
- Works across all platforms (macOS, iOS, iPadOS)
- No manual notification plumbing

## Advanced Usage

### Custom Observation Patterns

**SwiftUI:**

```swift
struct TaskListView: View {
    @State private var lastSignal = 0

    var body: some View {
        TaskListContent()
            .task {
                for await _ in signalStream() {
                    await reloadData()
                }
            }
    }

    private func signalStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            Task { @MainActor in
                observeSignals(continuation: continuation)
            }
        }
    }

    @MainActor
    private func observeSignals(continuation: AsyncStream<Void>.Continuation) {
        withObservationTracking {
            _ = PolyRefreshCoordinator.shared.signal(for: "Task")
        } onChange: {
            continuation.yield()
            Task { @MainActor in
                observeSignals(continuation: continuation)
            }
        }
    }
}
```

**Combine:**

```swift
class TaskViewModel: ObservableObject {
    @Published var tasks: [Task] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Manual Combine bridge
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .map { _ in PolyRefreshCoordinator.shared.signal(for: "Task") }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.loadTasks()
            }
            .store(in: &cancellables)
    }
}
```

### Debugging

Enable debug logging to see all registration and notification events:

```swift
// PolyRefresh prints debug info in DEBUG builds automatically:
// "PolyRefresh: Registered 'Task' with parent 'Project'"
// "PolyRefresh: 'Task' changed (update, 3 entities)"
// "PolyRefresh: Bubbled 'Task' change to parent 'Project'"
```

### Inspection

Query the coordinator state:

```swift
// Get all registered types
let types = PolyRefreshCoordinator.shared.registeredEntityTypes()
// ["User", "Project", "Task", "Tag"]

// Check hierarchy
let parent = PolyRefreshCoordinator.shared.parent(of: "Task")
// "Project"

// Get current signal value
let signal = PolyRefreshCoordinator.shared.signal(for: "Task")
// 42
```

## Performance Considerations

### Efficient Observation

**Good:**

```swift
// Only observe what you need
_ = PolyRefreshCoordinator.shared.signal(for: "Task")
```

**Bad:**

```swift
// Don't observe everything if you only care about one thing
_ = PolyRefreshCoordinator.shared.signal(for: "Task")
_ = PolyRefreshCoordinator.shared.signal(for: "Project")
_ = PolyRefreshCoordinator.shared.signal(for: "User")
_ = PolyRefreshCoordinator.shared.signal(for: "Tag")
// ... etc
```

### Batching

Batch multiple changes into a single notification:

```swift
// Bad: Multiple notifications
for task in tasks {
    task.completed = true
    AppRefreshCoordinator.notifyTasksChanged(
        EntityChange(changeType: .update, entityID: task.id)
    )
}

// Good: Single batch notification
for task in tasks {
    task.completed = true
}
AppRefreshCoordinator.notifyTasksChanged(
    EntityChange(
        changeType: .update,
        entityIDs: Set(tasks.map(\.id))
    )
)
```

### Throttling

If you're getting excessive updates, consider throttling in your observer:

```swift
private var refreshWorkItem: DispatchWorkItem?

private func handleDataChanged() {
    refreshWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
        self?.reloadData()
    }

    refreshWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
}
```

## Migration from NotificationCenter

**Before:**

```swift
// Scattered throughout your app
NotificationCenter.default.post(
    name: .taskDidChange,
    object: nil,
    userInfo: ["taskID": task.id]
)

// Observers
NotificationCenter.default.addObserver(
    forName: .taskDidChange,
    object: nil,
    queue: .main
) { notification in
    self.reloadData()
}
```

**After:**

```swift
// Single notify point
AppRefreshCoordinator.notifyTasksChanged(
    EntityChange(changeType: .update, entityID: task.id)
)

// Observable tracking
withObservationTracking {
    _ = AppRefreshCoordinator.taskSignal
} onChange: {
    Task { @MainActor in
        self.reloadData()
        self.observeSignals() // Re-subscribe
    }
}
```

**Benefits:**

- Type-safe (no string-based notification names)
- Compiler-checked (typos caught at compile time)
- Better performance (Observable is optimized)
- Hierarchical bubbling built-in
- Change details without userInfo dictionary casting

## Best Practices

1. **Register early** - Call `configure()` during app initialization, before any data operations

2. **Centralize notifications** - Notify from one place (data coordinator) rather than scattered throughout your app

3. **Use hierarchies** - Model parent-child relationships to get automatic cascading updates

4. **Provide change details** - Include `changeType` and `entityIDs` when possible for smarter UI updates

5. **Track last signals** - Compare signal values to avoid unnecessary work:

   ```swift
   if taskSignal != lastTaskSignal {
       lastTaskSignal = taskSignal
       reloadTasks()
   }
   ```

6. **Re-subscribe after onChange** - Always re-establish observation in your onChange handler

7. **Batch bulk operations** - Use `EntityChange(entityIDs: Set(...))` for multiple entities

8. **Use app-specific wrappers** - Create a typed wrapper for better DX and maintainability

## Complete Example: Todo App

```swift
// 1. Configuration at startup
@main
struct TodoApp: App {
    init() {
        configureTodoRefresh()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@MainActor
func configureTodoRefresh() {
    let coordinator = PolyRefreshCoordinator.shared
    coordinator.register("Project")
    coordinator.register("Task", parent: "Project")
    coordinator.register("Tag")
}

// 2. Data coordinator handles all persistence + notification
@MainActor
final class TodoDataCoordinator {
    static let shared = TodoDataCoordinator()

    func completeTask(_ task: Task) async throws {
        task.completed = true
        task.version += 1

        try modelContext.save()
        try await syncService.push(task)

        PolyRefreshCoordinator.shared.notify(
            "Task",
            change: EntityChange(
                changeType: .update,
                entityID: task.id,
                parentID: task.projectID
            )
        )
    }
}

// 3. UI observes and reacts
class TaskListViewController: UITableViewController {
    private var lastTaskSignal = 0
    private var tasks: [Task] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        loadTasks()
        observeRefreshSignals()
    }

    private func observeRefreshSignals() {
        withObservationTracking {
            _ = PolyRefreshCoordinator.shared.signal(for: "Task")
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleTasksChanged()
                self?.observeRefreshSignals()
            }
        }
    }

    @MainActor
    private func handleTasksChanged() {
        let signal = PolyRefreshCoordinator.shared.signal(for: "Task")
        guard signal != lastTaskSignal else { return }

        lastTaskSignal = signal
        loadTasks()
        tableView.reloadData()
    }

    private func loadTasks() {
        // Fetch from SwiftData, CoreData, etc.
        tasks = TaskStorage.shared.fetchTasks()
    }
}
```

## Comparison with Other Solutions

| Approach | PolyRefresh | NotificationCenter | Combine | SwiftUI @Published |
| -------- | ----------- | ------------------ | ------- | ------------------ |
| Type-safe | ✅ | ❌ | ✅ | ✅ |
| Cross-platform | ✅ | ✅ | ✅ | SwiftUI only |
| Hierarchical bubbling | ✅ | ❌ | ❌ | ❌ |
| Change details | ✅ | Manual | Manual | ❌ |
| Setup complexity | Minimal | Minimal | Moderate | Minimal |
| AppKit/UIKit friendly | ✅ | ✅ | ✅ | ❌ |
| Observable-based | ✅ | ❌ | ❌ | ✅ |

## Summary

PolyRefresh solves UI refresh coordination once and for all:

- ✅ **No more random UI bugs** - Everything that should update, does
- ✅ **No scattered notification code** - Centralized, typed coordination
- ✅ **No performance issues** - Observable-based efficiency
- ✅ **No maintenance nightmares** - Register once, use everywhere

**Use it in every app. Never solve this problem again.**
