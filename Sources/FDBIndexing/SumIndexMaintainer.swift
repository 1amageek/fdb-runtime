// SumIndexMaintainer.swift
// FDBIndexing - Sum aggregation index maintainer implementation
//
// Maintains sum indexes for summing numeric values by grouping keys.

import Foundation
import FoundationDB
import FDBModel
import FDBCore

/// Maintains sum aggregation indexes by grouping keys
///
/// **Key Structure**: `[subspace][groupKey...] = Int64/Double(sum)`
/// Last field in keyPaths is the value field; preceding fields are grouping keys.
///
/// **Supports**:
/// - Get sum by group key
/// - Atomic add on insert
/// - Atomic subtract on delete
/// - Atomic delta on update
///
/// **Usage**:
/// ```swift
/// let index = Index(
///     name: "Order_sum_by_customer",
///     kind: SumIndexKind(),
///     rootExpression: ConcatenateKeyExpression([
///         FieldKeyExpression(fieldName: "customerId"),
///         FieldKeyExpression(fieldName: "amount")
///     ]),
///     subspaceKey: "Order_sum_by_customer"
/// )
///
/// let maintainer = SumIndexMaintainer<Order>(
///     index: index,
///     subspace: indexSubspace
/// )
/// ```
public struct SumIndexMaintainer<Item: Persistable>: IndexMaintainer {
    // MARK: - Properties

    /// Index definition
    public let index: Index

    /// Subspace for index storage
    public let subspace: Subspace

    /// ID expression for extracting item's unique identifier
    public let idExpression: KeyExpression

    // MARK: - Initialization

    /// Create a SumIndexMaintainer
    ///
    /// - Parameters:
    ///   - index: Index definition
    ///   - subspace: Subspace for index storage
    ///   - idExpression: Expression for extracting item's unique identifier
    public init(index: Index, subspace: Subspace, idExpression: KeyExpression) {
        self.index = index
        self.subspace = subspace
        self.idExpression = idExpression
    }

    // MARK: - IndexMaintainer

    /// Update index entries when an item changes
    ///
    /// - Insert (oldItem=nil, newItem=value): Add value to sum
    /// - Update (oldItem=value, newItem=value): Adjust sum for value change
    /// - Delete (oldItem=value, newItem=nil): Subtract value from sum
    public func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        transaction: any TransactionProtocol
    ) async throws {
        // Extract old grouping key and value
        var oldGroupKey: [UInt8]?
        var oldValue: Double = 0

        if let old = oldItem {
            let (key, value) = try extractGroupKeyAndValue(for: old)
            oldGroupKey = key
            oldValue = value
        }

        // Extract new grouping key and value
        var newGroupKey: [UInt8]?
        var newValue: Double = 0

        if let new = newItem {
            let (key, value) = try extractGroupKeyAndValue(for: new)
            newGroupKey = key
            newValue = value
        }

        // Handle updates
        if let oldKey = oldGroupKey, let newKey = newGroupKey {
            if oldKey == newKey {
                // Same group key - apply delta
                let delta = newValue - oldValue
                if delta != 0 {
                    applyDelta(delta, toKey: newKey, transaction: transaction)
                }
            } else {
                // Different group keys - subtract from old, add to new
                applyDelta(-oldValue, toKey: oldKey, transaction: transaction)
                applyDelta(newValue, toKey: newKey, transaction: transaction)
            }
        } else if let oldKey = oldGroupKey {
            // Delete - subtract from old
            applyDelta(-oldValue, toKey: oldKey, transaction: transaction)
        } else if let newKey = newGroupKey {
            // Insert - add to new
            applyDelta(newValue, toKey: newKey, transaction: transaction)
        }
    }

    /// Build index entries for an item during batch indexing
    public func scanItem(
        _ item: Item,
        id: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let (key, value) = try extractGroupKeyAndValue(for: item)
        applyDelta(value, toKey: key, transaction: transaction)
    }

    /// Compute expected index keys for an item (for scrubber verification)
    ///
    /// For sum indexes, returns the group key that this item contributes to.
    ///
    /// **Note**: Aggregation indexes (Count/Sum/Min/Max) store aggregated values,
    /// not per-item entries. Scrubber can verify the key exists but cannot
    /// verify the exact sum value without full re-scan. Use `allowRepair=false`
    /// for detection only, or use `rebuildIndex()` for full rebuild.
    public func computeIndexKeys(
        for item: Item,
        id: Tuple
    ) async throws -> [FDB.Bytes] {
        let (key, _) = try extractGroupKeyAndValue(for: item)
        return [key]
    }

    // MARK: - Private

    /// Extract grouping key and value from an item
    ///
    /// The last field is the value; all preceding fields are grouping keys.
    private func extractGroupKeyAndValue(for item: Item) throws -> ([UInt8], Double) {
        // Extract all field values
        let fieldValues = try DataAccess.evaluate(item: item, expression: index.rootExpression)

        guard fieldValues.count >= 2 else {
            throw SumIndexMaintainerError.insufficientFields(
                expected: 2,
                actual: fieldValues.count
            )
        }

        // Separate grouping keys from value
        let groupingValues = Array(fieldValues.dropLast())
        let valueElement = fieldValues.last!

        // Build grouping key
        let groupKey = subspace.pack(Tuple(groupingValues))

        // Extract numeric value
        let numericValue = try extractNumericValue(from: valueElement)

        return (groupKey, numericValue)
    }

    /// Extract numeric value from a TupleElement
    ///
    /// Supports TupleElement-conforming numeric types: Int64, Int, Int32, UInt64, Double, Float
    private func extractNumericValue(from element: any TupleElement) throws -> Double {
        // TupleElement-conforming numeric types
        switch element {
        case let v as Int64:
            return Double(v)
        case let v as Int:
            return Double(v)
        case let v as Int32:
            return Double(v)
        case let v as UInt64:
            return Double(v)
        case let v as Double:
            return v
        case let v as Float:
            return Double(v)
        default:
            throw SumIndexMaintainerError.nonNumericValue(type: String(describing: type(of: element)))
        }
    }

    /// Apply a delta to a sum key using atomic operation
    private func applyDelta(_ delta: Double, toKey key: [UInt8], transaction: any TransactionProtocol) {
        // Use IEEE 754 double representation for atomic add
        // FoundationDB atomic add for doubles requires specific encoding
        let deltaBytes = withUnsafeBytes(of: delta.bitPattern.littleEndian) { Array($0) }
        transaction.atomicOp(key: key, param: deltaBytes, mutationType: .add)
    }
}

// MARK: - SumIndexMaintainerError

/// Errors specific to SumIndexMaintainer
public enum SumIndexMaintainerError: Error, CustomStringConvertible {
    /// Not enough fields for sum index (need groupKey + value)
    case insufficientFields(expected: Int, actual: Int)

    /// Value field is not numeric
    case nonNumericValue(type: String)

    public var description: String {
        switch self {
        case .insufficientFields(let expected, let actual):
            return "Sum index requires at least \(expected) fields (groupKey + value), got \(actual)"
        case .nonNumericValue(let type):
            return "Sum index value must be numeric, got \(type)"
        }
    }
}

// MARK: - IndexKindMaintainable Extension

extension SumIndexKind: IndexKindMaintainable {
    /// Create a SumIndexMaintainer for this index kind
    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item> {
        return SumIndexMaintainer<Item>(
            index: index,
            subspace: subspace.subspace(index.name),
            idExpression: idExpression
        )
    }
}
