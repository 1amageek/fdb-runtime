import Foundation
import FDBModel

/// Describes the criteria, sort order, and configuration for fetching models
///
/// Similar to SwiftData's `FetchDescriptor<T>`, this type provides a declarative
/// way to specify what data to fetch and how to process it.
///
/// **Usage**:
/// ```swift
/// // Fetch all users
/// let descriptor = FDBFetchDescriptor<User>()
///
/// // Fetch with predicate and sorting
/// let descriptor = FDBFetchDescriptor<User>(
///     predicate: .field("isActive", .equals, true),
///     sortBy: [.ascending("name")],
///     fetchLimit: 10
/// )
///
/// let users = try await context.fetch(descriptor)
/// ```
public struct FDBFetchDescriptor<T: Persistable>: Sendable {
    /// Filter predicate (nil means fetch all)
    public var predicate: FDBPredicate<T>?

    /// Sort descriptors (empty means no sorting)
    public var sortBy: [FDBSortDescriptor<T>]

    /// Maximum number of results (nil means no limit)
    public var fetchLimit: Int?

    /// Number of results to skip (nil means start from beginning)
    public var fetchOffset: Int?

    /// Initialize a fetch descriptor
    ///
    /// - Parameters:
    ///   - predicate: Filter predicate
    ///   - sortBy: Sort descriptors
    ///   - fetchLimit: Maximum number of results
    ///   - fetchOffset: Number of results to skip
    public init(
        predicate: FDBPredicate<T>? = nil,
        sortBy: [FDBSortDescriptor<T>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int? = nil
    ) {
        self.predicate = predicate
        self.sortBy = sortBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
    }
}

// MARK: - FDBPredicate

/// Predicate for filtering models
///
/// Provides a type-safe way to express filter conditions.
///
/// **Usage**:
/// ```swift
/// // Simple field comparison
/// let predicate: FDBPredicate<User> = .field("isActive", .equals, true)
///
/// // Combined predicates
/// let predicate: FDBPredicate<User> = .and([
///     .field("age", .greaterThan, 18),
///     .field("city", .equals, "Tokyo")
/// ])
/// ```
///
/// **Limitations**:
/// - **Nested fields not supported**: Field names must be top-level properties only.
///   Dot notation (e.g., "address.city") will throw an error at runtime.
///   To query nested data, flatten the structure or use separate index fields.
///
/// - **Type-safe comparison**: Numeric comparisons preserve proper ordering
///   (Int, Double, etc. are compared numerically, not as strings).
public indirect enum FDBPredicate<T: Persistable>: Sendable {
    /// Compare a field value
    case field(String, FDBComparison, any Sendable)

    /// All predicates must match (AND)
    case and([FDBPredicate<T>])

    /// Any predicate must match (OR)
    case or([FDBPredicate<T>])

    /// Negate the predicate (NOT)
    case not(FDBPredicate<T>)

    /// Always true
    case `true`

    /// Always false
    case `false`
}

// MARK: - FDBComparison

/// Comparison operators for predicates
public enum FDBComparison: Sendable, Equatable {
    /// Equal to
    case equals

    /// Not equal to
    case notEquals

    /// Less than
    case lessThan

    /// Less than or equal to
    case lessThanOrEquals

    /// Greater than
    case greaterThan

    /// Greater than or equal to
    case greaterThanOrEquals

    /// String contains substring
    case contains

    /// String begins with prefix
    case beginsWith

    /// String ends with suffix
    case endsWith

    /// Value is in array
    case `in`
}

// MARK: - FDBSortDescriptor

/// Describes how to sort fetch results
///
/// **Usage**:
/// ```swift
/// let sortBy: [FDBSortDescriptor<User>] = [
///     .ascending("lastName"),
///     .descending("createdAt")
/// ]
/// ```
///
/// **Limitations**:
/// - **Nested fields not supported**: Sort key paths must be top-level properties only.
///   Dot notation (e.g., "address.city") will throw an error at runtime.
///
/// - **Type-safe sorting**: Numeric values are sorted numerically (not as strings),
///   ensuring proper ordering for Int, Double, Date, etc.
public struct FDBSortDescriptor<T: Persistable>: Sendable {
    /// Field name to sort by
    public let keyPath: String

    /// Sort order
    public let order: FDBSortOrder

    /// Initialize with key path and order
    public init(keyPath: String, order: FDBSortOrder) {
        self.keyPath = keyPath
        self.order = order
    }

    /// Create an ascending sort descriptor
    public static func ascending(_ keyPath: String) -> Self {
        Self(keyPath: keyPath, order: .ascending)
    }

    /// Create a descending sort descriptor
    public static func descending(_ keyPath: String) -> Self {
        Self(keyPath: keyPath, order: .descending)
    }
}

/// Sort order
public enum FDBSortOrder: Sendable, Equatable {
    case ascending
    case descending
}
