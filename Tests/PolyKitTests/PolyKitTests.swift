//
//  PolyKitTests.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

@testable import PolyBase
@testable import PolyKit
@testable import PolyMedia
import Testing

// MARK: - PolyKitTests

/// Smoke tests to ensure all public APIs compile and link correctly.
/// These don't test functionality deeply - they just force the compiler to validate
/// that the library actually works when consumed as a dependency.
struct PolyKitTests {
    // MARK: - PolyKit Core

    @Test func deviceIdentification() {
        // Reference Device API
        _ = Device.isPhone
        _ = Device.isPad
        _ = Device.isMac

        #expect(Device.isPhone || Device.isPad || Device.isMac, "One device type must be true")
    }

    @Test func loggingAPI() {
        // Test log group creation
        _ = LogGroup("TestGroup", emoji: "🧪")

        // Verify log levels and entries exist
        _ = LogLevel.debug
        _ = LogLevel.info
        _ = LogLevel.warning
        _ = LogLevel.error
        _ = LogLevel.fault

        _ = LogEntry.self
        _ = LogBuffer.self
    }

    @Test func ulidGeneration() {
        // Test ULID API
        let ulidString = ULID.generate(for: Date())
        #expect(ulidString.count == 26, "ULID should be 26 characters")

        // Test ULID generator
        let generator = ULIDGenerator.shared
        let generatedID = generator.next()
        #expect(generatedID.count == 26, "Generated ULID should be 26 characters")
    }

    // MARK: - PolyBase Sync Engine

    @Test func polyBaseConfigTypes() {
        // Just reference the core types to ensure they compile
        // We're not testing functionality, just API surface
        _ = PolyBaseConfig.self
        _ = (any PolySyncable).self
        _ = VersionState.self
        _ = ReconcileAction.self
    }

    @Test func polyBaseClientTypes() {
        // Reference client and auth types
        _ = PolyBaseClient.self
        _ = PolyBaseAuth.self
        _ = PolyBaseStorage.self
    }

    @Test func polyBaseEngineTypes() {
        // Reference sync engine components
        _ = PolySyncCoordinator.self
        _ = PolyPushEngine.self
        _ = PolyPullEngine.self
        _ = PolyReconciliationService.self
        _ = PolyHealingService.self
    }

    @Test func polyBaseRealtimeTypes() {
        // Reference realtime components
        _ = PolyBaseRealtimeCoordinator.self
        _ = PolyRealtimeSubscriber.self
    }

    @Test func polyBaseUtilityTypes() {
        // Reference utility types
        _ = PolyBaseEchoTracker.self
        _ = PolyBaseOfflineQueue.self
        _ = PolyBaseDebouncedNotifier.self
        _ = PolyBaseEncryption.self
    }

    // MARK: - PolyMedia

    @Test func polyMediaPlayerTypes() {
        // Reference player types
        _ = PlayerCore.self
        _ = (any Playable).self
    }

    @Test func polyMediaAudioTypes() {
        // Reference audio analysis types
        _ = AudioAnalyzer.self
        _ = AnimatedEqualizer.self
    }
}

// MARK: - Platform-Specific Smoke Tests

#if canImport(UIKit)
    import UIKit

    struct iOSSpecificTests {
        @Test func dataExplorerIOSTypes() {
            // Reference iOS DataExplorer types
            _ = iOSDataExplorerViewController.self
            _ = iOSDetailViewController.self
            _ = iOSBulkEditViewController.self
        }
    }
#endif

#if canImport(AppKit)
    import AppKit

    struct macOSSpecificTests {
        @Test func dataExplorerMacOSTypes() {
            // Reference macOS DataExplorer types
            _ = macOSPolyDataExplorerViewController.self
            _ = macOSPolyDataExplorerDetailPanel.self
            _ = macOSBulkEditPanel.self
            _ = macOSPolyDataExplorerSplitViewController.self
            _ = macOSPolyDataExplorerWindowController.self
        }
    }
#endif
