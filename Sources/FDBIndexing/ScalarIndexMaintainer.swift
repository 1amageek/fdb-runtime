// ScalarIndexMaintainer.swift
// FDBIndexing - Standard VALUE index maintainer implementation
//
// Maintains scalar (VALUE) indexes for sorting and range queries.

import Foundation
import FoundationDB
import FDBModel
import FDBCore

/// Maintains scalar (VALUE) indexes
///
/// **Key Structure**: `[subspace][fieldValues...][id] = ''`
///
/// **Supports**:
/// - Exact match queries
/// - Range queries
/// - Prefix queries
/// - Unique constraints (enforced at application level)
///
/// **Usage**:
/// ```swift
/// let index = Index(
///     name: "User_email",
///     kind: ScalarIndexKind(),
///     rootExpression: FieldKeyExpression(fieldName: "email"),
///     subspaceKey: "User_email"
/// )
///
/// let maintainer = ScalarIndexMaintainer<User>(
///     index: index,
///     subspace: indexSubspace
/// )
///
/// try await maintainer.updateIndex(
///     oldItem: nil,
///     newItem: user,
///     transaction: transaction
/// )
/// ```
public struct ScalarIndexMaintainer<Item: Persistable>: IndexMaintainer {
    // MARK: - Properties

    /// Index definition
    public let index: Index

    /// Subspace for index storage
    public let subspace: Subspace

    /// ID expression for extracting item's unique identifier
    public let idExpression: KeyExpression

    // MARK: - Initialization

    /// Create a ScalarIndexMaintainer
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
            // Value is empty for scalar indexes
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
    /// Returns the index key that should exist for this item.
    public func computeIndexKeys(
        for item: Item,
        id: Tuple
    ) async throws -> [FDB.Bytes] {
        return [try buildIndexKey(for: item, id: id)]
    }

    // MARK: - Private

    /// Build index key for an item
    ///
    /// Key structure: [subspace][fieldValues...][id]
    private func buildIndexKey(for item: Item, id: Tuple? = nil) throws -> [UInt8] {
        // Extract field values using DataAccess
        let fieldValues = try DataAccess.evaluate(item: item, expression: index.rootExpression)

        // Extract id
        let itemId: Tuple
        if let providedId = id {
            itemId = providedId
        } else {
            itemId = try DataAccess.extractId(from: item, using: idExpression)
        }

        // Build key: [subspace][fieldValues...][id]
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

extension ScalarIndexKind: IndexKindMaintainable {
    /// Create a ScalarIndexMaintainer for this index kind
    ///
    /// This bridges `ScalarIndexKind` (metadata) with `ScalarIndexMaintainer` (runtime).
    /// Called by the system when building or maintaining indexes.
    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item> {
        return ScalarIndexMaintainer<Item>(
            index: index,
            subspace: subspace.subspace(index.name),
            idExpression: idExpression
        )
    }
}
