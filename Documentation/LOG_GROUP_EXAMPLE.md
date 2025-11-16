# PolyLog Group-Based Logging Examples

## Overview

PolyLog now supports **group-based logging** - a way to categorize logs and control their visibility at runtime. This is perfect for managing noisy logs in complex applications while maintaining clean, organized output.

## Basic Concepts

### What Are Log Groups?

Log groups are type-safe identifiers that categorize logs. They're completely optional - logs without groups always print.

### Key Features

- ✅ **Optional** - Works seamlessly with existing code
- ✅ **Type-safe** - Use Swift extensions for compile-time safety
- ✅ **Thread-safe** - Safe to enable/disable groups from any thread
- ✅ **Zero overhead** - No performance impact when groups aren't used
- ✅ **Runtime control** - Toggle groups dynamically as your app runs

## Quick Start

### 1. Define Your Groups

Create a file to define your app's log groups:

```swift
import PolyKit

// Define your application's log groups
extension LogGroup {
    static let networking = LogGroup("networking")
    static let database = LogGroup("database")
    static let ui = LogGroup("ui")
    static let authentication = LogGroup("auth")
    static let fileProcessing = LogGroup("files")
}
```

### 2. Use Groups in Your Logging

```swift
let logger = PolyLog()

// Regular logging (always prints)
logger.info("App started")

// Group-tagged logging (can be filtered)
logger.debug("Fetching user profile", group: .networking)
logger.debug("Query: SELECT * FROM users", group: .database)
logger.debug("Updating view hierarchy", group: .ui)
```

### 3. Control Groups at Runtime

```swift
// Disable noisy groups during normal operation
logger.disableGroup(.networking)
logger.disableGroup(.database)

// The following won't print:
logger.debug("HTTP GET /api/users", group: .networking)  // Silenced
logger.debug("Cache miss", group: .database)  // Silenced

// But group-less logs still print:
logger.info("User logged in")  // ✅ Printed

// Re-enable when debugging specific issues
logger.enableGroup(.networking)
logger.debug("Request timeout", group: .networking)  // ✅ Printed now
```

## Real-World Use Cases

### Scenario 1: Debugging Network Issues

```swift
// Your app is having network problems. Enable just networking logs:

logger.disableGroups([.database, .ui, .fileProcessing])
logger.enableGroup(.networking)

// Now only networking logs will appear, making it easy to spot the issue
```

### Scenario 2: Development vs Production

```swift
#if DEBUG
    // Show everything during development
    logger.enableAllGroups()
#else
    // In production, only show critical logs (those without groups)
    // and specific groups you care about
    logger.disableGroups([.database, .fileProcessing])
#endif
```

### Scenario 3: UI Toggle for Power Users

```swift
// In a settings panel or developer menu:

struct LoggingSettingsView: View {
    @State private var networkingEnabled = true
    @State private var databaseEnabled = false
    let logger: PolyLog

    var body: some View {
        Form {
            Toggle("Network Logs", isOn: $networkingEnabled)
                .onChange(of: networkingEnabled) { oldValue, newValue in
                    if newValue {
                        logger.enableGroup(.networking)
                    } else {
                        logger.disableGroup(.networking)
                    }
                }

            Toggle("Database Logs", isOn: $databaseEnabled)
                .onChange(of: databaseEnabled) { oldValue, newValue in
                    if newValue {
                        logger.enableGroup(.database)
                    } else {
                        logger.disableGroup(.database)
                    }
                }
        }
    }
}
```

## Output Format

When using groups, logs include a cyan-colored tag:

```text
9:15:23.456 PM ✅ [networking] Successfully connected to server
9:15:23.789 PM 🛠️  [database] Executing query...
9:15:24.012 PM ⚠️  [ui] View layout update took 45ms
```

Without terminal color support:

```text
9:15:23.456 PM ✅ [networking] Successfully connected to server
```

## Using Emojis for Visual Clarity

Groups support optional emojis for more compact and visually scannable output. When an emoji is provided, it's used in the log output instead of the bracketed identifier.

### Defining Groups with Emojis

```swift
extension LogGroup {
    static let networking = LogGroup("networking", emoji: "🌐")
    static let database = LogGroup("database", emoji: "💾")
    static let ui = LogGroup("ui", emoji: "🎨")
    static let authentication = LogGroup("auth", emoji: "🔐")
    static let fileSystem = LogGroup("filesystem", emoji: "📁")
    static let performance = LogGroup("performance", emoji: "⚡️")

    // Can mix and match - groups without emojis still work
    static let legacy = LogGroup("legacy")
}
```

### Output Comparison

**With emojis:**

```text
9:15:23.456 PM ✅ 🌐 Successfully connected to server
9:15:23.789 PM 🛠️  💾 Executing query...
9:15:24.012 PM ⚠️  🎨 View layout update took 45ms
9:15:24.234 PM ❌ 🔐 Authentication failed
9:15:24.567 PM ✅ [legacy] Old system message
```

**Without emojis (traditional):**

```text
9:15:23.456 PM ✅ [networking] Successfully connected to server
9:15:23.789 PM 🛠️  [database] Executing query...
9:15:24.012 PM ⚠️  [ui] View layout update took 45ms
9:15:24.234 PM ❌ [auth] Authentication failed
9:15:24.567 PM ✅ [legacy] Old system message
```

### Benefits of Emojis

- 🎯 **Glanceability** - Instantly spot specific subsystems in log output
- 📏 **Brevity** - `🌐` vs `[networking]` saves ~12 characters per line
- 🌈 **Visual Distinction** - Color-coded at a glance without ANSI color support
- 🔍 **Quick Scanning** - Emoji patterns stand out when scrolling through logs
- 🧹 **Cleaner Output** - Less visual clutter in dense log streams

### Recommended Emojis

Here are some commonly useful emojis for logging:

```swift
extension LogGroup {
    // Network & Communication
    static let networking = LogGroup("networking", emoji: "🌐")
    static let api = LogGroup("api", emoji: "🔌")
    static let websocket = LogGroup("websocket", emoji: "📡")

    // Data & Storage
    static let database = LogGroup("database", emoji: "💾")
    static let cache = LogGroup("cache", emoji: "💿")
    static let fileIO = LogGroup("file-io", emoji: "📁")

    // UI & Presentation
    static let ui = LogGroup("ui", emoji: "🎨")
    static let layout = LogGroup("layout", emoji: "📐")
    static let animation = LogGroup("animation", emoji: "✨")

    // Security & Auth
    static let authentication = LogGroup("auth", emoji: "🔐")
    static let encryption = LogGroup("encryption", emoji: "🔒")
    static let permissions = LogGroup("permissions", emoji: "🛡️")

    // Performance & Monitoring
    static let performance = LogGroup("performance", emoji: "⚡️")
    static let memory = LogGroup("memory", emoji: "🧠")
    static let diagnostics = LogGroup("diagnostics", emoji: "🔬")

    // Business Logic
    static let payments = LogGroup("payments", emoji: "💳")
    static let analytics = LogGroup("analytics", emoji: "📊")
    static let notifications = LogGroup("notifications", emoji: "🔔")
}
```

### Best Practices with Emojis

**Do:**

- ✅ Choose emojis that are semantically meaningful
- ✅ Use consistent emoji patterns across your codebase
- ✅ Keep identifiers clear even when emojis are used (code references `.networking`, not `.globe`)
- ✅ Mix emoji and non-emoji groups as needed

**Don't:**

- ❌ Use multiple emojis per group (creates visual clutter)
- ❌ Choose confusing or ambiguous emojis
- ❌ Rely solely on emojis - identifiers remain the source of truth

## API Reference

### Creating Groups

```swift
// Type-safe approach (recommended)
extension LogGroup {
    static let myGroup = LogGroup("myGroup")
    static let withEmoji = LogGroup("withEmoji", emoji: "🎯")
}

// Direct creation
let customGroup = LogGroup("custom-feature")
let emojiGroup = LogGroup("important", emoji: "⭐️")
```

### Logging with Groups

```swift
// All log levels support optional groups
logger.debug("Debug info", group: .myGroup)
logger.info("Info message", group: .myGroup)
logger.warning("Warning message", group: .myGroup)
logger.error("Error message", group: .myGroup)
logger.fault("Critical fault", group: .myGroup)

// Groups are always optional
logger.info("This always prints")
```

### Managing Groups

```swift
// Disable a single group
logger.disableGroup(.networking)

// Enable a single group
logger.enableGroup(.networking)

// Disable multiple groups at once
logger.disableGroups([.database, .ui, .fileProcessing])

// Enable multiple groups at once
logger.enableGroups([.database, .ui])

// Check if an group is enabled
if logger.isGroupEnabled(.networking) {
    // Perform expensive logging preparation
    let detailedInfo = buildDetailedNetworkReport()
    logger.debug(detailedInfo, group: .networking)
}

// Get all disabled groups
let disabled = logger.getDisabledGroups()
print("Disabled groups: \(disabled)")

// Enable all groups (clear disabled list)
logger.enableAllGroups()
```

## Best Practices

### 1. Define Groups Once

Create a single file with all your app's log groups:

```swift
// LogGroups.swift
import PolyKit

extension LogGroup {
    // Core systems
    static let networking = LogGroup("networking")
    static let database = LogGroup("database")

    // Features
    static let authentication = LogGroup("auth")
    static let payments = LogGroup("payments")

    // Components
    static let imageCache = LogGroup("image-cache")
    static let analytics = LogGroup("analytics")
}
```

### 2. Use Descriptive Identifiers

```swift
// ✅ Good - clear and specific
static let networkRequest = LogGroup("network-request")
static let userAuthentication = LogGroup("user-auth")

// ❌ Bad - too generic
static let stuff = LogGroup("stuff")
static let x = LogGroup("x")
```

### 3. Critical Logs Should Use No Group

Reserve group-less logging for critical information that should always appear:

```swift
// Always prints (no group)
logger.error("Failed to save user data - disk full!")

// Can be filtered (has group)
logger.debug("Cache statistics: 45% hit rate", group: .performance)
```

### 4. Check Before Expensive Operations

Use `isGroupEnabled()` to avoid expensive logging preparation when an group is disabled:

```swift
if logger.isGroupEnabled(.diagnostics) {
    // Only build this expensive report if it will be logged
    let fullSystemReport = buildComprehensiveSystemReport()
    logger.debug(fullSystemReport, group: .diagnostics)
}
```

### 5. Document Your Groups

Keep a list of your app's groups and their purposes:

```swift
extension LogGroup {
    /// Logs related to network requests and responses
    static let networking = LogGroup("networking")

    /// Database queries and transaction logs
    static let database = LogGroup("database")

    /// UI rendering and layout operations
    static let ui = LogGroup("ui")

    /// Authentication flows and token management
    static let authentication = LogGroup("auth")
}
```

## Thread Safety

All group management methods are thread-safe. You can safely enable/disable groups from any thread:

```swift
// Safe to call from any thread
DispatchQueue.global().async {
    logger.disableGroup(.networking)
}

Task {
    logger.enableGroup(.database)
}
```

## Backward Compatibility

The group feature is 100% backward compatible. Existing code without groups continues to work unchanged:

```swift
// Old code - still works perfectly
logger.info("This still works")
logger.error("No changes needed")

// New code - optional groups
logger.info("This also works", group: .networking)
```

## Performance Notes

- **Zero overhead** when not using groups (default behavior unchanged)
- **Minimal overhead** when using groups: single `Set.contains()` check
- **Thread-safe** using `NSLock` (fast on modern Swift)
- **Group filtering happens early** - disabled groups skip all formatting

## Integration with Apple's Unified Logging

Group information is included in Apple's unified logging system (os_log), so you can filter by group in Console.app:

```swift
// In Console.app, you'll see:
// [networking] Successfully connected to server
```

## Migration Guide

### From Regular Logging

```swift
// Before
logger.debug("Network request completed")

// After
logger.debug("Network request completed", group: .networking)
```

### From Custom Categories

If you were using prefixes or custom category systems:

```swift
// Before
logger.debug("[NET] Request completed")

// After
logger.debug("Request completed", group: .networking)
// Output: 9:15:23.456 PM 🛠️  [networking] Request completed
```

## Troubleshooting

### Logs Not Appearing?

Check if the group is disabled:

```swift
if !logger.isGroupEnabled(.myGroup) {
    print("Group is disabled!")
    logger.enableGroup(.myGroup)
}
```

### Too Much Output?

Disable noisy groups:

```swift
// Find which groups are producing too much output
logger.getDisabledGroups()  // Check current state

// Disable the noisy ones
logger.disableGroups([.database, .networking])
```

### Need to Reset?

```swift
// Enable everything
logger.enableAllGroups()

// Or start fresh
let logger = PolyLog()  // New instance has no disabled groups
```

---

## Summary

Group-based logging in PolyLog provides:

- 🎯 **Focused debugging** - See only the logs you care about
- 🔧 **Runtime control** - Toggle groups without recompiling
- 📊 **Better organization** - Categorize logs logically
- ⚡ **Performance** - Skip disabled groups early, avoid waste
- 🔒 **Type safety** - Compile-time checks with Swift extensions
- 🔄 **Backward compatible** - Existing code works unchanged

Start using groups today to make your debugging sessions more productive and your logs more manageable!
