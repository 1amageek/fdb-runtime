// IndexConfiguration.swift
// FDBModel - Protocol for defining runtime index configuration
//
// Provides runtime configuration for indexes that need heavy parameters
// (HNSW, full-text search, etc.) separate from compile-time IndexKind metadata.

/// Protocol for defining runtime index configuration
///
/// **Purpose**: Separate heavy, environment-dependent parameters from IndexKind.
/// While IndexKind is defined in model macros, IndexConfiguration is specified
/// at Container initialization time.
///
/// **Design Principles**:
/// - No associated type: enables `[any IndexConfiguration]` without wrapping
/// - KeyPath specified via AnyKeyPath for protocol conformance
/// - Concrete types use generics for type safety
/// - Multiple configurations per index supported (e.g., multi-language full-text)
///
/// **When to use IndexConfiguration**:
/// - Memory-intensive parameters (HNSW: M, efConstruction, efSearch)
/// - Environment-dependent settings (vector dimensions, language settings)
/// - Parameters that vary between deployments
///
/// **When NOT to use** (use IndexKind properties instead):
/// - Lightweight metadata (retention strategy for VersionIndexKind)
/// - Compile-time constants
/// - Index behavior that doesn't vary between deployments
///
/// **Example - Vector Index**:
/// ```swift
/// public struct VectorIndexConfiguration<Model: Persistable>: IndexConfiguration {
///     public static var kindIdentifier: String { "vector" }
///
///     private let _keyPath: KeyPath<Model, [Float]>
///     public var keyPath: AnyKeyPath { _keyPath }
///     public var modelTypeName: String { String(describing: Model.self) }
///
///     public let dimensions: Int
///     public let hnswParameters: HNSWParameters
/// }
/// ```
///
/// **Example - Full-text Index (multiple languages)**:
/// ```swift
/// FDBConfiguration(
///     indexConfigurations: [
///         FullTextIndexConfiguration<Article>(keyPath: \.content, language: "ja", ...),
///         FullTextIndexConfiguration<Article>(keyPath: \.content, language: "en", ...)
///     ]
/// )
/// ```
public protocol IndexConfiguration: Sendable {
    /// Identifier of the corresponding IndexKind
    ///
    /// Must match the `identifier` property of the IndexKind this configuration applies to.
    ///
    /// **Examples**:
    /// - "vector" for VectorIndexKind
    /// - "fulltext" for FullTextIndexKind
    /// - "com.mycompany.custom" for custom IndexKinds
    static var kindIdentifier: String { get }

    /// Target field's KeyPath (type-erased)
    ///
    /// Must match the keyPath defined in the model via `#Index` macro.
    var keyPath: AnyKeyPath { get }

    /// Target model's type name
    ///
    /// Used for generating index name: `{modelTypeName}_{fieldName}`
    var modelTypeName: String { get }

    /// Computed index name
    ///
    /// Format: `{modelTypeName}_{fieldName}`
    /// Default implementation extracts fieldName from keyPath.
    var indexName: String { get }
}

// MARK: - Default Implementation

extension IndexConfiguration {
    /// Computed index name
    ///
    /// **Note**: This is a fallback. Concrete implementations should provide
    /// a more reliable way to extract field name from keyPath.
    public var indexName: String {
        // Extract field name from keyPath string representation
        // KeyPath<Model, Type> typically shows as \Model.fieldName
        let keyPathString = String(describing: keyPath)
        let fieldName: String
        if let dotIndex = keyPathString.lastIndex(of: ".") {
            fieldName = String(keyPathString[keyPathString.index(after: dotIndex)...])
        } else {
            fieldName = keyPathString
        }
        return "\(modelTypeName)_\(fieldName)"
    }
}

// MARK: - Configuration Errors

/// Errors that occur during index configuration validation
public enum IndexConfigurationError: Error, CustomStringConvertible, Sendable {
    /// The specified index was not found in the schema
    case unknownIndex(indexName: String)

    /// The IndexConfiguration's kindIdentifier doesn't match the IndexKind
    case indexKindMismatch(indexName: String, expected: String, actual: String)

    /// Duplicate configuration for the same index (when duplicates are not allowed)
    case duplicateConfiguration(indexName: String)

    /// Configuration is missing for a required index
    case missingRequiredConfiguration(indexName: String, kindIdentifier: String)

    /// Invalid configuration parameters
    case invalidConfiguration(indexName: String, reason: String)

    public var description: String {
        switch self {
        case let .unknownIndex(indexName):
            return "Index configuration references unknown index '\(indexName)'"

        case let .indexKindMismatch(indexName, expected, actual):
            return "Index '\(indexName)' has kind '\(expected)', but configuration has kindIdentifier '\(actual)'"

        case let .duplicateConfiguration(indexName):
            return "Multiple configurations provided for index '\(indexName)' where only one is allowed"

        case let .missingRequiredConfiguration(indexName, kindIdentifier):
            return "Index '\(indexName)' of kind '\(kindIdentifier)' requires runtime configuration"

        case let .invalidConfiguration(indexName, reason):
            return "Invalid configuration for index '\(indexName)': \(reason)"
        }
    }
}
