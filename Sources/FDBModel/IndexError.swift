// IndexError.swift
// FDBIndexing - Error types for index operations

/// Errors that can occur during index operations
public enum IndexError: Error, CustomStringConvertible {
    /// Invalid index configuration
    case invalidConfiguration(String)

    /// Invalid argument provided to index operation
    case invalidArgument(String)

    /// Incompatible algorithm configuration for index kind
    case incompatibleConfiguration(String)

    /// Invalid index structure encountered
    case invalidStructure(String)

    /// No data found for operation
    case noData(String)

    /// Internal error (should not happen)
    case internalError(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .incompatibleConfiguration(let message):
            return "Incompatible configuration: \(message)"
        case .invalidStructure(let message):
            return "Invalid structure: \(message)"
        case .noData(let message):
            return "No data: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
