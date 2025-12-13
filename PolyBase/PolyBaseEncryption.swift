//
//  PolyBaseEncryption.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import CryptoKit
import Foundation

// MARK: - PolyBaseEncryption

/// Handles client-side encryption for Supabase data.
///
/// Uses AES-GCM encryption with per-user keys derived from app secret + user ID.
/// This ensures user data is unreadable even when browsing the database directly.
///
/// Usage:
/// ```swift
/// // Configure with your app's encryption secret
/// PolyBaseEncryption.configure(secret: "your-secret-key")
///
/// // Optionally bypass encryption for admin users (useful for debugging)
/// PolyBaseEncryption.shared.addAdminUser(UUID(uuidString: "...")!)
///
/// // Encrypt/decrypt
/// if let encrypted = PolyBaseEncryption.shared.encrypt("sensitive data", forUserID: userID) {
///     // Store encrypted in database
/// }
///
/// if let decrypted = PolyBaseEncryption.shared.decrypt(encrypted, forUserID: userID) {
///     // Use decrypted value
/// }
/// ```
public final class PolyBaseEncryption: @unchecked Sendable {
    /// Shared instance. Configure with `configure(secret:)` before use.
    /// Configured once at app startup before concurrent access.
    public private(set) nonisolated(unsafe) static var shared: PolyBaseEncryption?

    private let appSecret: Data
    private var adminUserIDs: Set<UUID> = []
    private let lock: NSLock = .init()

    private init(secret: String) {
        guard let secretData = secret.data(using: .utf8), !secret.isEmpty else {
            fatalError("PolyBaseEncryption: Secret cannot be empty")
        }
        appSecret = secretData
    }

    // MARK: - Configuration

    /// Configure encryption with your app's secret.
    ///
    /// - Parameter secret: A secret string used for key derivation. Should be stored securely
    ///                     (e.g., in a config file not committed to source control).
    @discardableResult
    public static func configure(secret: String) -> PolyBaseEncryption {
        let instance = PolyBaseEncryption(secret: secret)
        shared = instance
        polyInfo("PolyBase: Encryption configured")
        return instance
    }

    /// Returns the configured instance, or throws if not configured.
    public static func requireEncryption() throws -> PolyBaseEncryption {
        guard let shared else {
            throw PolyBaseError.missingConfiguration("Encryption not configured. Call PolyBaseEncryption.configure(secret:) first.")
        }
        return shared
    }

    // MARK: - Admin Users

    /// Add a user ID that should bypass encryption (data stored in plaintext).
    /// Useful for admin accounts where you want to inspect data directly in the database.
    public func addAdminUser(_ userID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        adminUserIDs.insert(userID)
        polyDebug("PolyBase: Added admin user (encryption bypass)")
    }

    /// Remove a user from the admin list.
    public func removeAdminUser(_ userID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        adminUserIDs.remove(userID)
    }

    /// Check if a user is an admin (bypasses encryption).
    public func isAdminUser(_ userID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return adminUserIDs.contains(userID)
    }

    // MARK: - Encryption

    /// Encrypt a string for a specific user.
    ///
    /// - Parameters:
    ///   - plaintext: The string to encrypt.
    ///   - userID: The user's ID (used in key derivation).
    /// - Returns: A base64-encoded string prefixed with "enc:" for identification,
    ///            or the original plaintext for admin users, or `nil` on failure.
    public func encrypt(_ plaintext: String, forUserID userID: UUID) -> String? {
        guard !plaintext.isEmpty else { return plaintext }

        // Skip encryption for admin users
        if isAdminUser(userID) {
            return plaintext
        }

        do {
            let key = deriveKey(forUserID: userID)
            let plaintextData = Data(plaintext.utf8)

            // Generate random nonce
            let nonce = AES.GCM.Nonce()

            // Encrypt
            let sealedBox = try AES.GCM.seal(plaintextData, using: key, nonce: nonce)

            // Combine nonce + ciphertext + tag into single data
            guard let combined = sealedBox.combined else { return nil }

            // Return with prefix so we know it's encrypted
            return "enc:" + combined.base64EncodedString()
        } catch {
            polyError("PolyBase: Encryption failed: \(error)")
            return nil
        }
    }

    /// Decrypt a string for a specific user.
    ///
    /// - Parameters:
    ///   - ciphertext: The encrypted string (with "enc:" prefix) or plaintext.
    ///   - userID: The user's ID (used in key derivation).
    /// - Returns: The decrypted string, or the original if not encrypted, or `nil` on failure.
    public func decrypt(_ ciphertext: String, forUserID userID: UUID) -> String? {
        // If not encrypted, return as-is (for backwards compatibility during migration)
        guard ciphertext.hasPrefix("enc:") else { return ciphertext }

        do {
            let key = deriveKey(forUserID: userID)

            // Remove prefix and decode base64
            let base64String = String(ciphertext.dropFirst(4))
            guard let combined = Data(base64Encoded: base64String) else {
                polyError("PolyBase: Failed to decode base64 ciphertext")
                return nil
            }

            // Decrypt
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)

            return String(data: decryptedData, encoding: .utf8)
        } catch {
            polyError("PolyBase: Decryption failed: \(error)")
            return nil
        }
    }

    /// Check if a string is encrypted (has our prefix).
    public func isEncrypted(_ text: String) -> Bool {
        text.hasPrefix("enc:")
    }

    // MARK: - Key Derivation

    /// Derive a unique encryption key for a user.
    /// Uses HKDF with app secret as input key material and user ID as salt.
    private func deriveKey(forUserID userID: UUID) -> SymmetricKey {
        let salt = Data(userID.uuidString.utf8)
        let info = Data("supabase-encryption".utf8)

        // Use HKDF to derive a 256-bit key
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: appSecret),
            salt: salt,
            info: info,
            outputByteCount: 32,
        )
    }
}
