# Seq Logging Setup for volumeHUD

This guide explains how to enable and use Seq logging for beta testing and production debugging.

## What is Seq?

[Seq](https://datalust.co/seq) is a centralized log aggregation server that makes it easy to search, filter, and analyze logs from multiple sources. It's perfect for beta testing because your testers' logs automatically stream to your Seq server, giving you the full context you need to debug issues.

## Quick Start

### 1. Install Seq (Local Development)

For local testing, install Seq via Docker:

```bash
docker run --name seq -d --restart unless-stopped \
  -e ACCEPT_EULA=Y \
  -p 5341:80 \
  datalust/seq:latest
```

Then visit <http://localhost:5341> to access the Seq UI.

### 2. Configure volumeHUD

Open `volumeHUD/SeqConfiguration.swift` and update the settings:

```swift
enum SeqConfiguration {
    // Enable/disable Seq logging
    static let isEnabled = true

    // Update this to your Seq server's URL
    static let serverUrl = "http://your-seq-server.com:5341"

    // Optional: Add an API key for authentication
    static let apiKey: String? = "your-api-key-here"
}
```

### 3. Update AppDelegate to Use Seq Logging

You have two options for integrating Seq:

#### Option A: Shared Logger with Seq (Recommended for Beta)

Create a shared logger instance in `AppDelegate` that all components can use:

```swift
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // Shared logger instance with Seq
    static var logger: PolyLog!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize shared logger with Seq support
        Task {
            Self.logger = await SeqConfiguration.createLogger()

            // Now continue with your initialization...
            if isDevEnvironment() { return }
            // ... rest of init
        }
    }
}

// Then in other components, use the shared logger:
class VolumeMonitor {
    private var logger: PolyLog { AppDelegate.logger }

    func someMethod() {
        logger.info("Volume changed")
    }
}
```

#### Option B: Individual Loggers per Component

Keep the current pattern but initialize each logger with Seq:

```swift
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var logger: PolyLog!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            // Initialize with Seq
            self.logger = await SeqConfiguration.createLogger()

            // Continue initialization...
        }
    }
}

// And similarly for other components:
class VolumeMonitor {
    var logger: PolyLog!

    init(isPreviewMode: Bool = false) {
        // Initialize async in a Task
        Task {
            self.logger = await SeqConfiguration.createLogger()
        }
        // ... rest of init
    }
}
```

**Note:** Option B requires more changes but keeps components independent. Option A is simpler for beta testing.

## Production Setup

### Deploy Seq Server

For beta testing with external users, you'll need a publicly accessible Seq server:

1. **Cloud Hosting**: Deploy Seq to a cloud provider (AWS, DigitalOcean, etc.)
2. **Docker Compose** (recommended for VPS):

```yaml
version: '3'
services:
  seq:
    image: datalust/seq:latest
    environment:
      - ACCEPT_EULA=Y
      - SEQ_FIRSTRUN_ADMINUSERHASH=${SEQ_ADMIN_HASH}  # Set via env
    ports:
      - "5341:80"
    volumes:
      - seq-data:/data
    restart: unless-stopped

volumes:
  seq-data:
```

3. **Generate API Key**: In Seq UI → Settings → API Keys → Create key for your app

### Security Considerations

- **Always use HTTPS** in production (put Seq behind nginx/Caddy with SSL)
- **Use API keys** to prevent unauthorized log submissions
- **Firewall**: Only allow connections from your app's servers/beta testers
- **Data retention**: Configure Seq to automatically delete old logs

## Using Seq for Debugging

Once logs are flowing, you can:

1. **Search logs**: Use Seq's powerful query syntax

   ```text
   Level = 'Error' and Application = 'com.dannystewart.volumehud'
   ```

2. **Filter by session**: Each app session gets a unique `SessionId`

   ```text
   SessionId = 'abc-123-def'
   ```

3. **Find patterns**: Group by version, OSVersion, etc.

4. **Create alerts**: Get notified when errors occur

## Disabling Seq

To disable Seq logging (e.g., for App Store release):

1. Set `SeqConfiguration.isEnabled = false`
2. Or: Remove the `seqSink` parameter when creating loggers

Logs will still go to console (DEBUG) and system logger (production) as normal.

## Troubleshooting

### Logs not appearing in Seq?

1. Check Seq server is running: `curl http://your-server:5341/api/events/raw`
2. Check app can reach server: Look for warnings in Console.app
3. Verify API key is correct
4. Check firewall rules

### Performance concerns?

- Logs are batched and sent asynchronously
- Failed sends don't block or crash the app
- In-memory buffer is small (20 events by default)
- Network failures fail silently

### Privacy concerns?

- Seq integration only sends log messages you explicitly write
- No automatic PII collection
- Consider what you log in production builds
- Can disable entirely for App Store builds

## Example Queries

Here are some useful Seq queries for volumeHUD:

```text
// All errors in the last hour
Level = 'Error' and @Timestamp > Now() - 1h

// Volume changes
@Message like '%volume%'

// Specific version issues
Version = '2.0.0' and Level in ['Error', 'Warning']

// Crashes (app startup followed by quick exit)
@Message = 'volumeHUD started!'
  and not exists(
    @Message = 'Stopping monitoring and quitting.'
    and SessionId = {SessionId}
  )
```

## Architecture Notes

The Seq integration is built into your `PolyLog` framework, so:

- **Zero changes to existing logging calls** - just initialize with a `SeqSink`
- **Works everywhere you use PolyLog** - AppDelegate, monitors, controllers, etc.
- **Fail-safe** - Seq errors don't affect app functionality
- **Portable** - Can be used in other projects that use PolyLog

Happy debugging! 🎉

# Seq Logging Integration for volumeHUD

Your volumeHUD app now has **built-in Seq logging support** for beta testing! 🎉

## What You Got

### In PolyKit (your logging framework)

- ✅ **`SeqSink`** - A fully async, batch-based log sink that streams to Seq
- ✅ **Extended `PolyLog`** - Now accepts an optional `SeqSink` parameter
- ✅ **Zero breaking changes** - Existing code works exactly as before

### In volumeHUD

- ✅ **`SeqConfiguration.swift`** - Central config for Seq settings
- ✅ **`BetaConfiguration.swift`** - Smart beta feature management
- ✅ **`SEQ_SETUP.md`** - Complete setup guide
- ✅ **`INTEGRATION_EXAMPLE.swift`** - Code examples
- ✅ **`scripts/test-seq.swift`** - Test script

## Quick Start (3 minutes)

### 1. Start Seq Locally

```bash
docker run -d --name seq -p 5341:80 -e ACCEPT_EULA=Y datalust/seq
```

Visit <http://localhost:5341> to see the Seq UI.

### 2. Test the Connection

```bash
swift scripts/test-seq.swift
```

You should see test logs appear in Seq!

### 3. Enable in Your App

Option A - **Simplest** (Recommended for beta):

```swift
// In AppDelegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedLogger: PolyLog!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            // Initialize with Seq
            Self.sharedLogger = await SeqConfiguration.createLogger()

            // Continue with normal init
            continueInitialization()
        }
    }
}

// In other files (VolumeMonitor, BrightnessMonitor, etc.):
class VolumeMonitor {
    var logger: PolyLog { AppDelegate.sharedLogger }
    // Everything else stays the same!
}
```

Option B - **More flexible**:

```swift
// In AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var logger: PolyLog!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            self.logger = await SeqConfiguration.createLogger()
            continueInitialization()
        }
    }
}

// Do the same in each component that has a logger
```

### 4. Deploy for Beta Testers

Update `SeqConfiguration.swift`:

```swift
static let serverUrl = "https://your-seq-server.com"
static let apiKey = "your-api-key"
```

Ship it! Logs will start flowing to your server.

## Key Features

### 🚀 Async & Non-Blocking

- Logs are batched and sent asynchronously
- Never blocks your UI or main operations
- Failed sends don't crash the app

### 🎯 Auto-Enrichment

Every log automatically includes:

- `Application` - Your bundle identifier
- `Version` - App version (e.g., "2.0-beta.3")
- `Platform` - Always "macOS"
- `OSVersion` - User's macOS version
- `MachineName` - User's computer name
- `SessionId` - Unique ID per app session
- `Environment` - "Debug" or "Production"

### 🔒 Safe & Private

- Only sends log messages you explicitly write
- No automatic PII collection
- Fails silently if Seq is unreachable
- Easy to disable for production

### ⚡ Efficient

- Batches 10-20 events before sending (configurable)
- Flushes at least every 5-10 seconds (configurable)
- Small memory footprint
- Uses standard URLSession

## Production Considerations

### For Beta Testing

1. Deploy Seq to a cloud server (AWS, DigitalOcean, etc.)
2. Enable HTTPS (use nginx/Caddy)
3. Generate an API key in Seq
4. Update `SeqConfiguration` with your server URL and API key
5. Build and distribute to beta testers

### For App Store Release

Either:

- Set `SeqConfiguration.isEnabled = false`
- Or use `BetaConfiguration.betaFeaturesEnabled` to auto-disable

### Optional: User Opt-In

Use `BetaConfiguration` to make Seq opt-in:

```swift
// In AboutView, add:
Toggle("Join Beta Program", isOn: $betaOptIn)
    .help("Send diagnostic logs to help improve volumeHUD")

// In AppDelegate:
Task {
    if BetaConfiguration.seqLoggingEnabled {
        logger = await SeqConfiguration.createLogger()
    } else {
        logger = PolyLog()
    }
}
```

## Example Seq Queries

Once logs are flowing, try these queries in Seq:

```sql
-- All errors in last hour
Level = 'Error' and @Timestamp > Now() - 1h

-- Volume changes
@Message like '%volume%'

-- Specific version
Version = '2.0.0'

-- Brightness issues
@Message like '%brightness%' and Level in ['Error', 'Warning']

-- Track user sessions
SessionId = 'abc-123'
```

## Architecture Design Notes

### Why extend PolyLog vs create separate logger?

- **Zero changes to existing code** - All your `logger.info()` calls work unchanged
- **Portable** - You can use this in other projects that use PolyLog
- **Opt-in** - Pass `nil` for seqSink to disable

### Why use an Actor for SeqSink?

- **Thread-safe** by design (Swift 6 concurrency)
- **Async by default** - Never blocks
- **Proper isolation** - No data races possible

### Why CLEF format?

- **Native Seq format** - No server-side parsing needed
- **Efficient** - Newline-delimited JSON is simple and fast
- **Structured** - Each event is a proper JSON object with properties

### Why batch logs?

- **Reduces network overhead** - 1 request for 20 logs vs 20 requests
- **Better performance** - Less HTTP overhead
- **Configurable** - Tune based on your needs

## Common Issues

**Logs not appearing?**

- Check Seq is running: `curl http://localhost:5341/api/events/raw`
- Check firewall rules
- Verify API key
- Look for errors in Console.app

**Too many logs?**

- Reduce `includeDebug` to `false` in production
- Filter by level in Seq UI
- Adjust batch size/flush interval

**Privacy concerns?**

- Review what you're logging
- Don't log user data, passwords, etc.
- Make Seq opt-in for production
- Add privacy policy if needed

## Next Steps

1. ✅ Test locally with Docker Seq
2. ✅ Integrate into AppDelegate (choose Option A or B)
3. ✅ Test with your app
4. ⏳ Deploy Seq server for beta
5. ⏳ Update SeqConfiguration with production URL
6. ⏳ Build and distribute beta
7. ⏳ Watch logs flow in!

## Questions?

The implementation is fully commented and follows Swift 6 best practices. Check out:

- `SeqSink.swift` - The core implementation
- `PolyLog.swift` - Extended logging
- `SEQ_SETUP.md` - Detailed setup guide
- `INTEGRATION_EXAMPLE.swift` - Code examples

---

Built with ❤️ for better beta testing and debugging!

---

```swift
// This file shows a minimal example of integrating Seq into your existing AppDelegate
// This is NOT meant to be added to your project - it's just a reference!

import AppKit
import Foundation
import PolyKit
import SwiftUI

// MARK: - AppDelegate

// EXAMPLE: Minimal changes to enable Seq logging

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // CHANGE 1: Make logger optional initially, initialize async
    var logger: PolyLog!

    var volumeMonitor: VolumeMonitor!
    var brightnessMonitor: BrightnessMonitor!
    var hudController: HUDController!
    var aboutWindow: NSPanel?

    func applicationDidFinishLaunching(_: Notification) {
        // CHANGE 2: Initialize logger with Seq support
        // This wraps your existing initialization in a Task
        Task {
            // Create logger with Seq
            self.logger = await SeqConfiguration.createLogger()

            // Log startup (now with Seq!)
            self.logger.info("volumeHUD starting with Seq logging enabled")

            // Continue with normal initialization
            self.continueInitialization()
        }
    }

    // CHANGE 3: Extract rest of initialization into separate method
    private func continueInitialization() {
        let isDevEnvironment = isRunningInDevEnvironment()
        if isDevEnvironment { return }

        if let otherInstancePath = checkForOtherInstances() {
            showConflictingInstanceAlert(otherPath: otherInstancePath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
            return
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self

        volumeMonitor = VolumeMonitor(isPreviewMode: false)
        brightnessMonitor = BrightnessMonitor(isPreviewMode: false)
        hudController = HUDController(isPreviewMode: false)

        // ... rest of your existing code
    }

    // Rest of your existing AppDelegate code stays exactly the same!
    // The logger.debug(), logger.info() etc calls all work as before
    // but now also stream to Seq

    private func isRunningInDevEnvironment() -> Bool {
        // ... your existing implementation
        false
    }

    private func checkForOtherInstances() -> String? {
        // ... your existing implementation
        nil
    }

    private func showConflictingInstanceAlert(otherPath _: String) {
        // ... your existing implementation
    }
}

// MARK: - AppDelegateShared

// ALTERNATIVE: Shared logger approach (simpler but more invasive)
//
// If you want to avoid making every component wait for async logger init,
// you can use a shared logger pattern:

@MainActor
class AppDelegateShared: NSObject, NSApplicationDelegate {
    // Shared logger available to all components
    static var sharedLogger: PolyLog!

    func applicationDidFinishLaunching(_: Notification) {
        Task {
            // Initialize shared logger once
            Self.sharedLogger = await SeqConfiguration.createLogger()

            // Now all components can use AppDelegate.sharedLogger
            Self.sharedLogger.info("Starting with shared Seq logger")

            continueInitialization()
        }
    }

    private func continueInitialization() {
        // Your normal init code
    }
}

// Then in VolumeMonitor, BrightnessMonitor, etc:
//
// class VolumeMonitor {
//     var logger: PolyLog { AppDelegate.sharedLogger }
//     // ... rest of class
// }
//
// This avoids needing to pass logger around or async-init everywhere

// COMPARISON OF APPROACHES:
//
// 1. Async init per component (shown first)
//    + Keeps components independent
//    + Each can have different logger config
//    - Requires Task { } wrapper in each init
//    - Slight complexity in initialization order
//
// 2. Shared logger (shown second)
//    + Simplest integration
//    + No async init needed in components
//    + Single source of truth
//    - Global state (computed property avoids most issues)
//    - All components share same logger instance
//
// For beta testing, I'd recommend approach #2 (shared logger)
// For production architecture, approach #1 is more flexible
```
