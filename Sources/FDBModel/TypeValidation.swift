// TypeValidation.swift
// FDBModel - Type validation helper functions (FDB-independent)
//
// Helper functions for use in IndexKind.validateTypes() implementations.
// Provides type checking using actual type metatypes.

/// Helper functions for type validation
///
/// **Purpose**: Used in IndexKindProtocol.validateTypes() implementations
///
/// **Design principles**:
/// - Use actual type metatypes (Any.Type)
/// - Extensible (supports custom types too)
/// - Runtime checks (Comparable protocol conformance, etc.)
///
/// **Example**:
/// ```swift
/// // Numeric type check
/// if TypeValidation.isNumeric(Int64.self) {
///     print("Int64 is numeric")
/// }
///
/// // Comparable type check
/// if TypeValidation.isComparable(String.self) {
///     print("String is comparable")
/// }
///
/// // Works with custom types too
/// struct Price: Comparable { ... }
/// if TypeValidation.isComparable(Price.self) {
///     print("Price is comparable")
/// }
/// ```
public enum TypeValidation {
    /// Check if type is numeric
    ///
    /// **Supported types**:
    /// - Integers: Int, Int8, Int16, Int32, Int64
    /// - Unsigned integers: UInt, UInt8, UInt16, UInt32, UInt64
    /// - Floating-point: Float, Double, Float32
    ///
    /// **Example**:
    /// ```swift
    /// TypeValidation.isNumeric(Int64.self)   // true
    /// TypeValidation.isNumeric(Double.self)  // true
    /// TypeValidation.isNumeric(String.self)  // false
    /// ```
    ///
    /// - Parameter type: Type to check
    /// - Returns: true if numeric type
    public static func isNumeric(_ type: Any.Type) -> Bool {
        return type == Int.self
            || type == Int8.self
            || type == Int16.self
            || type == Int32.self
            || type == Int64.self
            || type == UInt.self
            || type == UInt8.self
            || type == UInt16.self
            || type == UInt32.self
            || type == UInt64.self
            || type == Float.self
            || type == Double.self
            || type == Float32.self
    }

    /// Check if type is floating-point
    ///
    /// **Supported types**: Float, Double, Float32
    ///
    /// **Example**:
    /// ```swift
    /// TypeValidation.isFloatingPoint(Float32.self)  // true
    /// TypeValidation.isFloatingPoint(Int.self)      // false
    /// ```
    ///
    /// - Parameter type: Type to check
    /// - Returns: true if floating-point type
    public static func isFloatingPoint(_ type: Any.Type) -> Bool {
        return type == Float.self
            || type == Double.self
            || type == Float32.self
    }

    /// Check if type is integer
    ///
    /// **Supported types**: All Int and UInt variants
    ///
    /// **Example**:
    /// ```swift
    /// TypeValidation.isInteger(Int64.self)  // true
    /// TypeValidation.isInteger(Float.self)  // false
    /// ```
    ///
    /// - Parameter type: Type to check
    /// - Returns: true if integer type
    public static func isInteger(_ type: Any.Type) -> Bool {
        return type == Int.self
            || type == Int8.self
            || type == Int16.self
            || type == Int32.self
            || type == Int64.self
            || type == UInt.self
            || type == UInt8.self
            || type == UInt16.self
            || type == UInt32.self
            || type == UInt64.self
    }

    /// Check if type conforms to Comparable
    ///
    /// **Support**: All Comparable-conforming types
    /// - String, Int, Date, UUID, etc. (standard types)
    /// - User-defined Comparable types
    ///
    /// **Implementation**: Dynamic protocol check
    ///
    /// **Example**:
    /// ```swift
    /// TypeValidation.isComparable(String.self)  // true
    /// TypeValidation.isComparable(Int.self)     // true
    /// TypeValidation.isComparable(Date.self)    // true
    ///
    /// // Custom type
    /// struct Price: Comparable { ... }
    /// TypeValidation.isComparable(Price.self)   // true
    /// ```
    ///
    /// - Parameter type: Type to check
    /// - Returns: true if Comparable-conforming type
    public static func isComparable(_ type: Any.Type) -> Bool {
        return (type as? any Comparable.Type) != nil
    }

    /// Check if type is array
    ///
    /// **Support**: All Array<T> types
    ///
    /// **Example**:
    /// ```swift
    /// TypeValidation.isArrayType([Float32].self)  // true
    /// TypeValidation.isArrayType([Int].self)      // true
    /// TypeValidation.isArrayType(String.self)     // false
    /// ```
    ///
    /// **Note**: This implementation uses string-based detection.
    /// For more strict detection, perform additional validation in execution layer.
    ///
    /// - Parameter type: Type to check
    /// - Returns: true if array type
    public static func isArrayType(_ type: Any.Type) -> Bool {
        // Check type's string representation
        let typeString = String(describing: type)
        return typeString.hasPrefix("Array<")
    }
}
