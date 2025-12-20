//
//  ULID.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Security

// MARK: - ULID

/// ULID (Universally Unique Lexicographically Sortable Identifier).
///
/// This implementation generates **Crockford Base32** ULIDs (26 chars) with:
/// - 48-bit millisecond timestamp
/// - 80-bit randomness
///
/// We use a monotonic generator within-process so multiple ULIDs generated in the
/// same millisecond remain strictly increasing (important for stable ordering).
public enum ULID {
    nonisolated static let length = 26

    private nonisolated static let alphabet: [UInt8] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    private nonisolated static let decodeTable: [Int8] = {
        // 256-entry lookup table for ASCII bytes -> 0...31 values (or -1 if invalid).
        var table = [Int8](repeating: -1, count: 256)

        func set(_ char: UInt8, _ value: Int8) {
            table[Int(char)] = value
        }

        // 0-9
        for (i, c) in Array("0123456789".utf8).enumerated() {
            set(c, Int8(i))
        }

        // Crockford alphabet (no I, L, O, U)
        for (i, c) in Array("ABCDEFGHJKMNPQRSTVWXYZ".utf8).enumerated() {
            set(c, Int8(10 + i))
        }

        // Accept lowercase too.
        for (i, c) in Array("abcdefghjkmnpqrstvwxyz".utf8).enumerated() {
            set(c, Int8(10 + i))
        }

        // Crockford ambiguous chars: accept i/l as 1, o as 0.
        set(105, 1) // 'i'
        set(73, 1) // 'I'
        set(108, 1) // 'l'
        set(76, 1) // 'L'
        set(111, 0) // 'o'
        set(79, 0) // 'O'

        return table
    }()

    /// Generate a ULID for a specific timestamp (non-monotonic).
    ///
    /// Prefer `ULIDGenerator.shared.next()` for normal ID generation, since that
    /// guarantees monotonicity within a process. This API is intended for imports
    /// and other cases where you want the ULID timestamp to match a chosen `Date`.
    public nonisolated static func generate(for date: Date) -> String {
        let timestampMs = UInt64(max(0, date.timeIntervalSince1970) * 1000.0)

        var random = [UInt8](repeating: 0, count: 10)
        let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")

        return encode(timestampMs: timestampMs, random: random)
    }

    /// Decode a ULID string into its timestamp (ms) and 10-byte random component.
    ///
    /// Returns nil if the string is not valid Crockford Base32 ULID.
    public nonisolated static func decode(_ ulid: String) -> (timestampMs: UInt64, random: [UInt8])? {
        guard ulid.utf8.count == 26 else { return nil }

        // Parse base32 digits into a 130-bit value, stored in 17 bytes (big-endian).
        var acc = [UInt8](repeating: 0, count: 17)

        for c in ulid.utf8 {
            let v = decodeTable[Int(c)]
            guard v >= 0 else { return nil }
            shiftLeft(&acc, by: 5)
            acc[acc.count - 1] |= UInt8(v)
        }

        // The ULID spec prefixes two leading 0 bits, so the 130-bit value fits in 128 bits.
        // That means the highest byte should be 0.
        guard acc[0] == 0 else { return nil }

        let bytes = Array(acc.suffix(16))
        guard bytes.count == 16 else { return nil }

        var timestampMs: UInt64 = 0
        for i in 0 ..< 6 {
            timestampMs = (timestampMs << 8) | UInt64(bytes[i])
        }
        let random = Array(bytes[6 ..< 16])
        return (timestampMs, random)
    }

    /// Encode timestamp + randomness into a ULID string.
    nonisolated static func encode(timestampMs: UInt64, random: [UInt8]) -> String {
        precondition(random.count == 10, "ULID random component must be 10 bytes")

        var bytes = [UInt8](repeating: 0, count: 16)

        // 48-bit timestamp, big-endian
        bytes[0] = UInt8((timestampMs >> 40) & 0xFF)
        bytes[1] = UInt8((timestampMs >> 32) & 0xFF)
        bytes[2] = UInt8((timestampMs >> 24) & 0xFF)
        bytes[3] = UInt8((timestampMs >> 16) & 0xFF)
        bytes[4] = UInt8((timestampMs >> 8) & 0xFF)
        bytes[5] = UInt8(timestampMs & 0xFF)

        // 80-bit random, big-endian as given
        for i in 0 ..< 10 {
            bytes[6 + i] = random[i]
        }

        // Encode 128 bits into 26 base32 chars by prefixing 2 leading zero bits (130 bits total).
        var output = [UInt8]()
        output.reserveCapacity(26)

        var buffer: UInt32 = 0
        var bitsLeft = 2 // prefix two 0 bits

        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8

            while bitsLeft >= 5 {
                let shift = bitsLeft - 5
                let index = Int((buffer >> shift) & 0x1F)
                output.append(alphabet[index])
                bitsLeft -= 5

                // Mask out consumed bits to keep buffer bounded.
                if bitsLeft == 0 {
                    buffer = 0
                } else {
                    buffer = buffer & ((1 << bitsLeft) - 1)
                }
            }
        }

        // With the 2-bit prefix, we should have emitted exactly 26 chars.
        precondition(output.count == 26, "ULID encoding produced \(output.count) chars")

        return String(decoding: output, as: UTF8.self)
    }

    private nonisolated static func shiftLeft(_ bytes: inout [UInt8], by bits: UInt16) {
        precondition(bits > 0 && bits < 8)
        var carry: UInt16 = 0
        for i in stride(from: bytes.count - 1, through: 0, by: -1) {
            let value = UInt16(bytes[i])
            let shifted = (value << bits) | carry
            bytes[i] = UInt8(shifted & 0xFF)
            carry = shifted >> 8
        }
    }
}

// MARK: - ULIDGenerator

/// Thread-safe monotonic ULID generator.
///
/// - Uses a lock to remain synchronous (no async/await call sites).
/// - Monotonic within a single process: if time does not advance, increments the 80-bit random payload.
public final class ULIDGenerator: Sendable {
    public nonisolated static let shared: ULIDGenerator = .init()

    private let lock: NSLock = .init()

    // Tell Swift we handle synchronization ourselves.
    private nonisolated(unsafe) var lastTimestampMs: UInt64 = 0
    private nonisolated(unsafe) var lastRandom: [UInt8] = Array(repeating: 0, count: 10)

    private nonisolated init() {}

    private nonisolated static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

    public nonisolated func next(date: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }

        let nowMs = UInt64(max(0, date.timeIntervalSince1970) * 1000.0)

        if nowMs > lastTimestampMs {
            lastTimestampMs = nowMs
            lastRandom = Self.randomBytes(count: 10)
        } else {
            // Clock skew backwards or multiple ULIDs in the same millisecond.
            // Keep timestamp constant and increment the random component.
            incrementRandom(&lastRandom)
        }

        return ULID.encode(timestampMs: lastTimestampMs, random: lastRandom)
    }

    /// Seed the monotonic generator from an existing ULID.
    ///
    /// This is used to ensure newly generated ULIDs sort *after* existing ones,
    /// even across app relaunches and clock skew.
    public nonisolated func seed(fromExistingMaxULID ulid: String) {
        guard let decoded = ULID.decode(ulid) else { return }

        lock.lock()
        defer { lock.unlock() }

        let shouldReplace: Bool = if decoded.timestampMs > lastTimestampMs {
            true
        } else if decoded.timestampMs < lastTimestampMs {
            false
        } else {
            // Same timestamp: compare random lexicographically.
            lastRandom.lexicographicallyPrecedes(decoded.random)
        }

        guard shouldReplace else { return }
        lastTimestampMs = decoded.timestampMs
        lastRandom = decoded.random
    }

    private nonisolated func incrementRandom(_ bytes: inout [UInt8]) {
        precondition(bytes.count == 10)

        // Treat as big-endian 80-bit integer and add 1.
        for i in stride(from: 9, through: 0, by: -1) {
            if bytes[i] == 0xFF {
                bytes[i] = 0
                continue
            }
            bytes[i] &+= 1
            return
        }

        // Overflow (extremely unlikely). Reseed.
        bytes = Self.randomBytes(count: 10)
    }
}
