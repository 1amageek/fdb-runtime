// MinIndexMaintainer.swift
// FDBIndexing - Minimum value index maintainer implementation
//
// Maintains min indexes for efficient minimum value tracking by grouping keys.

import Foundation
import FoundationDB
import FDBModel
import FDBCore

/// Maintains minimum value indexes by grouping keys
///
/// **Key Structure**: `[subspace][groupKey...][value][id] = ''`
/// Last field in keyPaths is the value field; preceding fields are grouping keys.
///
/// **Supports**:
/// - Get minimum value by group key (first key in range)
/// - Efficient min tracking via sorted storage
///
/// **Usage**:
/// ```swift
/// let index = Index(
///     name: "Product_min_price_by_category",
///     kind: MinIndexKind(),
///     rootExpression: ConcatenateKeyExpression([
///         FieldKeyExpression(fieldName: "category"),
///         FieldKeyExpression(fieldName: "price")
///     ]),
///     subspaceKey: "Product_min_price_by_category"
/// )
///
/// let maintainer = MinIndexMaintainer<Product>(
///     index: index,
///     subspace: indexSubspace
/// )
/// ```
public struct MinIndexMaintainer<Item: Persistable>: IndexMaintainer {
    // MARK: - Properties

    /// Index definition
    public let index: Index

    /// Subspace for index storage
    public let subspace: Subspace

    /// ID expression for extracting item's unique identifier
    public let idExpression: KeyExpression

    // MARK: - Initialization

    /// Create a MinIndexMaintainer
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
    /// - Insert (oldItem=nil, newItem=value): Add index entry
    /// - Update (oldItem=value, newItem=value): Remove old entry, add new entry
    /// - Delete (oldItem=value, newItem=nil): Remove index entry
    public func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old index entry
        if let old = oldItem {
            let oldKey = try buildIndexKey(for: old)
            transaction.clear(key: oldKey)
        }

        // Add new index entry
        if let new = newItem {
            let newKey = try buildIndexKey(for: new)
            transaction.setValue([], for: newKey)
        }
    }

    /// Build index entries for an item during batch indexing
    public func scanItem(
        _ item: Item,
        id: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let key = try buildIndexKey(for: item, id: id)
        transaction.setValue([], for: key)
    }

    /// Compute expected index keys for an item (for scrubber verification)
    ///
    /// For min indexes, returns the index key that should exist for this item.
    /// Min indexes store per-item entries (unlike Count/Sum aggregations),
    /// so scrubber can verify exact entries.
    public func computeIndexKeys(
        for item: Item,
        id: Tuple
    ) async throws -> [FDB.Bytes] {
        return [try buildIndexKey(for: item, id: id)]
    }

    // MARK: - Private

    /// Build index key for an item
    ///
    /// Key structure: [subspace][groupKey...][value][id]
    private func buildIndexKey(for item: Item, id: Tuple? = nil) throws -> [UInt8] {
        // Extract all field values (groupKey... + value)
        let fieldValues = try DataAccess.evaluate(item: item, expression: index.rootExpression)

        // Extract id
        let itemId: Tuple
        if let providedId = id {
            itemId = providedId
        } else {
            itemId = try DataAccess.extractId(from: item, using: idExpression)
        }

        // Build key: [subspace][groupKey...][value][id]
        var allElements: [any TupleElement] = []
        for value in fieldValues {
            allElements.append(value)
        }

        // Append id elements
        for i in 0..<itemId.count {
            if let element = itemId[i] {
                allElements.append(element)
            }
        }

        return subspace.pack(Tuple(allElements))
    }
}

// MARK: - IndexKindMaintainable Extension

extension MinIndexKind: IndexKindMaintainable {
    /// Create a MinIndexMaintainer for this index kind
    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item> {
        return MinIndexMaintainer<Item>(
            index: index,
            subspace: subspace.subspace(index.name),
            idExpression: idExpression
        )
    }
}
