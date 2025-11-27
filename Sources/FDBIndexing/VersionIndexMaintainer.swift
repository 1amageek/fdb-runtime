// VersionIndexMaintainer.swift
// FDBIndexing - Version index maintainer implementation
//
// Maintains version-based indexes for tracking record changes.

import Foundation
import FoundationDB
import FDBModel
import FDBCore

/// Maintains version indexes for tracking record changes
///
/// **Key Structure**: `[subspace][version][id] = ''`
///
/// **Supports**:
/// - Range queries by version
/// - Find records modified after a specific version
///
/// **Usage**:
/// ```swift
/// let index = Index(
///     name: "User_version",
///     kind: VersionIndexKind(),
///     rootExpression: FieldKeyExpression(fieldName: "version"),
///     subspaceKey: "User_version"
/// )
///
/// let maintainer = VersionIndexMaintainer<User>(
///     index: index,
///     subspace: indexSubspace
/// )
/// ```
public struct VersionIndexMaintainer<Item: Persistable>: IndexMaintainer {
    // MARK: - Properties

    /// Index definition
    public let index: Index

    /// Subspace for index storage
    public let subspace: Subspace

    /// ID expression for extracting item's unique identifier
    public let idExpression: KeyExpression

    // MARK: - Initialization

    /// Create a VersionIndexMaintainer
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
    /// Returns the version index key that should exist for this item.
    public func computeIndexKeys(
        for item: Item,
        id: Tuple
    ) async throws -> [FDB.Bytes] {
        return [try buildIndexKey(for: item, id: id)]
    }

    // MARK: - Private

    /// Build index key for an item
    ///
    /// Key structure: [subspace][version][id]
    private func buildIndexKey(for item: Item, id: Tuple? = nil) throws -> [UInt8] {
        // Extract version value
        let versionValues = try DataAccess.evaluate(item: item, expression: index.rootExpression)

        // Extract id
        let itemId: Tuple
        if let providedId = id {
            itemId = providedId
        } else {
            itemId = try DataAccess.extractId(from: item, using: idExpression)
        }

        // Build key: [subspace][version][id]
        var allElements: [any TupleElement] = []
        for value in versionValues {
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

extension VersionIndexKind: IndexKindMaintainable {
    /// Create a VersionIndexMaintainer for this index kind
    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item> {
        return VersionIndexMaintainer<Item>(
            index: index,
            subspace: subspace.subspace(index.name),
            idExpression: idExpression
        )
    }
}
