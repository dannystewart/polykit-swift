# PolyKit for Swift

A collection of delightful Swift utilities that bring personality and polish to CLI applications and native Apple development. Inspired by my [Python PolyKit library](https://github.com/dannystewart/polykit/).

Each component is designed with Swift 6 strict concurrency in mind, follows Apple's API design guidelines, and integrates naturally with the Swift/SwiftUI ecosystem.

## What's Inside

### 📱 Environment+Device — SwiftUI Device Detection

Elegant device detection utilities for SwiftUI that make it easy to write platform-specific code. Provides both direct access and SwiftUI environment-based detection for iPhone, iPad, and Mac.

### 📝 PolyLog — Beautiful Console Logging

A thoughtful logging system that provides colorful, timestamped console output during development while seamlessly integrating with Apple's unified logging system (OSLog) in production builds.

**Key Features:**

- Color-coded log levels with emoji indicators (🛠️ debug, ✅ info, ⚠️ warning, ❌ error, 🔥 fault)
- Automatic timestamp formatting with millisecond precision
- Respects terminal capabilities (colors in terminal, plain text in Xcode)
- Built-in error logging patterns with `LoggableError` protocol
- Thread-safe design with `@unchecked Sendable`

### 🎨 PolyText — Terminal Colors and Input

Brings ANSI color support to your console output with automatic detection of terminal capabilities. Includes utilities for colorizing text, checking if your output supports colors (detecting Xcode vs. real terminals), and reading single characters from the terminal in raw mode.

**Key Features:**

- Smart terminal capability detection (automatically disables colors in Xcode, enables in real terminals)
- Full ANSI color palette with convenient enums
- Raw terminal input for interactive CLI tools
- iOS-aware (gracefully degrades on unsupported platforms)

### 🔍 PolyDiff — Content Comparison with Color

Compare files or text content and display beautiful, colorized diffs directly in your terminal. Perfect for showing what changed in configuration files, generated code, or any text-based content.

**Key Features:**

- File-to-file or content-to-content comparison
- Color-coded output (green for additions, red for deletions)
- Returns structured `DiffResult` with detailed change information
- Line-by-line unified diff algorithm

### 🚶 WalkingMan — The Delightful Progress Indicator

The legendary Walking Man animation `<('-'<)` for operations that take time. A charming alternative to boring spinners that brings genuine joy to waiting. Watch him pace back and forth while your tasks complete!

**Key Features:**

- Adorable ASCII art character that walks back and forth
- Customizable width, speed, color, and loading text
- Smooth turn animations at the boundaries
- Hides the cursor during animation for a clean experience
- Thread-safe operation

**Key Features:**

- Simple device idiom detection: `Device.isPhone`, `Device.isPad`, `Device.isMac`
- SwiftUI environment integration for reactive UI
- Cross-platform support (iOS and macOS)
- Clean, testable API

## Installation

### Swift Package Manager

Add PolyKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/dannystewart/polykit-swift.git", branch: "main")
]
```

## Quick Examples

### Device-Specific UI

```swift
struct ContentView: View {
    @Environment(\.deviceIdiom) var device

    var body: some View {
        if device == .iPhone {
            CompactLayout()
        } else {
            ExpandedLayout()
        }
    }
}
```

### Colorful Logging

```swift
let log = PolyLog()
log.info("Application started successfully")
log.warning("Cache is getting full")
log.error("Failed to connect to server")
```

### Terminal Colors

```swift
if PolyText.supportsColor() {
    PolyText.printColor("Success!", .green)
} else {
    print("Success!")
}
```

### File Comparison

```swift
let diff = PolyDiff.files(oldPath: "config.old.json", newPath: "config.json")
if diff.hasChanges {
    print("Found \(diff.additions.count) additions and \(diff.deletions.count) deletions")
}
```

### Walking Man Progress

```swift
let walker = WalkingMan(loadingText: "Processing your request...", color: .cyan)
walker.start()
// ... do your work ...
walker.stop()
```
