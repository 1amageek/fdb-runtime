import Foundation
import FoundationDB

/// Protocol for maintaining an index
///
/// IndexMaintainer provides the interface for updating and building indexes.
/// Concrete implementations are provided by upper layers (fdb-record-layer, etc.).
///
/// **Responsibilities**:
/// - Update index entries when items change
/// - Build index entries during batch indexing
/// - Use DataAccess to extract field values
///
/// **Design**:
/// - Protocol definition only in FDBIndexing
/// - Concrete implementations in upper layers (fdb-record-layer, fdb-document-layer, etc.)
/// - Each data model layer provides its own implementations
///
/// **Usage Example** (fdb-record-layer):
/// ```swift
/// struct ValueIndexMaintainer<Item: Persistable>: IndexMaintainer {
///     func updateIndex(
///         oldItem: Item?,
///         newItem: Item?,
///         dataAccess: any DataAccess<Item>,
///         transaction: any TransactionProtocol
///     ) async throws {
///         // Remove old index entries
///         if let old = oldItem {
///             let oldValues = try dataAccess.evaluate(item: old, expression: index.rootExpression)
///             // Remove from index...
///         }
///
///         // Add new index entries
///         if let new = newItem {
///             let newValues = try dataAccess.evaluate(item: new, expression: index.rootExpression)
///             // Add to index...
///         }
///     }
///
///     func scanItem(
///         _ item: Item,
///         primaryKey: Tuple,
///         dataAccess: any DataAccess<Item>,
///         transaction: any TransactionProtocol
///     ) async throws {
///         // Build index entries for this item
///         let values = try dataAccess.evaluate(item: item, expression: index.rootExpression)
///         // Add to index...
///     }
/// }
/// ```
public protocol IndexMaintainer<Item>: Sendable {
    associatedtype Item: Sendable

    /// Update index entries when an item changes
    ///
    /// This method is called when an item is inserted, updated, or deleted.
    /// The implementation should:
    /// 1. Remove old index entries (if oldItem is not nil)
    /// 2. Add new index entries (if newItem is not nil)
    ///
    /// - Parameters:
    ///   - oldItem: The old item (nil if inserting)
    ///   - newItem: The new item (nil if deleting)
    ///   - dataAccess: DataAccess for extracting field values
    ///   - transaction: The transaction to use
    /// - Throws: Error if index update fails
    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws

    /// Scan and build index entries for an item
    ///
    /// This method is called during batch index building (OnlineIndexer).
    /// The implementation should build all index entries for the given item.
    ///
    /// - Parameters:
    ///   - item: The item to scan
    ///   - primaryKey: The item's primary key
    ///   - dataAccess: DataAccess for extracting field values
    ///   - transaction: The transaction to use
    /// - Throws: Error if index building fails
    func scanItem(
        _ item: Item,
        primaryKey: Tuple,
        dataAccess: any DataAccess<Item>,
        transaction: any TransactionProtocol
    ) async throws
}
