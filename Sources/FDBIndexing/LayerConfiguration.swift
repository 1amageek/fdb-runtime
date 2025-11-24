import Foundation
import FoundationDB

/// Configuration for a data model layer
///
/// LayerConfiguration defines how a specific data model layer (Record, Document, Vector, Graph, etc.)
/// integrates with FDBStore. Each layer provides factories for creating DataAccess and IndexMaintainer
/// instances based on itemType.
///
/// **Responsibilities**:
/// - Declare supported item types
/// - Provide DataAccess factory for serialization and field extraction
/// - Provide IndexMaintainer factory for index maintenance
///
/// **Design**:
/// - Multiple LayerConfigurations can coexist in a single FDBContainer
/// - FDBStore routes operations based on itemType
/// - Each layer is responsible for its own data transformation logic
///
/// **Implementation Examples**:
///
/// **Record Layer**:
/// ```swift
/// struct RecordLayerConfiguration: LayerConfiguration {
///     let itemTypes: Set<String> = ["User", "Order", "Product"]
///
///     func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
///         switch itemType {
///         case "User":
///             return GenericDataAccess<User>() as! any DataAccess<Item>
///         case "Order":
///             return GenericDataAccess<Order>() as! any DataAccess<Item>
///         default:
///             throw ConfigurationError.unsupportedItemType(itemType)
///         }
///     }
///
///     func makeIndexMaintainer<Item>(
///         for index: Index,
///         itemType: String,
///         subspace: Subspace
///     ) throws -> any IndexMaintainer<Item> {
///         return try GenericValueIndexMaintainer<Item>(index: index, subspace: subspace)
///     }
/// }
/// ```
///
/// **Document Layer**:
/// ```swift
/// struct DocumentLayerConfiguration: LayerConfiguration {
///     let itemTypes: Set<String> = ["Document"]
///
///     func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
///         guard itemType == "Document" else {
///             throw ConfigurationError.unsupportedItemType(itemType)
///         }
///         return DocumentAccess() as! any DataAccess<Item>
///     }
///
///     func makeIndexMaintainer<Item>(
///         for index: Index,
///         itemType: String,
///         subspace: Subspace
///     ) throws -> any IndexMaintainer<Item> {
///         return try DocumentIndexMaintainer<Item>(index: index, subspace: subspace)
///     }
/// }
/// ```
public protocol LayerConfiguration: Sendable {
    /// Set of item types supported by this layer
    ///
    /// Example: ["User", "Order", "Product"] for Record Layer
    /// Example: ["Document"] for Document Layer
    var itemTypes: Set<String> { get }

    /// Create a DataAccess instance for the given item type
    ///
    /// - Parameter itemType: The item type name
    /// - Returns: DataAccess instance for serialization and field extraction
    /// - Throws: Error if itemType is not supported
    func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item>

    /// Create an IndexMaintainer instance for the given index
    ///
    /// - Parameters:
    ///   - index: The index definition
    ///   - itemType: The item type name
    ///   - subspace: The index subspace
    /// - Returns: IndexMaintainer instance for maintaining the index
    /// - Throws: Error if index type or itemType is not supported
    func makeIndexMaintainer<Item>(
        for index: Index,
        itemType: String,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item>
}

// MARK: - Configuration Error

/// Errors that can occur during layer configuration
public enum ConfigurationError: Error {
    case unsupportedItemType(String)
    case unsupportedIndexType(String)
    case invalidConfiguration(String)
}
