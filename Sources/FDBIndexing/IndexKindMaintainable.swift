// IndexKind.swift
// FDBIndexing - Runtime extension of IndexKindMetadata
//
// Adds runtime capabilities (IndexMaintainer creation) to IndexKindMetadata.
// This protocol depends on FoundationDB types and should only be used in server-side code.

import Foundation
import FoundationDB
import FDBModel
import FDBCore

/// Runtime extension of IndexKindMetadata with IndexMaintainer creation
///
/// This protocol extends IndexKindMetadata with the ability to create IndexMaintainer
/// instances at runtime. Since IndexMaintainer depends on FoundationDB types
/// (Subspace, TransactionProtocol), this protocol must be in FDBIndexing, not FDBCore.
///
/// **Design**:
/// - IndexKindMetadata (FDBCore): Pure metadata, FDB-independent
/// - IndexKind (FDBIndexing): Runtime capabilities, FDB-dependent
///
/// **Example**:
/// ```swift
/// public struct ScalarIndexKind: IndexKind {
///     public static let identifier = "scalar"
///     public static let subspaceStructure = SubspaceStructure.flat
///
///     public static func validateTypes(_ types: [Any.Type]) throws {
///         // Type validation
///     }
///
///     public func makeIndexMaintainer<Item: Sendable>(
///         index: Index,
///         subspace: Subspace,
///         configuration: AlgorithmConfiguration?
///     ) throws -> any IndexMaintainer<Item> {
///         return ScalarIndexMaintainer<Item>(index: index, kind: self, subspace: subspace)
///     }
///
///     public init() {}
/// }
/// ```
public protocol IndexKindMaintainable: IndexKind {
    /// Create an IndexMaintainer instance for this index kind
    ///
    /// **Purpose**: Factory method to create the appropriate IndexMaintainer implementation
    ///
    /// **Runtime Algorithm Selection**:
    /// - `configuration` parameter allows runtime algorithm selection (e.g., vector: flat/HNSW/IVF)
    /// - IndexKind implementations can ignore configuration if not applicable (e.g., scalar)
    /// - If configuration is nil, implementations should use safe defaults
    ///
    /// **Parameters**:
    /// - index: Index definition (name, rootExpression, etc.)
    /// - subspace: FDB subspace for storing index data
    /// - configuration: Optional runtime algorithm configuration
    ///
    /// **Returns**: IndexMaintainer instance for maintaining this index
    ///
    /// **Throws**: IndexError if configuration is incompatible with this index kind
    ///
    /// **Examples**:
    /// ```swift
    /// // Scalar: Configuration ignored
    /// public func makeIndexMaintainer<Item: Sendable>(
    ///     index: Index,
    ///     subspace: Subspace,
    ///     configuration: AlgorithmConfiguration?
    /// ) throws -> any IndexMaintainer<Item> {
    ///     return ScalarIndexMaintainer<Item>(index: index, kind: self, subspace: subspace)
    /// }
    ///
    /// // Vector: Configuration determines algorithm
    /// public func makeIndexMaintainer<Item: Sendable>(
    ///     index: Index,
    ///     subspace: Subspace,
    ///     configuration: AlgorithmConfiguration?
    /// ) throws -> any IndexMaintainer<Item> {
    ///     switch configuration {
    ///     case .vectorFlatScan:
    ///         return FlatVectorIndexMaintainer<Item>(...)
    ///     case .vectorHNSW(let params):
    ///         return HNSWIndexMaintainer<Item>(..., parameters: params)
    ///     default:
    ///         return FlatVectorIndexMaintainer<Item>(...)  // Safe default
    ///     }
    /// }
    /// ```
    func makeIndexMaintainer<Item: Sendable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item>
}
