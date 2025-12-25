# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PolyKit is a Swift utility library providing delightful utilities for CLI applications and native Apple development. It's built with Swift 6 strict concurrency and targets the latest OS releases. The library is organized into three main products:

- **PolyKit**: Core utilities (logging, terminal I/O, device detection, ULID generation, data explorer framework)
- **PolyMedia**: Audio/video player components and audio analysis
- **PolyBase**: Supabase sync engine with offline-first architecture

## Building and Tool Use

- **Always** run `swiftlint` before building, either via the Swift MCP or using `swiftlint lint` from the command line.
- **Always** check available MCPs and tools before falling back to shell commands.
- **Use the Apple Docs MCP often** to retrieve the latest Apple API documentation. This is especially important for modern macOS 26 and iOS 26 APIs.

Warnings are always to be treated as errors and fixed accordingly.

### Validating Build

**DO NOT** validate by building the Xcode project alone. Building individual schemes (PolyKit, PolyMedia, PolyBase) only checks if files compile in isolation - it does **NOT** validate that the library works as a consumable dependency.

```bash
# Run all tests (REQUIRED for validation)
swift test

# Run specific test
swift test --filter PolyKitTests.deviceIdentification
```

The test suite contains **smoke tests** specifically designed to catch:

- Missing imports in library code
- Incorrect access control (internal vs public)
- API breaking changes
- Generic type issues
- Any error that only surfaces when importing the library

**Building alone will give false positives.** Always test.

### Code Quality

**CRITICAL**: All warnings are treated as errors via `.treatAllWarnings(as: .error)` in Package.swift. Code must compile with zero warnings.

```bash
# Lint with swiftlint
swiftlint lint

# Format code (runs automatically via pre-commit hook)
swiftformat . --config .swiftformat

# Run pre-commit hooks manually
pre-commit run --all-files
```

## Architecture

### Module Structure

```text
PolyKit/
├── PolyLog/           # Logging system (PolyLog class, LogEntry, LogBuffer, LogLevel)
├── CLI/               # Terminal utilities (PolyTerm, WalkingMan, PolyDiff, ANSIColor)
├── DataExplorer/      # SwiftData UI framework
│   ├── Core/          # Platform-agnostic logic (context, data source, bulk edit)
│   ├── Configuration/ # Entity definitions and column configuration
│   ├── iOS/           # UIKit-based UI
│   └── macOS/         # AppKit-based UI
├── Environment+Device.swift  # Device detection utilities
└── ULID.swift         # ULID generation

PolyMedia/
├── PlayerCore.swift   # Core playback engine
├── Playable.swift     # Protocol for media items
├── AudioAnalyzer.swift     # Real-time audio analysis
└── AnimatedEqualizer.swift # Animated visualization

PolyBase/
├── PolyBaseClient.swift         # Supabase client wrapper
├── PolySyncCoordinator.swift    # Main mutation coordinator (@MainActor)
├── PolyPushEngine.swift         # Local→remote sync
├── PolyPullEngine.swift         # Remote→local sync
├── PolyReconciliationService.swift  # Conflict resolution
├── PolyHealingService.swift     # Data integrity repairs
├── PolyBaseRealtimeCoordinator.swift  # WebSocket coordination
├── PolyRealtimeSubscriber.swift # Per-table subscriptions
├── PolyBaseOfflineQueue.swift   # Offline mutation queue
└── PolySyncable.swift           # Protocol for syncable entities
```

### Key Architectural Patterns

#### Logging: PolyLog

Always use `PolyLog` for logging. It provides:

- Automatic ANSI color support detection (real terminal vs Xcode console)
- Log groups with emoji identifiers for categorization
- In-app console capture (opt-in via `enableCapture()`)
- Persistent log files (opt-in via `enablePersistence()`)
- Integration with OSLog

```swift
let log = PolyLog()
log.info("Application started", group: .networking)
```

#### DataExplorer Framework

A configuration-driven SwiftData browser with platform-specific UI (iOS/macOS). The architecture separates:

- **Configuration layer**: Define entities, columns, fields, badges, toolbar actions
- **Core layer**: Platform-agnostic business logic (PolyDataExplorerContext, data source)
- **Platform layers**: iOS (UIKit) and macOS (AppKit) view controllers

To add DataExplorer to an app, create a `PolyDataExplorerConfiguration` with entity definitions, then instantiate the platform-specific view controller.

#### PolyBase Sync Engine

An offline-first, real-time sync engine for Supabase with:

1. **PolySyncCoordinator** (`@MainActor`): Single entry point for all mutations
   - Automatically increments version numbers
   - Persists to SwiftData
   - Queues for remote sync
   - Tracks echoes to prevent duplicate updates
   - Posts notifications for UI updates

2. **Push/Pull Engines**: Bidirectional sync with conflict resolution
   - `PolyPushEngine`: Sends local changes to Supabase
   - `PolyPullEngine`: Fetches remote changes
   - `PolyReconciliationService`: Resolves conflicts using version numbers

3. **Realtime Coordination**: WebSocket-based live updates
   - `PolyBaseRealtimeCoordinator`: Manages connection lifecycle
   - `PolyRealtimeSubscriber`: Per-table subscriptions with echo filtering

4. **PolySyncable Protocol**: Entities must conform to enable sync
   - Requires: `id`, `version`, `deleted_at`, `updated_at`
   - Provides table name and field mappings

All data mutations MUST go through `PolySyncCoordinator.shared.persistChange()` or `.delete()`. Direct SwiftData saves bypass version bumping and sync.

## Development Guidelines

### Swift 6 Concurrency

- Use `@MainActor` for UI-touching code
- Mark shared singletons as `@unchecked Sendable` with proper locking
- All public types should be `Sendable` where possible
- Use `nonisolated` initializers when needed

### Platform Targeting

- macOS 15+, iOS 18+, watchOS 26+
- Use `#if canImport(UIKit)` / `#if canImport(AppKit)` for platform-specific code
- Gracefully degrade features on unsupported platforms (e.g., PolyTerm on iOS)

### Code Organization

- Group related functionality with `// MARK: - SectionName`
- Keep file headers consistent with existing style
- Platform-specific implementations live in separate files (iOS/macOS subdirectories)

### Testing Philosophy

Tests are "smoke tests" that validate API surface and compilation, not deep functionality. They ensure the library works when consumed as a dependency. See `Tests/PolyKitTests/PolyKitTests.swift` for examples.

## Common Patterns

### Using PolyLog Groups

```swift
extension LogGroup {
    static let sync = LogGroup("sync", emoji: "🔄")
    static let network = LogGroup("network", emoji: "🌐", defaultEnabled: false)
}

// At startup
logger.registeredGroups = [.sync, .network]
logger.applyDefaultStates()
logger.loadPersistedStates()

// In code
log.debug("Fetching changes", group: .sync)
```

### DataExplorer Triple-Column Layout (iPad)

The iOS DataExplorer automatically uses a triple-column layout on iPad:

- Sidebar: Entity list
- Main: Table view with records
- Detail: Selected record details

### Sync Coordinator Usage

```swift
// Initialize once at app startup
@MainActor
func setupSync() {
    PolySyncCoordinator.shared.initialize(with: modelContext)
}

// Persist changes
@MainActor
func updateTask(_ task: Task) async throws {
    task.title = "Updated Title"
    try await PolySyncCoordinator.shared.persistChange(task)
}

// Delete (tombstone pattern)
@MainActor
func deleteTask(_ task: Task) async throws {
    try await PolySyncCoordinator.shared.delete(task)
}
```

## Dependencies

- **supabase-swift** (2.0.0+): Used exclusively by PolyBase for backend sync

## Notes

- The project uses pre-commit hooks for automatic formatting (SwiftFormat) and validation
- All code is formatted according to `.swiftformat` configuration
- Git commits should follow conventional commit style (see recent history)
