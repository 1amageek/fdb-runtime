/// Metadata for enum types
///
/// Provides information about enum cases for serialization and validation.
///
/// **Usage**:
/// ```swift
/// enum Status: String, Codable {
///     case active
///     case inactive
///     case pending
/// }
///
/// let metadata = EnumMetadata(
///     typeName: "Status",
///     cases: ["active", "inactive", "pending"]
/// )
/// ```
public struct EnumMetadata: Sendable, Equatable {
    /// The type name of the enum
    public let typeName: String

    /// All case names in the enum
    public let cases: [String]

    /// Initialize EnumMetadata
    ///
    /// - Parameters:
    ///   - typeName: The enum type name
    ///   - cases: All case names
    public init(typeName: String, cases: [String]) {
        self.typeName = typeName
        self.cases = cases
    }

    /// Check if a value is a valid case
    ///
    /// - Parameter value: The case name to validate
    /// - Returns: true if the value is a valid case
    public func isValidCase(_ value: String) -> Bool {
        return cases.contains(value)
    }
}
