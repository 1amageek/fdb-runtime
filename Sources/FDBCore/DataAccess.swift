import Foundation
import FoundationDB
import FDBModel

/// Static utility for accessing Persistable item data
///
/// DataAccess provides static functions for extracting metadata and field values
/// from Persistable items. It uses the @dynamicMemberLookup subscript for field
/// access and ProtobufEncoder/Decoder for serialization.
///
/// **Design**: Stateless namespace with generic static functions
/// **No instantiation needed**: All methods are static
///
/// **Usage Example**:
/// ```swift
/// @Persistable
/// struct User {
///     var userID: Int64
///     var email: String
/// }
///
/// let user = User(userID: 123, email: "user@example.com")
///
/// // Extract field
/// let emailValue = try DataAccess.extractField(from: user, keyPath: "email")
///
/// // Evaluate KeyExpression
/// let values = try DataAccess.evaluate(item: user, expression: emailIndex.rootExpression)
///
/// // Serialize
/// let bytes = try DataAccess.serialize(user)
///
/// // Deserialize
/// let restored: User = try DataAccess.deserialize(bytes)
/// ```
public struct DataAccess: Sendable {
    // Private init to prevent instantiation
    private init() {}

    // MARK: - KeyExpression Evaluation

    /// Evaluate a KeyExpression to extract field values
    ///
    /// This method uses the Visitor pattern to traverse the KeyExpression tree
    /// and extract the corresponding values from the item using Persistable's subscript.
    ///
    /// - Parameters:
    ///   - item: The item to evaluate
    ///   - expression: The KeyExpression to evaluate
    /// - Returns: Array of tuple elements representing the extracted values
    /// - Throws: Error if field access fails
    public static func evaluate<Item: Persistable>(
        item: Item,
        expression: KeyExpression
    ) throws -> [any TupleElement] {
        let visitor = DataAccessEvaluator(item: item)
        return try expression.accept(visitor: visitor)
    }

    /// Extract a single field value using Persistable's subscript
    ///
    /// This method is called by the KeyExpression evaluator.
    ///
    /// **Field Name Format**:
    /// - Simple field: "email", "price"
    /// - Nested field: "user.address.city" (dot notation)
    ///
    /// - Parameters:
    ///   - item: The item to extract from
    ///   - keyPath: The field name (supports dot notation)
    /// - Returns: Array of tuple elements (typically single element)
    /// - Throws: Error if field not found or type conversion fails
    public static func extractField<Item: Persistable>(
        from item: Item,
        keyPath: String
    ) throws -> [any TupleElement] {
        // Handle nested keyPaths (e.g., "user.address.city")
        if keyPath.contains(".") {
            // For now, throw error for nested fields
            // Full implementation would traverse nested subscripts
            throw DataAccessError.nestedFieldsNotSupported(
                itemType: Item.persistableType,
                keyPath: keyPath
            )
        }

        // Use Persistable's subscript
        guard let value = item[dynamicMember: keyPath] else {
            throw DataAccessError.fieldNotFound(
                itemType: Item.persistableType,
                keyPath: keyPath
            )
        }

        // Convert to TupleElement
        return try convertToTupleElements(value)
    }

    /// Extract primary key from an item using the primary key expression
    ///
    /// - Parameters:
    ///   - item: The item to extract from
    ///   - primaryKeyExpression: The KeyExpression defining the primary key
    /// - Returns: Tuple representing the primary key
    /// - Throws: Error if extraction fails
    public static func extractPrimaryKey<Item: Persistable>(
        from item: Item,
        using primaryKeyExpression: KeyExpression
    ) throws -> Tuple {
        let elements = try evaluate(item: item, expression: primaryKeyExpression)
        return Tuple(elements)
    }

    /// Extract Range boundary value
    ///
    /// Extracts the lowerBound or upperBound from a Range-type field.
    ///
    /// **Supported Range types**:
    /// - Range<Bound>: Half-open range [a, b)
    /// - ClosedRange<Bound>: Closed range [a, b]
    /// - PartialRangeFrom<Bound>: [a, ∞)
    /// - PartialRangeThrough<Bound>: (-∞, b]
    /// - PartialRangeUpTo<Bound>: (-∞, b)
    ///
    /// **Default Implementation**: Throws error (not supported)
    /// Upper layers should implement Range-type field handling if needed.
    ///
    /// - Parameters:
    ///   - item: The item to extract from
    ///   - keyPath: The field name containing the Range type
    ///   - component: The boundary component to extract (lowerBound/upperBound)
    /// - Returns: Array containing the boundary value as TupleElement
    /// - Throws: Error indicating Range fields are not supported
    public static func extractRangeBoundary<Item: Persistable>(
        from item: Item,
        keyPath: String,
        component: RangeComponent
    ) throws -> [any TupleElement] {
        throw DataAccessError.rangeFieldsNotSupported(
            itemType: Item.persistableType,
            suggestion: "Range-type fields are not yet supported in this version"
        )
    }

    // MARK: - Serialization

    /// Serialize an item to bytes using ProtobufEncoder
    ///
    /// - Parameter item: The item to serialize
    /// - Returns: Serialized bytes
    /// - Throws: Error if serialization fails
    public static func serialize<Item: Persistable>(_ item: Item) throws -> FDB.Bytes {
        let encoder = ProtobufEncoder()
        let data = try encoder.encode(item)
        return Array(data)
    }

    /// Deserialize bytes to an item using ProtobufDecoder
    ///
    /// - Parameter bytes: The bytes to deserialize
    /// - Returns: Deserialized item
    /// - Throws: Error if deserialization fails
    public static func deserialize<Item: Persistable>(_ bytes: FDB.Bytes) throws -> Item {
        let decoder = ProtobufDecoder()
        return try decoder.decode(Item.self, from: Data(bytes))
    }

    // MARK: - Covering Index Support (Optional)

    /// Reconstruct an item from covering index key and value
    ///
    /// This method enables covering index optimization by reconstructing
    /// items directly from index data without fetching from storage.
    ///
    /// **Default Implementation**: Throws error (not supported)
    /// Upper layers should implement reconstruction if they support covering indexes.
    ///
    /// **Index Key Structure**: `<indexSubspace><rootExpression fields><primaryKey fields>`
    ///
    /// - Parameters:
    ///   - indexKey: The index key (unpacked tuple)
    ///   - indexValue: The index value (packed covering fields)
    ///   - primaryKeyExpression: Primary key expression for field extraction
    /// - Returns: Reconstructed item
    /// - Throws: Error indicating reconstruction is not supported
    public static func reconstruct<Item: Persistable>(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        primaryKeyExpression: KeyExpression
    ) throws -> Item {
        throw DataAccessError.reconstructionNotSupported(
            itemType: Item.persistableType,
            suggestion: "Covering index reconstruction is not yet supported in this version"
        )
    }

    // MARK: - Private Helpers

    /// Convert a Sendable value to TupleElements
    ///
    /// - Parameter value: The value to convert
    /// - Returns: Array of TupleElements
    /// - Throws: Error if type is not convertible to TupleElement
    private static func convertToTupleElements(_ value: any Sendable) throws -> [any TupleElement] {
        // Handle common types
        switch value {
        case let stringValue as String:
            return [stringValue]
        case let intValue as Int:
            return [Int64(intValue)]
        case let int64Value as Int64:
            return [int64Value]
        case let int32Value as Int32:
            return [Int64(int32Value)]
        case let int16Value as Int16:
            return [Int64(int16Value)]
        case let int8Value as Int8:
            return [Int64(int8Value)]
        case let uintValue as UInt:
            return [Int64(uintValue)]
        case let uint64Value as UInt64:
            return [Int64(uint64Value)]
        case let uint32Value as UInt32:
            return [Int64(uint32Value)]
        case let uint16Value as UInt16:
            return [Int64(uint16Value)]
        case let uint8Value as UInt8:
            return [Int64(uint8Value)]
        case let doubleValue as Double:
            return [doubleValue]
        case let floatValue as Float:
            return [Double(floatValue)]
        case let boolValue as Bool:
            return [boolValue]
        case let uuidValue as UUID:
            return [uuidValue]
        case let dataValue as Data:
            return [Array(dataValue)]
        case let bytesValue as [UInt8]:
            return [bytesValue]
        case let tupleValue as Tuple:
            return [tupleValue]
        case let arrayValue as [any TupleElement]:
            return arrayValue
        default:
            // For other types, attempt to convert to String
            return [String(describing: value)]
        }
    }
}

// MARK: - DataAccessEvaluator

/// Visitor that evaluates KeyExpressions using DataAccess
///
/// This visitor traverses a KeyExpression tree and extracts values from an item
/// using DataAccess static methods.
private struct DataAccessEvaluator<Item: Persistable>: KeyExpressionVisitor {
    let item: Item

    typealias Result = [any TupleElement]

    func visitField(_ fieldName: String) throws -> [any TupleElement] {
        return try DataAccess.extractField(from: item, keyPath: fieldName)
    }

    func visitConcatenate(_ expressions: [KeyExpression]) throws -> [any TupleElement] {
        var result: [any TupleElement] = []
        for expression in expressions {
            let values = try expression.accept(visitor: self)
            result.append(contentsOf: values)
        }
        return result
    }

    func visitLiteral(_ value: any TupleElement) throws -> [any TupleElement] {
        return [value]
    }

    func visitEmpty() throws -> [any TupleElement] {
        return []
    }

    func visitRangeBoundary(_ fieldName: String, _ component: RangeComponent) throws -> [any TupleElement] {
        return try DataAccess.extractRangeBoundary(
            from: item,
            keyPath: fieldName,
            component: component
        )
    }

    func visitNest(_ parentField: String, _ child: KeyExpression) throws -> [any TupleElement] {
        // For simple cases, combine parent and child with dot notation
        if let fieldExpr = child as? FieldKeyExpression {
            let nestedPath = "\(parentField).\(fieldExpr.fieldName)"
            return try DataAccess.extractField(from: item, keyPath: nestedPath)
        }

        // For other cases, delegate to child's accept method
        return try child.accept(visitor: self)
    }
}

// MARK: - Errors

/// Errors that can occur during DataAccess operations
public enum DataAccessError: Error, CustomStringConvertible {
    case fieldNotFound(itemType: String, keyPath: String)
    case nestedFieldsNotSupported(itemType: String, keyPath: String)
    case rangeFieldsNotSupported(itemType: String, suggestion: String)
    case reconstructionNotSupported(itemType: String, suggestion: String)
    case typeMismatch(itemType: String, keyPath: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .fieldNotFound(let itemType, let keyPath):
            return "Field '\(keyPath)' not found in \(itemType)"
        case .nestedFieldsNotSupported(let itemType, let keyPath):
            return "Nested field '\(keyPath)' not supported for \(itemType). Only top-level fields are currently supported."
        case .rangeFieldsNotSupported(let itemType, let suggestion):
            return "Range fields not supported for \(itemType). \(suggestion)"
        case .reconstructionNotSupported(let itemType, let suggestion):
            return "Reconstruction not supported for \(itemType). \(suggestion)"
        case .typeMismatch(let itemType, let keyPath, let expected, let actual):
            return "Type mismatch for field '\(keyPath)' in \(itemType): expected \(expected), got \(actual)"
        }
    }
}
