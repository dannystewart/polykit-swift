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
