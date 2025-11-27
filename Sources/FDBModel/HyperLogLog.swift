import Foundation

/// HyperLogLog cardinality estimator
///
/// Memory-efficient probabilistic cardinality estimation using the HyperLogLog algorithm.
/// Uses only ~12KB memory (16,384 registers × 6 bits) with approximately ±2% accuracy.
///
/// **Algorithm**:
/// HyperLogLog works by hashing each element and observing the pattern of leading zeros
/// in the hash. The maximum number of leading zeros observed is used to estimate the
/// cardinality. Multiple registers (2^14 = 16,384) are used for accuracy.
///
/// **Usage**:
/// ```swift
/// var hll = HyperLogLog()
///
/// // Add values
/// for user in users {
///     hll.add(.string(user.email))
/// }
///
/// // Get estimated cardinality
/// let uniqueCount = hll.cardinality()
/// print("Estimated unique emails: \(uniqueCount)")
///
/// // Merge multiple estimators
/// var hll2 = HyperLogLog()
/// // ... add values to hll2
/// hll.merge(hll2)
/// ```
///
/// **Persistence**:
/// ```swift
/// // Save to FDB
/// let data = try JSONEncoder().encode(hll)
/// transaction.setValue(Array(data), for: key)
///
/// // Load from FDB
/// let data = try await transaction.getValue(for: key)
/// let hll = try JSONDecoder().decode(HyperLogLog.self, from: Data(data))
/// ```
///
/// **References**:
/// - P. Flajolet et al., "HyperLogLog: the analysis of a near-optimal cardinality estimation algorithm"
/// - http://algo.inria.fr/flajolet/Publications/FlFuGaMe07.pdf
public struct HyperLogLog: Sendable, Codable, Hashable {
    // MARK: - Constants

    /// Number of registers (2^14 = 16,384)
    /// More registers = better accuracy but more memory
    private static let numRegisters = 16384

    /// Number of bits for register index (14 bits for 16,384 registers)
    private static let indexBits = 14

    /// Mask for extracting register index
    private static let indexMask: UInt64 = (1 << indexBits) - 1

    /// Alpha constant for bias correction
    /// alpha_m = 0.7213 / (1 + 1.079 / m) where m = numRegisters
    private static let alpha: Double = 0.7213 / (1.0 + 1.079 / Double(numRegisters))

    // MARK: - Properties

    /// Registers storing the maximum number of leading zeros + 1 for each bucket
    /// Each register stores values 0-63 (6 bits), but we use UInt8 for simplicity
    private var registers: [UInt8]

    // MARK: - Initialization

    /// Initialize a new HyperLogLog estimator
    public init() {
        self.registers = Array(repeating: 0, count: Self.numRegisters)
    }

    /// Initialize from existing registers (for deserialization)
    internal init(registers: [UInt8]) {
        precondition(registers.count == Self.numRegisters, "Invalid register count")
        self.registers = registers
    }

    // MARK: - Public API

    /// Add a value to the estimator
    ///
    /// The value is hashed and the hash is used to update the appropriate register.
    ///
    /// - Parameter value: The value to add
    public mutating func add(_ value: FieldValue) {
        let hash = value.stableHash()
        addHash(hash)
    }

    /// Add a pre-computed hash to the estimator
    ///
    /// Useful when you already have a hash value from another source.
    ///
    /// - Parameter hash: 64-bit hash value
    public mutating func addHash(_ hash: UInt64) {
        // Use lower bits for register index
        let registerIndex = Int(hash & Self.indexMask)

        // Count leading zeros in remaining bits (upper 50 bits after using 14 for index)
        let remainingBits = hash >> Self.indexBits
        let effectiveBits = 64 - Self.indexBits  // 50 bits remaining

        let leadingZeros: Int
        if remainingBits == 0 {
            // All remaining bits are zero
            leadingZeros = effectiveBits
        } else {
            // leadingZeroBitCount counts from MSB of 64-bit value
            // After right shift by indexBits, the upper indexBits positions are 0
            // We need leading zeros within the effective 50 bits
            leadingZeros = remainingBits.leadingZeroBitCount - Self.indexBits
        }

        // rho(w) = position of leftmost 1-bit, which is leadingZeros + 1
        // Clamp to maximum value that fits in UInt8, minimum 1
        let rho = UInt8(min(max(leadingZeros + 1, 1), 255))

        // Update register with maximum
        registers[registerIndex] = max(registers[registerIndex], rho)
    }

    /// Estimate the cardinality (number of distinct elements)
    ///
    /// - Returns: Estimated number of distinct elements added
    public func cardinality() -> Int64 {
        // Raw HyperLogLog estimate: alpha * m^2 / sum(2^(-M[j]))
        let harmonicMean = registers.reduce(0.0) { sum, register in
            sum + pow(2.0, -Double(register))
        }

        let m = Double(Self.numRegisters)
        var estimate = Self.alpha * m * m / harmonicMean

        // Small range correction (linear counting)
        // When estimate < 2.5 * m, use linear counting for better accuracy
        if estimate <= 2.5 * m {
            // Count registers that are still zero
            let zeroCount = registers.filter { $0 == 0 }.count
            if zeroCount > 0 {
                // Linear counting: m * ln(m / V) where V = number of zero registers
                estimate = m * log(m / Double(zeroCount))
            }
        }

        // Large range correction
        // When estimate > 1/30 * 2^32, apply correction for hash collisions
        let threshold = (1.0 / 30.0) * pow(2.0, 32.0)
        if estimate > threshold {
            estimate = -pow(2.0, 32.0) * log(1.0 - estimate / pow(2.0, 32.0))
        }

        return Int64(estimate.rounded())
    }

    /// Merge another HyperLogLog estimator into this one
    ///
    /// After merging, this estimator will contain the union of both sets.
    /// The merged cardinality will be approximately the cardinality of
    /// the union of elements from both estimators.
    ///
    /// - Parameter other: Another HyperLogLog estimator
    public mutating func merge(_ other: HyperLogLog) {
        precondition(registers.count == other.registers.count,
                     "Cannot merge HyperLogLog with different register counts")

        for i in 0..<Self.numRegisters {
            registers[i] = max(registers[i], other.registers[i])
        }
    }

    /// Create a new HyperLogLog by merging two estimators
    ///
    /// - Parameters:
    ///   - lhs: First estimator
    ///   - rhs: Second estimator
    /// - Returns: New estimator containing the union
    public static func merged(_ lhs: HyperLogLog, _ rhs: HyperLogLog) -> HyperLogLog {
        var result = lhs
        result.merge(rhs)
        return result
    }

    /// Reset the estimator to empty state
    public mutating func reset() {
        registers = Array(repeating: 0, count: Self.numRegisters)
    }

    /// Check if the estimator is empty (no elements added)
    public var isEmpty: Bool {
        registers.allSatisfy { $0 == 0 }
    }

    // MARK: - Statistics

    /// Get the estimated relative error
    ///
    /// For HyperLogLog with 16,384 registers, the standard error is approximately 0.81%.
    ///
    /// - Returns: Estimated relative error (e.g., 0.0081 for 0.81%)
    public var estimatedRelativeError: Double {
        // Standard error = 1.04 / sqrt(m)
        return 1.04 / sqrt(Double(Self.numRegisters))
    }

    /// Get memory usage in bytes
    ///
    /// - Returns: Number of bytes used by registers
    public var memorySizeInBytes: Int {
        return Self.numRegisters  // 1 byte per register
    }
}

// MARK: - Codable

extension HyperLogLog {
    enum CodingKeys: String, CodingKey {
        case registers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try to decode as Data first (more compact)
        if let data = try? container.decode(Data.self, forKey: .registers) {
            self.registers = Array(data)
        } else {
            // Fall back to array of UInt8
            self.registers = try container.decode([UInt8].self, forKey: .registers)
        }

        guard registers.count == Self.numRegisters else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [CodingKeys.registers],
                    debugDescription: "Invalid register count: expected \(Self.numRegisters), got \(registers.count)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Encode as Data for compactness
        try container.encode(Data(registers), forKey: .registers)
    }
}

// MARK: - CustomStringConvertible

extension HyperLogLog: CustomStringConvertible {
    public var description: String {
        let card = cardinality()
        let error = estimatedRelativeError * 100
        return "HyperLogLog(cardinality: ~\(card), error: ±\(String(format: "%.2f", error))%)"
    }
}
