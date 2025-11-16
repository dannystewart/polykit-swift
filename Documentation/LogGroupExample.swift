//
//  LogGroupExample.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import PolyKit

// MARK: - Define Your App's Log Groups

extension LogGroup {
    static let networking: LogGroup = .init("networking")
    static let database: LogGroup = .init("database")
    static let ui: LogGroup = .init("ui")
    static let authentication: LogGroup = .init("auth")
}

// MARK: - Example Usage

func demonstrateLogGroups() {
    let logger = PolyLog()

    print("\n=== Example 1: Basic Group Logging ===\n")

    // Regular logging (no group - always prints)
    logger.info("Application started")

    // Group-tagged logging
    logger.debug("Initializing network layer", group: .networking)
    logger.debug("Database connection established", group: .database)
    logger.debug("UI views loaded", group: .ui)

    print("\n=== Example 2: Disabling Noisy Groups ===\n")

    // Disable some noisy groups
    logger.disableGroup(.networking)
    logger.disableGroup(.database)

    logger.info("Processing user request...")
    logger.debug("HTTP GET /api/data", group: .networking) // Won't print
    logger.debug("SELECT * FROM users", group: .database) // Won't print
    logger.debug("Updating view hierarchy", group: .ui) // Will print
    logger.info("Request completed") // Will print (no group)

    print("\n=== Example 3: Re-enabling Specific Groups ===\n")

    // Need to debug networking? Re-enable it
    logger.enableGroup(.networking)

    logger.debug("Sending API request", group: .networking) // Now prints
    logger.debug("Cache lookup", group: .database) // Still disabled

    print("\n=== Example 4: Batch Operations ===\n")

    // Disable multiple groups at once
    logger.disableGroups([.networking, .ui])

    logger.debug("Network activity", group: .networking) // Won't print
    logger.debug("UI update", group: .ui) // Won't print

    // Enable multiple groups
    logger.enableGroups([.networking, .database, .ui])

    logger.debug("All groups enabled!", group: .networking)

    print("\n=== Example 5: Conditional Logging ===\n")

    // Only perform expensive logging if group is enabled
    if logger.isGroupEnabled(.database) {
        // This is useful for expensive operations
        let detailedReport = buildExpensiveReport()
        logger.debug(detailedReport, group: .database)
    }

    print("\n=== Example 6: Group Management ===\n")

    // Check status
    logger.disableGroup(.networking)
    logger.disableGroup(.ui)

    let disabled = logger.getDisabledGroups()
    print("Currently disabled groups: \(disabled.map(\.identifier))")

    // Enable all at once
    logger.enableAllGroups()
    print("All groups enabled")
}

// MARK: - Real-World Example: Feature Development

func developNewFeature() {
    let logger = PolyLog()

    print("\n=== Real-World: Developing Authentication Feature ===\n")

    // During feature development, enable only relevant groups
    logger.disableGroups([.database, .networking])
    logger.enableGroup(.authentication)

    logger.info("Starting authentication flow")
    logger.debug("Token validation started", group: .authentication)
    logger.debug("Fetching user credentials from API", group: .networking) // Silent
    logger.debug("Checking user table", group: .database) // Silent
    logger.debug("Token validated successfully", group: .authentication)
    logger.info("User authenticated")
}

// MARK: - Real-World Example: Production Configuration

func configureForProduction() {
    let logger = PolyLog()

    print("\n=== Real-World: Production Configuration ===\n")

    #if DEBUG
        // Development: Show everything
        logger.enableAllGroups()
        logger.info("Development mode: All logging enabled")
    #else
        // Production: Only critical logs (those without groups)
        // and specific groups you want to monitor
        logger.disableGroups([.database, .ui])
        logger.enableGroup(.authentication) // Keep auth logs for security
        logger.info("Production mode: Filtered logging enabled")
    #endif

    logger.debug("Database query", group: .database) // Filtered in production
    logger.error("Critical error occurred") // Always shows
    logger.debug("Login attempt", group: .authentication) // Shows in production
}

// MARK: - Helper Functions

private func buildExpensiveReport() -> String {
    // Simulates building a complex diagnostic report
    "Database Statistics: 1000 queries, 50ms avg response time"
}

// MARK: - Main Entry Point

// Uncomment to run examples:
// demonstrateLogGroups()
// developNewFeature()
// configureForProduction()
