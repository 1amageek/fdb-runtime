import Foundation
import FoundationDB
import FDBIndexing

/// Protocol for accessing record metadata and fields
///
/// RecordAccess provides a unified interface for extracting metadata
/// and field values from records, regardless of their underlying representation
/// (structured records, documents, vectors, graphs, etc.).
///
/// **Responsibilities**:
/// - Extract record type name
/// - Evaluate KeyExpressions to get field values
/// - Serialize and deserialize records
/// - Extract range boundaries for Range-type fields
/// - Support covering index reconstruction (optional)
///
/// **Design**:
/// - Protocol definition only in FDBRuntime
/// - Concrete implementations in upper layers (fdb-record-layer, fdb-document-layer, etc.)
/// - Each data model layer provides its own implementations
///
/// **Implementation Examples**:
///
/// **For Record layer (fdb-record-layer)**:
/// ```swift
/// struct GenericRecordAccess<Record: Recordable>: RecordAccess {
///     func recordName(for record: Record) -> String {
///         return Record.recordName
///     }
///
///     func extractField(from record: Record, fieldName: String) throws -> [any TupleElement] {
///         // Use Mirror API or macro-generated code
///         return record.extractField(fieldName)
///     }
///
///     func serialize(_ record: Record) throws -> FDB.Bytes {
///         let encoder = ProtobufEncoder()
///         let data = try encoder.encode(record)
///         return Array(data)
///     }
///
///     func deserialize(_ bytes: FDB.Bytes) throws -> Record {
///         let decoder = ProtobufDecoder()
///         return try decoder.decode(Record.self, from: Data(bytes))
///     }
/// }
/// ```
///
/// **For Document layer (fdb-document-layer)**:
/// ```swift
/// struct DocumentAccess: RecordAccess {
///     typealias Record = Document
///
///     func recordName(for record: Document) -> String {
///         return record.collection
///     }
///
///     func extractField(from record: Document, fieldName: String) throws -> [any TupleElement] {
///         // Extract field from JSON-like structure
///         return record.get(fieldName)
///     }
///
///     func serialize(_ record: Document) throws -> FDB.Bytes {
///         return try JSONEncoder().encode(record)
///     }
///
///     func deserialize(_ bytes: FDB.Bytes) throws -> Document {
///         return try JSONDecoder().decode(Document.self, from: Data(bytes))
///     }
/// }
/// ```
public protocol RecordAccess<Record>: Sendable {
    associatedtype Record: Sendable

    // MARK: - Metadata

    /// Get the record type name
    ///
    /// The type name identifies the record type within the storage system.
    ///
    /// - Parameter record: The record to get the type name from
    /// - Returns: Record type name (e.g., "User", "Order", "Document")
    func recordName(for record: Record) -> String

    // MARK: - KeyExpression Evaluation

    /// Evaluate a KeyExpression to extract field values
    ///
    /// This method uses the Visitor pattern to traverse the KeyExpression tree
    /// and extract the corresponding values from the record.
    ///
    /// **Default Implementation**:
    /// A default implementation is provided that creates a RecordAccessEvaluator
    /// and uses it to traverse the KeyExpression tree. Implementations can
    /// override this if they need custom evaluation logic.
    ///
    /// - Parameters:
    ///   - record: The record to evaluate
    ///   - expression: The KeyExpression to evaluate
    /// - Returns: Array of tuple elements representing the extracted values
    /// - Throws: Error if field access fails
    func evaluate(
        record: Record,
        expression: KeyExpression
    ) throws -> [any TupleElement]

    /// Extract a single field value
    ///
    /// This method is called by the default KeyExpression evaluator.
    /// Concrete implementations must provide field access logic.
    ///
    /// **Field Name Format**:
    /// - Simple field: "email", "price"
    /// - Nested field: "user.address.city" (dot notation)
    ///
    /// - Parameters:
    ///   - record: The record to extract from
    ///   - fieldName: The field name (supports dot notation)
    /// - Returns: Array of tuple elements (typically single element)
    /// - Throws: Error if field not found or type conversion fails
    func extractField(
        from record: Record,
        fieldName: String
    ) throws -> [any TupleElement]

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
    /// **Default Implementation**:
    /// A default implementation throws an error. Upper layers should override
    /// this if they support Range-type fields.
    ///
    /// - Parameters:
    ///   - record: The record to extract from
    ///   - fieldName: The field name containing the Range type
    ///   - component: The boundary component to extract (lowerBound/upperBound)
    /// - Returns: Array containing the boundary value as TupleElement
    /// - Throws: Error if field not found or not a Range type
    func extractRangeBoundary(
        from record: Record,
        fieldName: String,
        component: RangeComponent
    ) throws -> [any TupleElement]

    // MARK: - Serialization

    /// Serialize a record to bytes
    ///
    /// The serialization format is implementation-dependent:
    /// - Record layer: Protobuf encoding
    /// - Document layer: JSON/BSON encoding
    /// - Vector layer: Custom binary format
    ///
    /// - Parameter record: The record to serialize
    /// - Returns: Serialized bytes
    /// - Throws: Error if serialization fails
    func serialize(_ record: Record) throws -> FDB.Bytes

    /// Deserialize bytes to a record
    ///
    /// - Parameter bytes: The bytes to deserialize
    /// - Returns: Deserialized record
    /// - Throws: Error if deserialization fails
    func deserialize(_ bytes: FDB.Bytes) throws -> Record

    // MARK: - Covering Index Support (Optional)

    /// Check if this RecordAccess supports reconstruction from covering indexes
    ///
    /// This allows the query planner to skip covering index plans
    /// for types that don't implement reconstruction.
    ///
    /// **Default**: false (safe, conservative)
    ///
    /// **Override**: Return true if reconstruct() is implemented
    var supportsReconstruction: Bool { get }

    /// Reconstruct a record from covering index key and value
    ///
    /// This method enables covering index optimization by reconstructing
    /// records directly from index data without fetching from storage.
    ///
    /// **Index Key Structure**: `<indexSubspace><rootExpression fields><primaryKey fields>`
    ///
    /// **Default Implementation**:
    /// Throws an error. Upper layers should override if they support covering indexes.
    ///
    /// - Parameters:
    ///   - indexKey: The index key (unpacked tuple)
    ///   - indexValue: The index value (packed covering fields)
    ///   - index: The index definition
    ///   - primaryKeyExpression: Primary key expression for field extraction
    /// - Returns: Reconstructed record
    /// - Throws: Error if reconstruction is not supported or fails
    func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record
}

// MARK: - Default Implementations

extension RecordAccess {
    /// Default implementation of evaluate using Visitor pattern
    ///
    /// This implementation creates a RecordAccessEvaluator and uses it
    /// to traverse the KeyExpression tree.
    ///
    /// - Parameters:
    ///   - record: The record to evaluate
    ///   - expression: The KeyExpression to evaluate
    /// - Returns: Array of tuple elements
    /// - Throws: Error if evaluation fails
    public func evaluate(
        record: Record,
        expression: KeyExpression
    ) throws -> [any TupleElement] {
        let visitor = RecordAccessEvaluator(recordAccess: self, record: record)
        return try expression.accept(visitor: visitor)
    }

    /// Extract primary key from a record using the primary key expression
    ///
    /// - Parameters:
    ///   - record: The record to extract from
    ///   - primaryKeyExpression: The KeyExpression defining the primary key
    /// - Returns: Tuple representing the primary key
    /// - Throws: Error if extraction fails
    public func extractPrimaryKey(
        from record: Record,
        using primaryKeyExpression: KeyExpression
    ) throws -> Tuple {
        let elements = try evaluate(record: record, expression: primaryKeyExpression)
        return Tuple(elements)
    }

    /// Default implementation of extractRangeBoundary
    ///
    /// This default implementation throws an error. Upper layers should override
    /// if they support Range-type fields.
    ///
    /// - Parameters:
    ///   - record: The record to extract from
    ///   - fieldName: The field name containing the Range type
    ///   - component: The boundary component to extract
    /// - Returns: Array containing the boundary value
    /// - Throws: Error indicating Range fields are not supported
    public func extractRangeBoundary(
        from record: Record,
        fieldName: String,
        component: RangeComponent
    ) throws -> [any TupleElement] {
        throw RecordAccessError.rangeFieldsNotSupported(
            recordType: String(describing: Record.self),
            suggestion: "Override extractRangeBoundary() to support Range-type fields"
        )
    }

    /// Default implementation of supportsReconstruction
    ///
    /// Returns false by default. Upper layers should override if they support
    /// covering index reconstruction.
    ///
    /// - Returns: false (not supported by default)
    public var supportsReconstruction: Bool {
        return false
    }

    /// Default implementation of reconstruct
    ///
    /// This default implementation throws an error. Upper layers should override
    /// if they support covering index reconstruction.
    ///
    /// - Parameters:
    ///   - indexKey: The index key
    ///   - indexValue: The index value
    ///   - index: The index definition
    ///   - primaryKeyExpression: Primary key expression
    /// - Returns: Reconstructed record
    /// - Throws: Error indicating reconstruction is not supported
    public func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record {
        throw RecordAccessError.reconstructionNotSupported(
            recordType: String(describing: Record.self),
            suggestion: """
            To use covering indexes with this record type, override reconstruct().
            Set supportsReconstruction to true when reconstruction is implemented.
            """
        )
    }
}

// MARK: - RecordAccessEvaluator

/// Visitor that evaluates KeyExpressions using RecordAccess
///
/// This visitor traverses a KeyExpression tree and extracts values from a record
/// using the provided RecordAccess implementation.
private struct RecordAccessEvaluator<Access: RecordAccess>: KeyExpressionVisitor {
    let recordAccess: Access
    let record: Access.Record

    typealias Result = [any TupleElement]

    func visitField(_ fieldName: String) throws -> [any TupleElement] {
        return try recordAccess.extractField(from: record, fieldName: fieldName)
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
        return try recordAccess.extractRangeBoundary(
            from: record,
            fieldName: fieldName,
            component: component
        )
    }

    func visitNest(_ parentField: String, _ child: KeyExpression) throws -> [any TupleElement] {
        // For simple cases, combine parent and child with dot notation
        if let fieldExpr = child as? FieldKeyExpression {
            let nestedPath = "\(parentField).\(fieldExpr.fieldName)"
            return try recordAccess.extractField(from: record, fieldName: nestedPath)
        }

        // For other cases, delegate to child's accept method
        return try child.accept(visitor: self)
    }
}

// MARK: - Errors

/// Errors that can occur during RecordAccess operations
public enum RecordAccessError: Error {
    case rangeFieldsNotSupported(recordType: String, suggestion: String)
    case reconstructionNotSupported(recordType: String, suggestion: String)
    case fieldNotFound(recordType: String, fieldName: String)
    case typeMismatch(recordType: String, fieldName: String, expected: String, actual: String)
}
