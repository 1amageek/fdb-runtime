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
/// - Protocol definition only in FDBRuntime
/// - Concrete implementations in upper layers (fdb-record-layer, fdb-document-layer, etc.)
/// - Each data model layer provides its own implementations
///
/// **Usage Example** (fdb-record-layer):
/// ```swift
/// struct ValueIndexMaintainer<Record: Recordable>: IndexMaintainer {
///     func updateIndex(
///         oldRecord: Record?,
///         newRecord: Record?,
///         dataAccess: any DataAccess<Record>,
///         transaction: any TransactionProtocol
///     ) async throws {
///         // Remove old index entries
///         if let old = oldRecord {
///             let oldValues = try dataAccess.evaluate(item: old, expression: index.rootExpression)
///             // Remove from index...
///         }
///
///         // Add new index entries
///         if let new = newRecord {
///             let newValues = try dataAccess.evaluate(item: new, expression: index.rootExpression)
///             // Add to index...
///         }
///     }
///
///     func scanRecord(
///         _ record: Record,
///         primaryKey: Tuple,
///         dataAccess: any DataAccess<Record>,
///         transaction: any TransactionProtocol
///     ) async throws {
///         // Build index entries for this record
///         let values = try dataAccess.evaluate(item: record, expression: index.rootExpression)
///         // Add to index...
///     }
/// }
/// ```
public protocol IndexMaintainer<Record>: Sendable {
    associatedtype Record: Sendable

    /// Update index entries when a record changes
    ///
    /// This method is called when a record is inserted, updated, or deleted.
    /// The implementation should:
    /// 1. Remove old index entries (if oldRecord is not nil)
    /// 2. Add new index entries (if newRecord is not nil)
    ///
    /// - Parameters:
    ///   - oldRecord: The old record (nil if inserting)
    ///   - newRecord: The new record (nil if deleting)
    ///   - dataAccess: DataAccess for extracting field values
    ///   - transaction: The transaction to use
    /// - Throws: Error if index update fails
    func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        dataAccess: any DataAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws

    /// Scan and build index entries for a record
    ///
    /// This method is called during batch index building (OnlineIndexer).
    /// The implementation should build all index entries for the given record.
    ///
    /// - Parameters:
    ///   - record: The record to scan
    ///   - primaryKey: The record's primary key
    ///   - dataAccess: DataAccess for extracting field values
    ///   - transaction: The transaction to use
    /// - Throws: Error if index building fails
    func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        dataAccess: any DataAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws
}
