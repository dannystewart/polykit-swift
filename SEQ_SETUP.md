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
