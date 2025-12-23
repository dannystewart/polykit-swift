# PolyBase: Production-Ready Supabase Sync Engine

**PolyBase** is a general-purpose, battle-tested sync engine for Swift apps using Supabase and SwiftData. It provides automatic version-based conflict resolution, encrypted fields, soft-delete tombstones, offline queueing, and hierarchical relationships—all with minimal per-app boilerplate.

---

## What Is PolyBase?

PolyBase abstracts the complex, error-prone logic of syncing SwiftData entities with Supabase into a reusable library. Instead of writing thousands of lines of custom sync code for each app, you **register your entities once** and let PolyBase handle:

- **Version-based conflict resolution** — Higher version wins, with battle-tested edge case handling
- **Tombstone pattern (soft-delete)** — Deletions sync reliably; "tombstone always wins" rule prevents resurrection
- **Field encryption** — Per-field encryption with automatic decryption and self-healing
- **Offline queue** — Failed pushes are queued and retried automatically
- **Hierarchy bumping** — Child changes bump parent versions for efficient tree reconciliation
- **Real-time sync** — Echo prevention ensures your own pushes don't trigger redundant merges
- **Full reconciliation** — Detect and repair drift between local and remote state

---

## Why PolyBase Exists

PolyBase was extracted from **Prism**, a production macOS/iOS chat app with complex sync requirements. Before PolyBase:

- Prism had **~5,500 lines** of sync infrastructure (`SupabaseSyncService`, `DataCoordinator`, reconciliation)
- Every entity type required separate push/pull/merge methods
- Sync bugs were constant—data loss, version conflicts, orphaned records
- Offline failures were logged but lost forever
- No encryption self-healing
- Per-entity tombstone structs duplicated across the codebase

After migrating to PolyBase:

- **~1,735 lines removed** from Prism
- Six entity types sync through a single generic engine
- Offline queue prevents data loss
- Encryption issues self-heal during pull
- Database-side cascade triggers ensure consistency
- **Sync reliability dramatically improved**

Prism's sync is now "really fucking good" (user's words). PolyBase packages that hard-won knowledge into a reusable library.

---

## Core Concepts

### 1. The `PolySyncable` Protocol

All syncable entities must conform to `PolySyncable`:

```swift
@Model
final class Task: PolySyncable {
    var id: String = ""        // Unique identifier (ULID/UUID)
    var version: Int = 0        // Incremented on each change
    var deleted: Bool = false   // Soft-delete flag

    var title: String = ""
    var completed: Bool = false
}
```

**Why these fields are mandatory:**

- `id` — Unique identifier for conflict resolution
- `version` — Higher version wins during sync (core conflict resolution rule)
- `deleted` — Tombstone pattern (deletions never hard-delete)

### 2. Entity Registration

Register entities at app startup with explicit field mappings:

```swift
PolyBaseRegistry.shared.register(Task.self) { config in
    config.tableName = "tasks"
    config.fields = [
        .map(\.title, to: "title"),
        .map(\.completed, to: "completed"),
    ]
    config.notification = .tasksDidChange  // Optional

    // Optional: Factory for creating entities during reconciliation
    config.factory = { record, context in
        let task = Task(
            id: record["id"]!.stringValue!,
            title: record["title"]?.stringValue ?? ""
        )
        context.insert(task)
        return task
    }
}
```

**Key points:**

- **Explicit mappings** — KeyPath-based, compile-time safe
- **Per-field encryption** — Mark fields with `encrypted: true`
- **Protected fields** — Use `rejectIfEmpty: true` to prevent data loss
- **Factory required for reconciliation** — Needed to create entities that exist remotely but not locally

### 3. The Persistence Lifecycle

All data mutations go through `PolySyncCoordinator`:

```swift
// Update existing entity
task.title = "Buy groceries"
try await PolySyncCoordinator.shared.persistChange(task)

// Create new entity
let newTask = Task(id: ULID().ulidString, title: "Walk dog")
context.insert(newTask)
try await PolySyncCoordinator.shared.persistNew(newTask)

// Delete (soft-delete with tombstone)
try await PolySyncCoordinator.shared.delete(task)

// Undelete (explicit +1000 version jump)
try await PolySyncCoordinator.shared.undelete(task)
```

**What happens under the hood:**

1. **Version bump** — `entity.version += 1`
2. **Hierarchy bump** (if configured) — Parent version incremented
3. **Local save** — SwiftData context saved
4. **Remote push** — Upsert to Supabase (with echo tracking)
5. **Offline queue** (on failure) — Operation queued for retry
6. **UI notification** (if configured) — NotificationCenter post

### 4. Conflict Resolution Rules

PolyBase applies battle-tested conflict resolution rules:

#### Rule 1: Higher Version Wins

```swift
// Remote: version 10, content "Updated remotely"
// Local:  version 9,  content "Updated locally"
// Result: Remote wins (version 10 > 9)
```

#### Rule 2: Tombstone Always Wins

If remote is deleted with `version >= local.version`, adopt the deletion locally. This prevents accidental resurrection of deleted items.

```swift
// Remote: version 5, deleted = true
// Local:  version 5, deleted = false
// Result: Local adopts deletion (deleted = true)
```

**Exception:** Explicit undelete requires `version += 1000` to override this rule.

#### Rule 3: Never Overwrite Content with Empty

Protected fields reject incoming empty values:

```swift
config.fields = [
    .map(\.content, to: "content", rejectIfEmpty: true)
]

// Remote: version 11, content ""
// Local:  version 10, content "Important data"
// Result: Rejected (protects against data loss)
```

#### Rule 4: Same-Version Healing

At equal versions, only deletion drift is healed:

```swift
// Remote: version 5, deleted = true
// Local:  version 5, deleted = false
// Result: Local adopts deletion
```

### 5. Offline Queue

Failed pushes are automatically queued and retried:

```swift
// In app startup (e.g., PrismApp.swift):
let processed = await PolySyncCoordinator.shared.processOfflineQueue()
print("Processed \(processed) offline operations")

// Check queue status:
if PolySyncCoordinator.shared.hasPendingOfflineOperations {
    print("\(PolySyncCoordinator.shared.pendingOfflineOperationCount) pending")
}
```

**Permanent errors are not retried:**

- Version regression (local version < remote)
- Invalid undelete attempts
- Immutable field violations
- Same-version mutations (benign duplicates)

### 6. Echo Prevention

When you push an entity, PolyBase marks it as "recently pushed" to prevent processing your own real-time echo:

```swift
// Push marks entity in echo tracker
try await PolySyncCoordinator.shared.persistChange(message)

// Real-time subscriber receives INSERT event
// PolyPushEngine.wasRecentlyPushed(id, table) returns true
// → Skipped (echo from own push)
```

Echo tracking is **nonisolated** and thread-safe—usable from background sync executors without MainActor hops.

### 7. Encryption with Self-Healing

Mark sensitive fields for automatic encryption:

```swift
config.fields = [
    .map(\.apiKey, to: "api_key", encrypted: true)
]
```

**On push:** Field is encrypted using `PolyBaseEncryption` (AES-256-GCM) before upsert.

**On pull:** Field is decrypted. If the remote value should be encrypted but isn't, the pull result returns `.updatedNeedsHealing`, signaling that a re-push is needed to fix the encryption drift.

### 8. Hierarchical Relationships

For parent-child relationships (e.g., `Persona → Conversation → Message`):

```swift
// Message registration
config.setParent(\.conversationID, entityType: Conversation.self)

// When a message changes:
// 1. Message version incremented
// 2. Conversation (parent) version incremented
// 3. Both saved and pushed
```

This enables efficient reconciliation—if a conversation's version changed, you know something in its subtree changed.

---

## Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│                         APP LAYER                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   Message   │  │Conversation │  │   Persona   │ (SwiftData) │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│         │                │                │                     │
│         └────────────────┼────────────────┘                     │
│                          ▼                                      │
│              PolyBaseRegistry.register(...)                     │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                      POLYBASE ENGINE                            │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                  PolySyncCoordinator                      │  │
│  │  • persistChange(entity) - version bump, save, push      │  │
│  │  • persistNew(entity) - create + sync                    │  │
│  │  • delete(entity) - tombstone pattern                    │  │
│  │  • processOfflineQueue() - retry failed operations       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                          │                                       │
│         ┌────────────────┼────────────────┐                      │
│         ▼                ▼                ▼                      │
│  ┌────────────┐  ┌────────────────┐  ┌───────────────┐          │
│  │ PushEngine │  │ PullEngine     │  │ Reconciliation│          │
│  │ (generic)  │  │ (mergeRemote)  │  │ Service       │          │
│  └────────────┘  └────────────────┘  └───────────────┘          │
│         │                │                │                      │
│         └────────────────┼────────────────┘                      │
│                          ▼                                       │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ EchoTracker, OfflineQueue, Encryption, Registry          │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
                      Supabase
```

---

## Components

### `PolySyncable` Protocol

Defines the contract for syncable entities (`id`, `version`, `deleted`).

**File:** `PolySyncable.swift`

### `PolyBaseRegistry`

Central registry for entity configurations. Apps register entities at startup with table names, field mappings, parent relations, and factories.

**File:** `PolyBaseRegistry.swift`

**Key types:**

- `PolyEntityConfig<Entity>` — Type-specific configuration
- `AnyEntityConfig` — Type-erased for storage
- `PolyFieldMapping<Entity>` — Field-level configuration

### `PolySyncCoordinator`

Central coordinator for all data mutations. Ensures consistent lifecycle: version bump → save → push → hierarchy → queue on failure.

**File:** `PolySyncCoordinator.swift`

**API:**

- `persistChange(_:)` — Update existing entity
- `persistChanges(_:)` — Batch update
- `persistNew(_:)` — Create new entity
- `delete(_:)` — Soft-delete (tombstone)
- `undelete(_:)` — Explicit resurrection (+1000 version)
- `processOfflineQueue()` — Retry failed operations

### `PolyPushEngine`

Generic engine for pushing entities to Supabase. Builds records from registered mappings, encrypts marked fields, and manages batch operations.

**File:** `PolyPushEngine.swift`

**API:**

- `push(_:)` — Push single entity
- `pushBatch(_:batchSize:)` — Batch push
- `updateTombstone(id:version:deleted:tableName:)` — Push deletion
- `buildRecord(from:config:)` — Build Supabase record
- `wasRecentlyPushed(_:table:)` — Echo check (static, nonisolated)
- `markAsPushed(_:table:)` — Mark for echo prevention (static, nonisolated)

### `PolyPullEngine`

Generic engine for pulling and merging remote changes. Applies conflict resolution rules, decrypts encrypted fields, and detects healing needs.

**File:** `PolyPullEngine.swift`

**API:**

- `mergeInto(record:local:config:)` — Merge remote into local
- `pullAll(_:filter:)` — Fetch all entities
- `pullVersions(_:)` — Fetch version info only

### `PolyReconciliationService`

Full reconciliation of local and remote state. Detects drift and executes pulls/pushes/tombstone adoptions to converge.

**File:** `PolyReconciliationService.swift`

**API:**

- `reconcile(_:)` — Reconcile entire entity type

**Process:**

1. Pull all remote versions (id, version, deleted)
2. Compare with local entities
3. Determine actions (pull, push, adopt tombstone, skip)
4. Execute actions in order (tombstones → pulls → pushes)
5. Return summary (`ReconcileResult`)

**Requires:** Entities must have a `factory` closure registered for creating new entities from remote records.

### `PolyFieldMapping`

Registry-based field mapping system with compile-time safety via KeyPaths.

**File:** `PolyFieldMapping.swift`

**Features:**

- Per-field encryption (`encrypted: true`)
- Per-field empty rejection (`rejectIfEmpty: true`)
- Type-safe getters/setters
- String, Int, Double, Bool, Date, UUID support (optional variants too)

### `PolyBaseOfflineQueue`

Persists failed operations to disk and retries them when connectivity returns.

**File:** `PolyBaseOfflineQueue.swift`

**Features:**

- Persistent queue (survives app restart)
- Automatic retry on app launch
- Permanent error detection (doesn't retry unrecoverable errors)

### `PolyBaseEncryption`

AES-256-GCM encryption for sensitive fields with per-user keys.

**File:** `PolyBaseEncryption.swift`

**Features:**

- User-scoped encryption (each user has their own key)
- Self-healing (detects unencrypted fields during pull)
- Key derivation from master secret

### `PolyBaseEchoTracker`

Thread-safe tracking of recently pushed entities to prevent real-time echo processing.

**File:** `PolyBaseEchoTracker.swift`

**Implementation:**

- Time-based tracking (entities expire after 5 seconds)
- Lock-protected (safe from background threads)
- Nonisolated API (no MainActor hops)

---

## Migration Guide for Existing Apps

### Scenario 1: No Supabase Integration Yet

**Steps:**

1. **Add PolyBase dependency:**

   ```swift
   // Package.swift
   dependencies: [
       .package(url: "https://github.com/dannystewart/polykit-swift.git", branch: "main")
   ]
   ```

2. **Make entities conform to `PolySyncable`:**

   ```swift
   @Model
   final class Item: PolySyncable {
       var id: String = ULID().ulidString
       var version: Int = 0
       var deleted: Bool = false

       var title: String = ""
   }
   ```

3. **Create Supabase table with required columns:**

   ```sql
   CREATE TABLE items (
       id TEXT PRIMARY KEY,
       version INTEGER NOT NULL DEFAULT 0,
       deleted BOOLEAN NOT NULL DEFAULT FALSE,
       updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
       user_id UUID NOT NULL,
       title TEXT NOT NULL
   );
   ```

4. **Register entities at app startup:**

   ```swift
   PolyBaseRegistry.shared.register(Item.self) { config in
       config.tableName = "items"
       config.fields = [
           .map(\.title, to: "title")
       ]
       config.factory = { record, context in
           let item = Item(
               id: record["id"]!.stringValue!,
               title: record["title"]?.stringValue ?? ""
           )
           context.insert(item)
           return item
       }
   }
   ```

5. **Initialize PolyBase:**

   ```swift
   // In app initialization
   PolyBaseConfig.configure(
       logger: logger,
       logGroup: .database,
       modelContext: modelContext
   )
   ```

6. **Use PolySyncCoordinator for all mutations:**

   ```swift
   // Instead of: context.save()
   try await PolySyncCoordinator.shared.persistChange(item)
   ```

7. **Process offline queue on app launch:**

   ```swift
   Task {
       await PolySyncCoordinator.shared.processOfflineQueue()
   }
   ```

### Scenario 2: Existing Supabase Integration (Legacy Sync Logic)

**Problem:** You have existing sync code that:

- Manually builds Supabase records for each entity type
- Has separate push/pull/merge methods per entity
- May have partial conflict resolution or offline handling
- Likely missing features (encryption, tombstones, reconciliation)

**Migration Strategy:**

#### Phase 1: Add PolyBase Alongside Existing Code

1. Add `id`, `version`, `deleted` to entities (if missing)
2. Register entities with PolyBase
3. Don't remove old sync code yet

#### Phase 2: Migrate One Entity Type (Pilot)

Choose a simple, low-stakes entity (e.g., user preferences, settings):

1. **Switch to PolySyncCoordinator:**

   ```swift
   // Old:
   entity.version += 1
   try context.save()
   try await supabase.from("settings").upsert(record).execute()

   // New:
   try await PolySyncCoordinator.shared.persistChange(entity)
   ```

2. **Remove old push/pull methods for that entity**

3. **Test thoroughly** — Verify sync works, conflicts resolve, offline queue catches failures

#### Phase 3: Migrate Remaining Entities

Repeat Phase 2 for each entity type, starting with simple ones and working toward complex hierarchies.

#### Phase 4: Clean Up

Remove old sync infrastructure:

- Old `SyncService` methods (push/pull/merge per entity)
- Custom version-bumping logic
- Manual Supabase record building
- Old reconciliation code
- Legacy tombstone structs

**Expected outcome:** Thousands of lines removed, sync reliability dramatically improved.

---

## Database Schema Requirements

### Required Columns

Every synced table must have:

```sql
id TEXT PRIMARY KEY,              -- Unique identifier (ULID/UUID)
version INTEGER NOT NULL DEFAULT 0,  -- Conflict resolution version
deleted BOOLEAN NOT NULL DEFAULT FALSE,  -- Soft-delete flag
updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),  -- Last update time
user_id UUID NOT NULL  -- For row-level security (if multi-user)
```

### Database Guards (Recommended)

Add PostgreSQL guards to enforce sync rules:

#### 1. Version Regression Guard

```sql
CREATE OR REPLACE FUNCTION guard_version_regression()
RETURNS TRIGGER AS $$
BEGIN
    -- Prevent version from decreasing
    IF NEW.version < OLD.version THEN
        RAISE EXCEPTION 'Version regression: version cannot decrease (old=%, new=%)',
            OLD.version, NEW.version;
    END IF;

    -- Prevent same-version mutations (except deletion healing)
    IF NEW.version = OLD.version AND NEW.deleted = OLD.deleted THEN
        RAISE EXCEPTION 'Same-version mutation is not allowed (version=%)', NEW.version;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER guard_version_regression_trigger
    BEFORE UPDATE ON messages
    FOR EACH ROW EXECUTE FUNCTION guard_version_regression();
```

#### 2. Undelete Guard

```sql
CREATE OR REPLACE FUNCTION guard_undelete()
RETURNS TRIGGER AS $$
BEGIN
    -- Undeleting requires version >= old + 1000
    IF OLD.deleted = TRUE AND NEW.deleted = FALSE THEN
        IF NEW.version < OLD.version + 1000 THEN
            RAISE EXCEPTION 'Undelete requires version >= old + 1000 (old=%, new=%)',
                OLD.version, NEW.version;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER guard_undelete_trigger
    BEFORE UPDATE ON messages
    FOR EACH ROW EXECUTE FUNCTION guard_undelete();
```

#### 3. Cascade Soft-Delete (for Hierarchies)

```sql
CREATE OR REPLACE FUNCTION cascade_conversation_soft_delete()
RETURNS TRIGGER AS $$
BEGIN
    -- When conversation is soft-deleted, cascade to messages
    IF NEW.deleted = TRUE AND OLD.deleted = FALSE THEN
        UPDATE messages
        SET deleted = TRUE, version = version + 1
        WHERE conversation_id = NEW.id AND deleted = FALSE;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cascade_conversation_soft_delete_trigger
    AFTER UPDATE OF deleted ON conversations
    FOR EACH ROW EXECUTE FUNCTION cascade_conversation_soft_delete();
```

**Why database-side triggers?**

- **Consistency:** Can't mess it up in app code if the database handles it
- **Atomic:** Cascade happens in the same transaction
- **Works across clients:** Multiple apps/platforms get the same behavior

---

## Real-Time Sync Integration

PolyBase doesn't manage real-time subscriptions directly (that's still app-specific), but it provides echo prevention to avoid processing your own pushes.

### Example Real-Time Handler (App-Side)

```swift
func handleRealtimeInsert(record: [String: AnyJSON], tableName: String) async {
    guard let id = record["id"]?.stringValue else { return }

    // Check for echo
    if PolyPushEngine.wasRecentlyPushed(id, table: tableName) {
        return  // Skip - this is our own push
    }

    // Merge the remote change
    let pullEngine = PolyPullEngine(modelContext: context)
    let result = await pullEngine.mergeRemote(
        record: record,
        tableName: tableName,
        isNew: true
    )

    if result.wasModified {
        try? context.save()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
    }
}
```

### Echo Prevention Pattern

1. **Before push:** `PolyPushEngine.markAsPushed(id, table: tableName)`
2. **On real-time event:** Check `PolyPushEngine.wasRecentlyPushed(id, table)`
3. **If true:** Skip (echo from own push)
4. **If false:** Merge remote change

**Important:** Echo tracking is nonisolated—safe to call from background sync executors without MainActor hops.

---

## Performance Considerations

### Batch Operations

Always prefer batch operations for multiple entities:

```swift
// ❌ Bad: One-by-one (N saves, N pushes, N notifications)
for item in items {
    try await PolySyncCoordinator.shared.persistChange(item)
}

// ✅ Good: Batch (1 save, 1 batch push, 1 notification)
try await PolySyncCoordinator.shared.persistChanges(items)
```

### Background Sync Executor

For bulk pulls and reconciliation, use a SwiftData `@ModelActor` to avoid blocking the UI thread:

```swift
@ModelActor
actor AppSyncActor {
    func pullAllItems() async throws {
        let pullEngine = PolyPullEngine(modelContext: modelContext)
        let records = try await pullEngine.pullAll(Item.self)

        for record in records {
            // Merge logic here
        }

        try modelContext.save()
    }
}
```

### Reconciliation Throttling

Don't run full reconciliation on every app launch—throttle it:

```swift
// Only reconcile if:
// 1. More than 1 hour since last reconcile
// 2. User explicitly requests it
// 3. Persistent drift detected

if Date().timeIntervalSince(lastReconcileTime) > 3600 {
    let result = await PolyReconciliationService.shared.reconcile(Item.self)
    lastReconcileTime = Date()
}
```

---

## Error Handling

### Push Failures

Push failures automatically queue for retry via `PolyBaseOfflineQueue`. You can monitor queue status:

```swift
if PolySyncCoordinator.shared.hasPendingOfflineOperations {
    // Show indicator in UI
    showSyncPendingIndicator()
}
```

### Reconciliation Failures

Reconciliation returns a detailed result:

```swift
let result = await PolyReconciliationService.shared.reconcile(Item.self)

if !result.succeeded {
    for error in result.errors {
        print("❌ \(error.action) failed for \(error.entityID): \(error.underlyingError)")
    }
}

print("↓\(result.pulled) ↑\(result.pushed) 🪦\(result.tombstonesAdopted)")
```

### Version Regression Detected

When a push is rejected due to version regression (local is stale), PolyBase posts a notification:

```swift
NotificationCenter.default.addObserver(
    forName: .polyBaseVersionRegressionDetected,
    object: nil,
    queue: .main
) { notification in
    guard let entityID = notification.userInfo?["entityId"] as? String else { return }

    // Trigger reconciliation to pull the latest version
    Task {
        await PolyReconciliationService.shared.reconcile(Item.self)
    }
}
```

---

## Advanced Features

### Custom Conflict Resolution

Add custom validation rules per entity:

```swift
config.conflictRules = PolyConflictRules(
    protectNonEmptyContent: true,
    protectedFields: ["title", "content"],
    customValidator: { local, remote in
        // Custom logic here
        // Return false to reject the remote change
        guard let localItem = local as? Item else { return true }
        guard let remoteStatus = remote["status"]?.stringValue else { return true }

        // Reject if trying to revert finalized to draft
        if localItem.status == "finalized" && remoteStatus == "draft" {
            return false
        }
        return true
    }
)
```

### Encryption Key Rotation

PolyBase supports re-encrypting data with a new master key:

```swift
// Update master encryption secret
PolyBaseEncryption.shared?.updateMasterKey(newSecret: newSecretKey)

// Force reconciliation to re-encrypt all encrypted fields
let result = await PolyReconciliationService.shared.reconcile(Item.self)
```

### Soft-Delete Purge

Periodically purge old tombstones (entities with `deleted = true`):

```swift
// App-side purge logic (run infrequently)
let descriptor = FetchDescriptor<Item>(
    predicate: #Predicate { $0.deleted == true }
)
let tombstones = try context.fetch(descriptor)

// Hard-delete tombstones older than 30 days
let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
for tombstone in tombstones where tombstone.updatedAt < cutoff {
    context.delete(tombstone)
}
try context.save()
```

---

## Testing

### Unit Tests

Test entity registration and field mapping:

```swift
func testEntityRegistration() {
    PolyBaseRegistry.shared.clearAll()

    PolyBaseRegistry.shared.register(TestItem.self) { config in
        config.tableName = "test_items"
        config.fields = [.map(\.title, to: "title")]
    }

    let config = PolyBaseRegistry.shared.config(for: TestItem.self)
    XCTAssertNotNil(config)
    XCTAssertEqual(config?.tableName, "test_items")
}
```

### Integration Tests

Test push/pull with a test Supabase instance:

```swift
@MainActor
func testPushPull() async throws {
    let item = TestItem(id: "test-1", title: "Test")
    context.insert(item)

    // Push
    try await PolySyncCoordinator.shared.persistNew(item)

    // Modify remotely (simulate another device)
    try await supabase.from("test_items")
        .update(["title": "Modified", "version": 1])
        .eq("id", value: "test-1")
        .execute()

    // Pull
    let pullEngine = PolyPullEngine(modelContext: context)
    let records = try await pullEngine.pullAll(TestItem.self)
    XCTAssertEqual(records.count, 1)

    // Merge
    let record = records[0]
    let result = pullEngine.mergeInto(
        record: record,
        local: item,
        config: PolyBaseRegistry.shared.config(for: TestItem.self)!
    )
    XCTAssertTrue(result.wasModified)
    XCTAssertEqual(item.title, "Modified")
}
```

---

## FAQ

### Q: Do I need to include `id`, `version`, and `deleted` in all entities?

**A:** Yes. These three fields are mandatory for `PolySyncable`. They enable version-based conflict resolution and the tombstone pattern. If you don't want soft-delete semantics, you can still hard-delete locally—just don't use `PolySyncCoordinator.delete()`.

### Q: Can I use PolyBase with Core Data instead of SwiftData?

**A:** Not currently. PolyBase is designed for SwiftData and uses `ModelContext`, `PersistentModel`, and `@ModelActor`. Core Data support could be added, but it's not a priority.

### Q: What if I don't need encryption?

**A:** Don't configure `PolyBaseEncryption` and don't mark any fields as `encrypted: true`. The encryption system is opt-in per field.

### Q: What if I don't need real-time sync?

**A:** You can use PolyBase without real-time subscriptions. Just use `PolySyncCoordinator` for mutations and `PolyReconciliationService` for periodic reconciliation. Real-time is optional.

### Q: How does PolyBase handle conflicts between multiple devices?

**A:** Version-based conflict resolution. The device with the higher version wins. If both devices modify at the same version, whichever pushes first sets the new version; the second device's push is rejected as "version regression" and triggers a reconciliation pull to get the latest state.

### Q: Can I customize the offline queue retry logic?

**A:** Not currently. The queue retries all operations on app launch and after sign-in. You can call `processOfflineQueue()` manually at any time. Network connectivity detection isn't built-in yet.

### Q: What happens if I delete an entity locally but another device modifies it remotely?

**A:** If the remote modification has a higher version, the deletion is overridden and the entity is restored locally with the remote changes. If the deletion has a higher version, the "tombstone always wins" rule applies and the entity stays deleted. This is why explicit undelete requires a +1000 version jump—to override the tombstone rule.

### Q: Can I use PolyBase for non-user-specific data (no RLS)?

**A:** Yes. Set `config.includeUserID = false` during registration. PolyBase will not include `user_id` in pushes or filter by it during pulls.

### Q: How do I handle schema migrations?

**A:** Add new fields to your entity, register them with PolyBase, and add the corresponding columns to Supabase. For backward compatibility, use optional fields (`.map(\.newField, to: "new_field")` with `String?`). Old data will have `nil` for the new field until it's updated.

---

## Summary

**PolyBase** is a production-ready sync engine that removes the complexity and error-prone nature of custom Supabase sync logic. By adopting PolyBase, you get:

- **Reliable sync** — Battle-tested conflict resolution, tombstones, offline queue
- **Less code** — ~1,700 lines removed from Prism after migration
- **Better UX** — No data loss, self-healing encryption, graceful offline handling
- **Reusability** — Write sync logic once, reuse across all apps

Whether you're starting fresh or migrating from legacy sync code, PolyBase provides a solid foundation for SwiftData + Supabase apps.
