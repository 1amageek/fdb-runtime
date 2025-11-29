import struct Foundation.Date

/// ULID (Universally Unique Lexicographically Sortable Identifier)
///
/// A 128-bit identifier that is:
/// - Lexicographically sortable
/// - Time-ordered (first 48 bits are timestamp)
/// - Randomly generated (last 80 bits are random)
/// - Case-insensitive and URL-safe
///
/// **Format**: `TTTTTTTTTTRRRRRRRRRRRRRRRRR` (26 characters, Crockford's Base32)
/// - `T`: Timestamp (10 chars, 48 bits, milliseconds since Unix epoch)
/// - `R`: Randomness (16 chars, 80 bits)
///
/// **Usage**:
/// ```swift
/// let ulid = ULID()
/// print(ulid.ulidString)  // "01HXK5M3N2P4Q5R6S7T8U9V0WX"
/// ```
///
/// **Reference**: https://github.com/ulid/spec
public struct ULID: Sendable, Hashable, Codable, CustomStringConvertible {

    /// The raw 128-bit value (16 bytes)
    public let rawValue: (UInt64, UInt64)

    /// Crockford's Base32 encoding alphabet
    private static let encodingChars: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Decoding map for Crockford's Base32
    private static let decodingMap: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, char) in encodingChars.enumerated() {
            map[char] = UInt8(index)
            map[Character(char.lowercased())] = UInt8(index)
        }
        // Handle commonly confused characters
        map["I"] = 1  // I -> 1
        map["i"] = 1
        map["L"] = 1  // L -> 1
        map["l"] = 1
        map["O"] = 0  // O -> 0
        map["o"] = 0
        return map
    }()

    /// Creates a new ULID with current timestamp and random data
    public init() {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        // Generate 10 random bytes using Swift's cross-platform RNG
        var rng = SystemRandomNumberGenerator()
        var randomBytes = [UInt8](repeating: 0, count: 10)
        for i in 0..<10 {
            randomBytes[i] = UInt8.random(in: 0...255, using: &rng)
        }

        // First 64 bits: timestamp (48 bits) + random (16 bits)
        let high = (timestamp << 16) | (UInt64(randomBytes[0]) << 8) | UInt64(randomBytes[1])

        // Last 64 bits: random (64 bits)
        let low = randomBytes[2...9].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }

        self.rawValue = (high, low)
    }

    /// Creates a ULID from a string representation
    ///
    /// - Parameter string: A 26-character Crockford's Base32 encoded string
    /// - Returns: nil if the string is invalid
    public init?(ulidString string: String) {
        guard string.count == 26 else { return nil }

        let chars = Array(string)
        var high: UInt64 = 0
        var low: UInt64 = 0

        // Decode first 10 characters (50 bits -> high 48 bits + 2 bits)
        for i in 0..<10 {
            guard let value = Self.decodingMap[chars[i]] else { return nil }
            high = (high << 5) | UInt64(value)
        }

        // Decode next 6 characters (30 bits -> remaining high bits + some low bits)
        var mid: UInt64 = 0
        for i in 10..<16 {
            guard let value = Self.decodingMap[chars[i]] else { return nil }
            mid = (mid << 5) | UInt64(value)
        }

        // Decode last 10 characters (50 bits -> low bits)
        for i in 16..<26 {
            guard let value = Self.decodingMap[chars[i]] else { return nil }
            low = (low << 5) | UInt64(value)
        }

        // Combine: high gets top 64 bits, low gets bottom 64 bits
        // Total 130 bits encoded, but ULID is 128 bits
        // First 10 chars = 50 bits (timestamp 48 + 2 random)
        // Next 6 chars = 30 bits
        // Last 10 chars = 50 bits
        // We need to reconstruct 128 bits

        // Simpler approach: re-encode and validate
        let combined = (high << 14) | (mid >> 16)
        let lowPart = ((mid & 0xFFFF) << 48) | (low >> 2)

        self.rawValue = (combined, lowPart)
    }

    /// Creates a ULID from raw bytes
    ///
    /// - Parameter bytes: 16 bytes representing the ULID
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "ULID requires exactly 16 bytes")

        let high = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let low = bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }

        self.rawValue = (high, low)
    }

    /// The ULID as a 26-character string (Crockford's Base32)
    public var ulidString: String {
        var result = [Character](repeating: "0", count: 26)
        let (high, low) = rawValue

        // Encode 128 bits into 26 characters (5 bits each, 130 bits capacity)
        // We have 128 bits, so 2 bits of padding at the start

        var value = high
        // First 10 characters from high 50 bits
        for i in stride(from: 9, through: 0, by: -1) {
            result[i] = Self.encodingChars[Int(value & 0x1F)]
            value >>= 5
        }

        // Middle characters
        value = ((high & 0x3FFF) << 16) | (low >> 48)
        for i in stride(from: 15, through: 10, by: -1) {
            result[i] = Self.encodingChars[Int(value & 0x1F)]
            value >>= 5
        }

        // Last 10 characters from low 50 bits
        value = low & 0xFFFFFFFFFFFF  // Bottom 48 bits + some
        for i in stride(from: 25, through: 16, by: -1) {
            result[i] = Self.encodingChars[Int(value & 0x1F)]
            value >>= 5
        }

        return String(result)
    }

    /// The ULID as raw bytes (16 bytes)
    public var bytes: [UInt8] {
        let (high, low) = rawValue
        var result = [UInt8](repeating: 0, count: 16)

        for i in 0..<8 {
            result[7 - i] = UInt8(high >> (i * 8) & 0xFF)
        }
        for i in 0..<8 {
            result[15 - i] = UInt8(low >> (i * 8) & 0xFF)
        }

        return result
    }

    /// The timestamp component (milliseconds since Unix epoch)
    public var timestamp: UInt64 {
        rawValue.0 >> 16
    }

    /// The timestamp as a Date
    public var date: Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        ulidString
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let ulid = ULID(ulidString: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ULID string: \(string)"
            )
        }
        self = ulid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ulidString)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.0)
        hasher.combine(rawValue.1)
    }

    // MARK: - Equatable

    public static func == (lhs: ULID, rhs: ULID) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

// MARK: - Comparable

extension ULID: Comparable {
    public static func < (lhs: ULID, rhs: ULID) -> Bool {
        if lhs.rawValue.0 != rhs.rawValue.0 {
            return lhs.rawValue.0 < rhs.rawValue.0
        }
        return lhs.rawValue.1 < rhs.rawValue.1
    }
}

// MARK: - ExpressibleByStringLiteral

extension ULID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        guard let ulid = ULID(ulidString: value) else {
            fatalError("Invalid ULID string literal: \(value)")
        }
        self = ulid
    }
}
