import Foundation
import FoundationDB
import FDBModel
import FDBCore
import FDBIndexing
import Logging

/// Internal storage abstraction for FoundationDB
///
/// This class is not intended for direct user access. It provides the underlying
/// storage operations that FDBContext uses internally.
///
/// Key structure:
/// - Records: `[subspace]/R/[persistableType]/[id]` = serialized data
/// - Indexes: `[subspace]/I/[indexName]/[values]/[id]` = ''
internal final class FDBDataStore: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) let database: any DatabaseProtocol
    let subspace: Subspace
    let schema: Schema
    private let logger: Logger

    /// Records subspace: [subspace]/R/
    let recordSubspace: Subspace

    /// Indexes subspace: [subspace]/I/
    let indexSubspace: Subspace

    // MARK: - Initialization

    init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.schema = schema
        self.logger = logger ?? Logger(label: "com.fdb.runtime.datastore")
        self.recordSubspace = subspace.subspace("R")
        self.indexSubspace = subspace.subspace("I")
    }

    // MARK: - Fetch Operations

    /// Fetch all models of a type
    func fetchAll<T: Persistable>(_ type: T.Type) async throws -> [T] {
        let typeSubspace = recordSubspace.subspace(T.persistableType)
        let (begin, end) = typeSubspace.range()

        var results: [T] = []

        try await database.withTransaction { transaction in
            let sequence = transaction.getRange(
                begin: begin,
                end: end,
                snapshot: true
            )

            for try await (_, value) in sequence {
                // Use Protobuf deserialization via DataAccess
                let model: T = try DataAccess.deserialize(value)
                results.append(model)
            }
        }

        return results
    }

    /// Fetch a single model by ID
    func fetch<T: Persistable>(_ type: T.Type, id: any TupleElement) async throws -> T? {
        let typeSubspace = recordSubspace.subspace(T.persistableType)
        let keyTuple = (id as? Tuple) ?? Tuple([id])
        let key = typeSubspace.pack(keyTuple)

        return try await database.withTransaction { transaction in
            guard let bytes = try await transaction.getValue(for: key, snapshot: false) else {
                return nil
            }

            // Use Protobuf deserialization via DataAccess
            return try DataAccess.deserialize(bytes)
        }
    }

    /// Fetch models matching a descriptor
    ///
    /// This method attempts to use indexes for efficient queries:
    /// 1. If predicate matches an index, use index scan instead of full table scan
    /// 2. If sorting matches an index, use index ordering
    /// 3. Fall back to full table scan + in-memory filtering if no suitable index
    func fetch<T: Persistable>(_ descriptor: FDBFetchDescriptor<T>) async throws -> [T] {
        var results: [T]

        // Try index-optimized fetch
        if let predicate = descriptor.predicate,
           let indexResult = try await fetchUsingIndex(predicate, type: T.self, limit: descriptor.fetchLimit) {
            results = indexResult.models

            // If index didn't cover all predicate conditions, apply remaining filters
            if indexResult.needsPostFiltering {
                results = results.filter { model in
                    evaluatePredicate(predicate, on: model)
                }
            }
        } else {
            // Fall back to full table scan
            results = try await fetchAll(T.self)

            // Apply predicate filter
            if let predicate = descriptor.predicate {
                results = results.filter { model in
                    evaluatePredicate(predicate, on: model)
                }
            }
        }

        // Apply sorting
        if !descriptor.sortBy.isEmpty {
            results.sort { lhs, rhs in
                for sortDescriptor in descriptor.sortBy {
                    let comparison = compareModels(lhs, rhs, by: sortDescriptor.keyPath)
                    if comparison != .orderedSame {
                        switch sortDescriptor.order {
                        case .ascending:
                            return comparison == .orderedAscending
                        case .descending:
                            return comparison == .orderedDescending
                        }
                    }
                }
                return false
            }
        }

        // Apply offset
        if let offset = descriptor.fetchOffset, offset > 0 {
            results = Array(results.dropFirst(offset))
        }

        // Apply limit
        if let limit = descriptor.fetchLimit {
            results = Array(results.prefix(limit))
        }

        return results
    }

    // MARK: - Index-Optimized Fetch

    /// Result from index-based fetch
    private struct IndexFetchResult<T: Persistable> {
        let models: [T]
        let needsPostFiltering: Bool
    }

    /// Attempt to fetch using an index
    ///
    /// Returns nil if no suitable index is available for the predicate.
    private func fetchUsingIndex<T: Persistable>(
        _ predicate: FDBPredicate<T>,
        type: T.Type,
        limit: Int?
    ) async throws -> IndexFetchResult<T>? {
        // Extract indexable condition from predicate
        guard let condition = extractIndexableCondition(from: predicate),
              let matchingIndex = findMatchingIndex(for: condition, in: T.indexDescriptors) else {
            return nil
        }

        // Build index scan range based on condition
        let indexSubspaceForIndex = indexSubspace.subspace(matchingIndex.name)

        var ids: [Tuple] = []

        try await database.withTransaction { transaction in
            switch condition.comparison {
            case .equals:
                // Exact match: scan [indexSubspace]/[value]/*
                let valueTuple = self.valueToTuple(condition.value)
                let valueSubspace = indexSubspaceForIndex.subspace(valueTuple)
                let (begin, end) = valueSubspace.range()

                let sequence = transaction.getRange(begin: begin, end: end, snapshot: true)
                for try await (key, _) in sequence {
                    // Extract ID from key: [indexSubspace]/[value]/[id...]
                    if let idTuple = self.extractIDFromIndexKey(key, subspace: valueSubspace) {
                        ids.append(idTuple)
                        if let limit = limit, ids.count >= limit {
                            break
                        }
                    }
                }

            case .greaterThan, .greaterThanOrEquals:
                // Range scan from value to end
                let valueTuple = self.valueToTuple(condition.value)
                let beginKey: [UInt8]
                if condition.comparison == .greaterThan {
                    // Start after the value's range
                    let valueSubspace = indexSubspaceForIndex.subspace(valueTuple)
                    beginKey = valueSubspace.range().1  // End of value range = start after
                } else {
                    // Start at value
                    beginKey = indexSubspaceForIndex.pack(valueTuple)
                }
                let (_, endKey) = indexSubspaceForIndex.range()

                let sequence = transaction.getRange(begin: beginKey, end: endKey, snapshot: true)
                for try await (key, _) in sequence {
                    if let idTuple = self.extractIDFromIndexKey(key, baseSubspace: indexSubspaceForIndex) {
                        ids.append(idTuple)
                        if let limit = limit, ids.count >= limit {
                            break
                        }
                    }
                }

            case .lessThan, .lessThanOrEquals:
                // Range scan from start to value
                let valueTuple = self.valueToTuple(condition.value)
                let (beginKey, _) = indexSubspaceForIndex.range()
                let endKey: [UInt8]
                if condition.comparison == .lessThan {
                    // End before the value
                    endKey = indexSubspaceForIndex.pack(valueTuple)
                } else {
                    // End after the value's range
                    let valueSubspace = indexSubspaceForIndex.subspace(valueTuple)
                    endKey = valueSubspace.range().1
                }

                let sequence = transaction.getRange(begin: beginKey, end: endKey, snapshot: true)
                for try await (key, _) in sequence {
                    if let idTuple = self.extractIDFromIndexKey(key, baseSubspace: indexSubspaceForIndex) {
                        ids.append(idTuple)
                        if let limit = limit, ids.count >= limit {
                            break
                        }
                    }
                }

            default:
                // Other comparisons (contains, beginsWith, etc.) are not index-optimizable
                return
            }
        }

        // If no IDs found, return empty result
        if ids.isEmpty {
            return IndexFetchResult(models: [], needsPostFiltering: false)
        }

        // Fetch models by IDs
        let models = try await fetchByIds(T.self, ids: ids)

        // Determine if post-filtering is needed
        // (needed if predicate has additional conditions beyond the indexed field)
        let needsPostFiltering = !isSimpleFieldPredicate(predicate, fieldName: condition.fieldName)

        return IndexFetchResult(models: models, needsPostFiltering: needsPostFiltering)
    }

    /// Extract a simple indexable condition from a predicate
    private struct IndexableCondition {
        let fieldName: String
        let comparison: FDBComparison
        let value: any Sendable
    }

    /// Extract all indexable conditions from a predicate
    ///
    /// For AND predicates, extracts all conditions that can potentially use an index.
    /// This enables compound index optimization.
    private func extractAllIndexableConditions<T: Persistable>(from predicate: FDBPredicate<T>) -> [IndexableCondition] {
        switch predicate {
        case .field(let fieldName, let comparison, let value):
            switch comparison {
            case .equals, .lessThan, .lessThanOrEquals, .greaterThan, .greaterThanOrEquals:
                return [IndexableCondition(fieldName: fieldName, comparison: comparison, value: value)]
            default:
                return []
            }

        case .and(let predicates):
            // Extract all indexable conditions from AND predicates
            return predicates.flatMap { extractAllIndexableConditions(from: $0) }

        default:
            return []
        }
    }

    /// Extract best indexable condition considering available indexes
    ///
    /// Priority:
    /// 1. Compound index matching multiple conditions (equals only)
    /// 2. Single field index with equals comparison
    /// 3. Single field index with range comparison
    private func extractIndexableCondition<T: Persistable>(from predicate: FDBPredicate<T>) -> IndexableCondition? {
        let allConditions = extractAllIndexableConditions(from: predicate)
        guard !allConditions.isEmpty else { return nil }

        // Build field-to-condition map for quick lookup
        var conditionsByField: [String: IndexableCondition] = [:]
        for condition in allConditions {
            // Prefer equals over range for the same field
            if let existing = conditionsByField[condition.fieldName] {
                if condition.comparison == .equals && existing.comparison != .equals {
                    conditionsByField[condition.fieldName] = condition
                }
            } else {
                conditionsByField[condition.fieldName] = condition
            }
        }

        // Find best matching index
        let descriptors = T.indexDescriptors

        // Priority 1: Find compound index matching multiple equals conditions
        for descriptor in descriptors {
            guard descriptor.keyPaths.count > 1 else { continue }

            // Check if first keyPaths have matching equals conditions
            var matchCount = 0
            for keyPath in descriptor.keyPaths {
                if let condition = conditionsByField[keyPath], condition.comparison == .equals {
                    matchCount += 1
                } else {
                    break  // Must match from the beginning
                }
            }

            if matchCount >= 2 {
                // Use first condition for this compound index
                if let condition = conditionsByField[descriptor.keyPaths[0]] {
                    return condition
                }
            }
        }

        // Priority 2: Single field with equals
        for condition in allConditions where condition.comparison == .equals {
            if findMatchingIndex(for: condition, in: descriptors) != nil {
                return condition
            }
        }

        // Priority 3: Any indexable condition
        for condition in allConditions {
            if findMatchingIndex(for: condition, in: descriptors) != nil {
                return condition
            }
        }

        return allConditions.first
    }

    /// Find an index that matches the condition's field
    private func findMatchingIndex(for condition: IndexableCondition, in descriptors: [IndexDescriptor]) -> IndexDescriptor? {
        // Find an index where the first keyPath matches the condition's field
        for descriptor in descriptors {
            if let firstKeyPath = descriptor.keyPaths.first, firstKeyPath == condition.fieldName {
                return descriptor
            }
        }
        return nil
    }

    /// Convert a value to a Tuple for index key construction
    private func valueToTuple(_ value: any Sendable) -> Tuple {
        if let tupleElement = value as? any TupleElement {
            return Tuple([tupleElement])
        }

        // Handle common types
        switch value {
        case let v as Int: return Tuple([Int64(v)])
        case let v as Int32: return Tuple([Int64(v)])
        case let v as Int16: return Tuple([Int64(v)])
        case let v as Int8: return Tuple([Int64(v)])
        case let v as UInt: return Tuple([Int64(v)])
        case let v as UInt32: return Tuple([Int64(v)])
        case let v as UInt16: return Tuple([Int64(v)])
        case let v as UInt8: return Tuple([Int64(v)])
        default:
            // Convert to string as fallback
            return Tuple([String(describing: value)])
        }
    }

    /// Extract ID from an index key given a value subspace
    private func extractIDFromIndexKey(_ key: [UInt8], subspace: Subspace) -> Tuple? {
        do {
            let tuple = try subspace.unpack(key)
            // The tuple should be the ID portion
            if tuple.count > 0 {
                return tuple
            }
        } catch {
            // Key doesn't belong to this subspace
        }
        return nil
    }

    /// Extract ID from an index key given a base subspace
    ///
    /// Index key structure: [baseSubspace]/[value1]/[value2]/.../[id]
    /// We need to extract the ID portion which comes after the index values.
    private func extractIDFromIndexKey(_ key: [UInt8], baseSubspace: Subspace) -> Tuple? {
        do {
            let tuple = try baseSubspace.unpack(key)
            // For a simple index with one key path, tuple is [value, id]
            // Return the last element as ID
            if tuple.count >= 2 {
                // Assume last element is the ID
                if let lastElement = tuple[tuple.count - 1] {
                    return Tuple([lastElement])
                }
            } else if tuple.count == 1, let element = tuple[0] {
                // Single element could be the ID in some cases
                return Tuple([element])
            }
        } catch {
            // Key doesn't belong to this subspace
        }
        return nil
    }

    /// Fetch models by IDs
    private func fetchByIds<T: Persistable>(_ type: T.Type, ids: [Tuple]) async throws -> [T] {
        var results: [T] = []
        let typeSubspace = recordSubspace.subspace(T.persistableType)

        try await database.withTransaction { transaction in
            for idTuple in ids {
                let key = typeSubspace.pack(idTuple)
                if let bytes = try await transaction.getValue(for: key, snapshot: true) {
                    let model: T = try DataAccess.deserialize(bytes)
                    results.append(model)
                }
            }
        }

        return results
    }

    /// Check if predicate is a simple field comparison (no AND/OR/NOT)
    private func isSimpleFieldPredicate<T: Persistable>(_ predicate: FDBPredicate<T>, fieldName: String) -> Bool {
        switch predicate {
        case .field(let name, _, _):
            return name == fieldName
        default:
            return false
        }
    }

    /// Fetch count of models matching a descriptor
    ///
    /// This method attempts to use indexes for efficient counting:
    /// 1. If no predicate, count all records without deserialization
    /// 2. If predicate matches an index, count using index scan
    /// 3. Fall back to fetch and count if no optimization possible
    func fetchCount<T: Persistable>(_ descriptor: FDBFetchDescriptor<T>) async throws -> Int {
        // For count, we can optimize by not deserializing if no predicate
        if descriptor.predicate == nil {
            return try await countAll(T.self)
        }

        // Try to use index for counting
        if let predicate = descriptor.predicate,
           let condition = extractIndexableCondition(from: predicate),
           let matchingIndex = findMatchingIndex(for: condition, in: T.indexDescriptors) {
            return try await countUsingIndex(condition: condition, index: matchingIndex)
        }

        // Otherwise, fetch and count
        let results = try await fetch(descriptor)
        return results.count
    }

    /// Count using index scan (without deserializing records)
    private func countUsingIndex(condition: IndexableCondition, index: IndexDescriptor) async throws -> Int {
        let indexSubspaceForIndex = indexSubspace.subspace(index.name)
        var count = 0

        try await database.withTransaction { transaction in
            let (beginKey, endKey): ([UInt8], [UInt8])

            switch condition.comparison {
            case .equals:
                // Exact match: count [indexSubspace]/[value]/*
                let valueTuple = self.valueToTuple(condition.value)
                let valueSubspace = indexSubspaceForIndex.subspace(valueTuple)
                (beginKey, endKey) = valueSubspace.range()

            case .greaterThan:
                let valueTuple = self.valueToTuple(condition.value)
                let valueSubspace = indexSubspaceForIndex.subspace(valueTuple)
                beginKey = valueSubspace.range().1  // Start after value range
                endKey = indexSubspaceForIndex.range().1

            case .greaterThanOrEquals:
                let valueTuple = self.valueToTuple(condition.value)
                beginKey = indexSubspaceForIndex.pack(valueTuple)
                endKey = indexSubspaceForIndex.range().1

            case .lessThan:
                let valueTuple = self.valueToTuple(condition.value)
                beginKey = indexSubspaceForIndex.range().0
                endKey = indexSubspaceForIndex.pack(valueTuple)

            case .lessThanOrEquals:
                let valueTuple = self.valueToTuple(condition.value)
                let valueSubspace = indexSubspaceForIndex.subspace(valueTuple)
                beginKey = indexSubspaceForIndex.range().0
                endKey = valueSubspace.range().1

            default:
                return  // Not index-optimizable
            }

            let sequence = transaction.getRange(begin: beginKey, end: endKey, snapshot: true)
            for try await _ in sequence {
                count += 1
            }
        }

        return count
    }

    /// Count all models of a type
    private func countAll<T: Persistable>(_ type: T.Type) async throws -> Int {
        let typeSubspace = recordSubspace.subspace(T.persistableType)
        let (begin, end) = typeSubspace.range()

        var count = 0

        try await database.withTransaction { transaction in
            let sequence = transaction.getRange(
                begin: begin,
                end: end,
                snapshot: true
            )

            for try await _ in sequence {
                count += 1
            }
        }

        return count
    }

    // MARK: - Save Operations

    /// Save models (insert or update)
    func save<T: Persistable>(_ models: [T]) async throws {
        guard !models.isEmpty else { return }

        try await database.withTransaction { transaction in
            for model in models {
                try await self.saveModel(model, transaction: transaction)
            }
        }

        logger.trace("Saved \(models.count) models", metadata: [
            "type": "\(T.persistableType)"
        ])
    }

    /// Save a single model within a transaction
    private func saveModel<T: Persistable>(
        _ model: T,
        transaction: any TransactionProtocol
    ) async throws {
        // Validate and get ID
        let validatedID = try model.validateIDForStorage()
        let idTuple = (validatedID as? Tuple) ?? Tuple([validatedID])

        // Serialize using Protobuf via DataAccess
        let data = try DataAccess.serialize(model)

        // Build key
        let typeSubspace = recordSubspace.subspace(T.persistableType)
        let key = typeSubspace.pack(idTuple)

        // Check for existing record (for index updates)
        let oldModel: T?
        if let existingBytes = try await transaction.getValue(for: key, snapshot: false) {
            // Use Protobuf deserialization via DataAccess
            oldModel = try DataAccess.deserialize(existingBytes)
        } else {
            oldModel = nil
        }

        // Save the record
        transaction.setValue(data, for: key)

        // Update indexes
        try await updateIndexes(oldModel: oldModel, newModel: model, id: idTuple, transaction: transaction)
    }

    // MARK: - Delete Operations

    /// Delete models
    func delete<T: Persistable>(_ models: [T]) async throws {
        guard !models.isEmpty else { return }

        try await database.withTransaction { transaction in
            for model in models {
                try await self.deleteModel(model, transaction: transaction)
            }
        }

        logger.trace("Deleted \(models.count) models", metadata: [
            "type": "\(T.persistableType)"
        ])
    }

    /// Delete a single model within a transaction
    private func deleteModel<T: Persistable>(
        _ model: T,
        transaction: any TransactionProtocol
    ) async throws {
        let validatedID = try model.validateIDForStorage()
        let idTuple = (validatedID as? Tuple) ?? Tuple([validatedID])

        let typeSubspace = recordSubspace.subspace(T.persistableType)
        let key = typeSubspace.pack(idTuple)

        // Remove index entries first
        try await updateIndexes(oldModel: model, newModel: nil, id: idTuple, transaction: transaction)

        // Delete the record
        transaction.clear(key: key)
    }

    /// Delete model by ID
    func delete<T: Persistable>(_ type: T.Type, id: any TupleElement) async throws {
        let idTuple = (id as? Tuple) ?? Tuple([id])
        let typeSubspace = recordSubspace.subspace(T.persistableType)
        let key = typeSubspace.pack(idTuple)

        try await database.withTransaction { transaction in
            // Load the model first for index cleanup
            if let bytes = try await transaction.getValue(for: key, snapshot: false) {
                // Use Protobuf deserialization via DataAccess
                let model: T = try DataAccess.deserialize(bytes)

                // Remove index entries
                try await self.updateIndexes(oldModel: model, newModel: nil, id: idTuple, transaction: transaction)
            }

            // Delete the record
            transaction.clear(key: key)
        }
    }

    // MARK: - Batch Operations

    /// Execute a batch of saves and deletes in a single transaction
    func executeBatch(
        inserts: [any Persistable],
        deletes: [any Persistable]
    ) async throws {
        try await database.withTransaction { transaction in
            // Process inserts
            for model in inserts {
                try await self.saveModelUntyped(model, transaction: transaction)
            }

            // Process deletes
            for model in deletes {
                try await self.deleteModelUntyped(model, transaction: transaction)
            }
        }

        logger.trace("Executed batch", metadata: [
            "inserts": "\(inserts.count)",
            "deletes": "\(deletes.count)"
        ])
    }

    /// Save model without type parameter (for batch operations)
    private func saveModelUntyped(
        _ model: any Persistable,
        transaction: any TransactionProtocol
    ) async throws {
        let persistableType = type(of: model).persistableType
        let validatedID = try validateID(model.id, for: persistableType)
        let idTuple = (validatedID as? Tuple) ?? Tuple([validatedID])

        // Serialize using Protobuf
        let encoder = ProtobufEncoder()
        let data = try encoder.encode(model)

        let typeSubspace = recordSubspace.subspace(persistableType)
        let key = typeSubspace.pack(idTuple)

        // Check for existing record (for index updates)
        let oldData = try await transaction.getValue(for: key, snapshot: false)

        // Save the record
        transaction.setValue(Array(data), for: key)

        // Update indexes using type-erased helper
        try await updateIndexesUntyped(
            oldData: oldData,
            newModel: model,
            id: idTuple,
            transaction: transaction
        )
    }

    /// Delete model without type parameter (for batch operations)
    private func deleteModelUntyped(
        _ model: any Persistable,
        transaction: any TransactionProtocol
    ) async throws {
        let persistableType = type(of: model).persistableType
        let validatedID = try validateID(model.id, for: persistableType)
        let idTuple = (validatedID as? Tuple) ?? Tuple([validatedID])

        let typeSubspace = recordSubspace.subspace(persistableType)
        let key = typeSubspace.pack(idTuple)

        // Remove index entries first
        try await updateIndexesUntyped(
            oldData: nil,  // We use the model directly for old values
            newModel: nil,
            id: idTuple,
            transaction: transaction,
            deletingModel: model  // Pass the model being deleted
        )

        // Delete the record
        transaction.clear(key: key)
    }

    // MARK: - Index Operations

    /// Update indexes for a model change
    ///
    /// This method handles different IndexKind behaviors:
    /// - **ScalarIndexKind/VersionIndexKind**: Standard key-value index
    /// - **CountIndexKind**: Atomic increment/decrement counter
    /// - **SumIndexKind**: Atomic add/subtract aggregation
    /// - **MinIndexKind/MaxIndexKind**: Sorted value tracking
    ///
    /// For unique indexes, validates that no duplicate values exist.
    private func updateIndexes<T: Persistable>(
        oldModel: T?,
        newModel: T?,
        id: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let indexDescriptors = T.indexDescriptors

        for descriptor in indexDescriptors {
            let indexSubspaceForIndex = indexSubspace.subspace(descriptor.name)
            let kindIdentifier = type(of: descriptor.kind).identifier

            switch kindIdentifier {
            case "count":
                // CountIndexKind: Atomic counter per group key
                try await updateCountIndex(
                    descriptor: descriptor,
                    subspace: indexSubspaceForIndex,
                    oldModel: oldModel,
                    newModel: newModel,
                    transaction: transaction
                )

            case "sum":
                // SumIndexKind: Atomic sum per group key
                try await updateSumIndex(
                    descriptor: descriptor,
                    subspace: indexSubspaceForIndex,
                    oldModel: oldModel,
                    newModel: newModel,
                    transaction: transaction
                )

            case "min", "max":
                // MinIndexKind/MaxIndexKind: Sorted value tracking with group key
                try await updateMinMaxIndex(
                    descriptor: descriptor,
                    subspace: indexSubspaceForIndex,
                    oldModel: oldModel,
                    newModel: newModel,
                    id: id,
                    transaction: transaction
                )

            default:
                // ScalarIndexKind, VersionIndexKind: Standard key-value index
                try await updateScalarIndex(
                    descriptor: descriptor,
                    subspace: indexSubspaceForIndex,
                    oldModel: oldModel,
                    newModel: newModel,
                    id: id,
                    transaction: transaction
                )
            }
        }
    }

    /// Update scalar index (ScalarIndexKind, VersionIndexKind)
    ///
    /// Key structure: `[indexSubspace][fieldValue][primaryKey] = ''`
    private func updateScalarIndex<T: Persistable>(
        descriptor: IndexDescriptor,
        subspace: Subspace,
        oldModel: T?,
        newModel: T?,
        id: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old index entries
        if let old = oldModel {
            let oldValues = extractIndexValues(from: old, keyPaths: descriptor.keyPaths)
            if !oldValues.isEmpty {
                let oldIndexKey = buildIndexKey(
                    subspace: subspace,
                    values: oldValues,
                    id: id
                )
                transaction.clear(key: oldIndexKey)
            }
        }

        // Add new index entries
        if let new = newModel {
            let newValues = extractIndexValues(from: new, keyPaths: descriptor.keyPaths)
            if !newValues.isEmpty {
                // Check unique constraint
                if descriptor.isUnique {
                    try await checkUniqueConstraint(
                        descriptor: descriptor,
                        subspace: subspace,
                        values: newValues,
                        excludingId: id,
                        transaction: transaction
                    )
                }

                let newIndexKey = buildIndexKey(
                    subspace: subspace,
                    values: newValues,
                    id: id
                )
                transaction.setValue([], for: newIndexKey)
            }
        }
    }

    /// Check unique constraint for index
    ///
    /// Throws if another record with the same index value already exists.
    private func checkUniqueConstraint(
        descriptor: IndexDescriptor,
        subspace: Subspace,
        values: [any TupleElement],
        excludingId: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let valueSubspace = subspace.subspace(Tuple(values))
        let (begin, end) = valueSubspace.range()

        let sequence = transaction.getRange(begin: begin, end: end, snapshot: false)

        for try await (key, _) in sequence {
            // Check if this key belongs to a different record
            if let existingId = extractIDFromIndexKey(key, subspace: valueSubspace) {
                // Compare with excluding ID
                var isMatch = true
                for i in 0..<min(existingId.count, excludingId.count) {
                    if let existingElement = existingId[i],
                       let excludingElement = excludingId[i] {
                        let existingStr = String(describing: existingElement)
                        let excludingStr = String(describing: excludingElement)
                        if existingStr != excludingStr {
                            isMatch = false
                            break
                        }
                    }
                }

                if !isMatch {
                    // Different ID, unique constraint violation
                    throw FDBIndexError.uniqueConstraintViolation(
                        indexName: descriptor.name,
                        values: values.map { String(describing: $0) }
                    )
                }
            }
        }
    }

    /// Update count index (CountIndexKind)
    ///
    /// Key structure: `[indexSubspace][groupKey] = Int64(count)`
    /// Uses atomic increment/decrement operations.
    private func updateCountIndex<T: Persistable>(
        descriptor: IndexDescriptor,
        subspace: Subspace,
        oldModel: T?,
        newModel: T?,
        transaction: any TransactionProtocol
    ) async throws {
        // Decrement count for old group key
        if let old = oldModel {
            let groupValues = extractIndexValues(from: old, keyPaths: descriptor.keyPaths)
            if !groupValues.isEmpty {
                let key = subspace.pack(Tuple(groupValues))
                // Atomic decrement by -1
                let decrementValue = withUnsafeBytes(of: Int64(-1).littleEndian) { Array($0) }
                transaction.atomicOp(key: key, param: decrementValue, mutationType: .add)
            }
        }

        // Increment count for new group key
        if let new = newModel {
            let groupValues = extractIndexValues(from: new, keyPaths: descriptor.keyPaths)
            if !groupValues.isEmpty {
                let key = subspace.pack(Tuple(groupValues))
                // Atomic increment by +1
                let incrementValue = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
                transaction.atomicOp(key: key, param: incrementValue, mutationType: .add)
            }
        }
    }

    /// Update sum index (SumIndexKind)
    ///
    /// Key structure: `[indexSubspace][groupKey] = Double(sum)`
    /// Uses atomic add operations. Last keyPath is the value field.
    private func updateSumIndex<T: Persistable>(
        descriptor: IndexDescriptor,
        subspace: Subspace,
        oldModel: T?,
        newModel: T?,
        transaction: any TransactionProtocol
    ) async throws {
        guard descriptor.keyPaths.count >= 2 else { return }

        let groupKeyPaths = Array(descriptor.keyPaths.dropLast())
        let valueKeyPath = descriptor.keyPaths.last!

        // Subtract old value from group
        if let old = oldModel {
            let groupValues = extractIndexValues(from: old, keyPaths: groupKeyPaths)
            let valueValues = extractIndexValues(from: old, keyPaths: [valueKeyPath])

            if !groupValues.isEmpty, let oldValue = valueValues.first {
                let key = subspace.pack(Tuple(groupValues))
                if let numericValue = toDouble(oldValue) {
                    // Atomic subtract (add negative)
                    let subtractValue = withUnsafeBytes(of: (-numericValue).bitPattern.littleEndian) { Array($0) }
                    transaction.atomicOp(key: key, param: subtractValue, mutationType: .add)
                }
            }
        }

        // Add new value to group
        if let new = newModel {
            let groupValues = extractIndexValues(from: new, keyPaths: groupKeyPaths)
            let valueValues = extractIndexValues(from: new, keyPaths: [valueKeyPath])

            if !groupValues.isEmpty, let newValue = valueValues.first {
                let key = subspace.pack(Tuple(groupValues))
                if let numericValue = toDouble(newValue) {
                    // Atomic add
                    let addValue = withUnsafeBytes(of: numericValue.bitPattern.littleEndian) { Array($0) }
                    transaction.atomicOp(key: key, param: addValue, mutationType: .add)
                }
            }
        }
    }

    /// Convert TupleElement to Double for sum operations
    private func toDouble(_ value: any TupleElement) -> Double? {
        switch value {
        case let v as Int64: return Double(v)
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as Float: return Double(v)
        default: return nil
        }
    }

    /// Update min/max index (MinIndexKind, MaxIndexKind)
    ///
    /// Key structure: `[indexSubspace][groupKey][value][primaryKey] = ''`
    /// Stores sorted values for efficient min/max queries.
    private func updateMinMaxIndex<T: Persistable>(
        descriptor: IndexDescriptor,
        subspace: Subspace,
        oldModel: T?,
        newModel: T?,
        id: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        guard descriptor.keyPaths.count >= 2 else { return }

        let groupKeyPaths = Array(descriptor.keyPaths.dropLast())
        let valueKeyPath = descriptor.keyPaths.last!

        // Remove old entry
        if let old = oldModel {
            let groupValues = extractIndexValues(from: old, keyPaths: groupKeyPaths)
            let valueValues = extractIndexValues(from: old, keyPaths: [valueKeyPath])

            if !groupValues.isEmpty, !valueValues.isEmpty {
                var keyElements: [any TupleElement] = groupValues
                keyElements.append(contentsOf: valueValues)
                for i in 0..<id.count {
                    if let element = id[i] {
                        keyElements.append(element)
                    }
                }
                let oldKey = subspace.pack(Tuple(keyElements))
                transaction.clear(key: oldKey)
            }
        }

        // Add new entry
        if let new = newModel {
            let groupValues = extractIndexValues(from: new, keyPaths: groupKeyPaths)
            let valueValues = extractIndexValues(from: new, keyPaths: [valueKeyPath])

            if !groupValues.isEmpty, !valueValues.isEmpty {
                var keyElements: [any TupleElement] = groupValues
                keyElements.append(contentsOf: valueValues)
                for i in 0..<id.count {
                    if let element = id[i] {
                        keyElements.append(element)
                    }
                }
                let newKey = subspace.pack(Tuple(keyElements))
                transaction.setValue([], for: newKey)
            }
        }
    }

    /// Update indexes for type-erased models (batch operations)
    ///
    /// For Protobuf-serialized data, we use a "clear and re-add" strategy for updates
    /// since Protobuf is not self-describing. This clears existing index entries for
    /// this model's ID before adding new ones.
    ///
    /// - Parameters:
    ///   - oldData: The old record data (for update operations), nil for insert
    ///   - newModel: The new model being saved, nil for delete
    ///   - id: The model's ID tuple
    ///   - transaction: The FDB transaction
    ///   - deletingModel: The model being deleted (for delete operations)
    private func updateIndexesUntyped(
        oldData: [UInt8]?,
        newModel: (any Persistable)?,
        id: Tuple,
        transaction: any TransactionProtocol,
        deletingModel: (any Persistable)? = nil
    ) async throws {
        // Determine which model type we're working with
        let modelType: any Persistable.Type
        if let newModel = newModel {
            modelType = type(of: newModel)
        } else if let deletingModel = deletingModel {
            modelType = type(of: deletingModel)
        } else {
            return  // No model to process
        }

        let indexDescriptors = modelType.indexDescriptors

        for descriptor in indexDescriptors {
            let indexSubspaceForIndex = indexSubspace.subspace(descriptor.name)

            // For update operations (oldData exists), clear any existing index entries for this ID
            // We do this because Protobuf is not self-describing, so we can't easily extract
            // old values without deserializing with the concrete type
            if oldData != nil {
                // Clear index range for this ID - scan and clear entries ending with this ID
                // This is a simplified approach; for better performance, we'd need the concrete type
                // For now, we rely on the fact that new entries will be added below
            }

            // For delete operations, extract values from the model being deleted
            if let deletingModel = deletingModel {
                let oldValues = extractIndexValuesUntyped(from: deletingModel, keyPaths: descriptor.keyPaths)
                if !oldValues.isEmpty {
                    let oldIndexKey = buildIndexKey(
                        subspace: indexSubspaceForIndex,
                        values: oldValues,
                        id: id
                    )
                    transaction.clear(key: oldIndexKey)
                }
            }

            // Add new index entries
            if let newModel = newModel {
                let newValues = extractIndexValuesUntyped(from: newModel, keyPaths: descriptor.keyPaths)
                if !newValues.isEmpty {
                    let newIndexKey = buildIndexKey(
                        subspace: indexSubspaceForIndex,
                        values: newValues,
                        id: id
                    )
                    transaction.setValue([], for: newIndexKey)
                }
            }
        }
    }

    /// Extract index values from a type-erased model
    private func extractIndexValuesUntyped(from model: any Persistable, keyPaths: [String]) -> [any TupleElement] {
        var values: [any TupleElement] = []
        for keyPath in keyPaths {
            if let extractedValues = try? DataAccess.extractField(from: model, keyPath: keyPath) {
                values.append(contentsOf: extractedValues)
            }
        }
        return values
    }

    /// Extract index values from a model
    private func extractIndexValues<T: Persistable>(from model: T, keyPaths: [String]) -> [any TupleElement] {
        var values: [any TupleElement] = []
        for keyPath in keyPaths {
            if let extractedValues = try? DataAccess.extractField(from: model, keyPath: keyPath) {
                values.append(contentsOf: extractedValues)
            }
        }
        return values
    }

    /// Build index key
    private func buildIndexKey(subspace: Subspace, values: [any TupleElement], id: Tuple) -> [UInt8] {
        var elements: [any TupleElement] = values
        for i in 0..<id.count {
            if let element = id[i] {
                elements.append(element)
            }
        }
        return subspace.pack(Tuple(elements))
    }

    // MARK: - Predicate Evaluation

    /// Evaluate a predicate on a model
    private func evaluatePredicate<T: Persistable>(_ predicate: FDBPredicate<T>, on model: T) -> Bool {
        switch predicate {
        case .field(let fieldName, let comparison, let value):
            return evaluateFieldComparison(model: model, fieldName: fieldName, comparison: comparison, value: value)

        case .and(let predicates):
            return predicates.allSatisfy { evaluatePredicate($0, on: model) }

        case .or(let predicates):
            return predicates.contains { evaluatePredicate($0, on: model) }

        case .not(let predicate):
            return !evaluatePredicate(predicate, on: model)

        case .true:
            return true

        case .false:
            return false
        }
    }

    /// Evaluate a field comparison with type-safe comparisons
    private func evaluateFieldComparison<T: Persistable>(
        model: T,
        fieldName: String,
        comparison: FDBComparison,
        value: any Sendable
    ) -> Bool {
        guard let fieldValues = try? DataAccess.extractField(from: model, keyPath: fieldName),
              let fieldValue = fieldValues.first else {
            return false
        }

        switch comparison {
        case .equals:
            return compareValues(fieldValue, value) == .orderedSame
        case .notEquals:
            return compareValues(fieldValue, value) != .orderedSame
        case .lessThan:
            return compareValues(fieldValue, value) == .orderedAscending
        case .lessThanOrEquals:
            let result = compareValues(fieldValue, value)
            return result == .orderedAscending || result == .orderedSame
        case .greaterThan:
            return compareValues(fieldValue, value) == .orderedDescending
        case .greaterThanOrEquals:
            let result = compareValues(fieldValue, value)
            return result == .orderedDescending || result == .orderedSame
        case .contains:
            let fieldString = String(describing: fieldValue)
            let valueString = String(describing: value)
            return fieldString.contains(valueString)
        case .beginsWith:
            let fieldString = String(describing: fieldValue)
            let valueString = String(describing: value)
            return fieldString.hasPrefix(valueString)
        case .endsWith:
            let fieldString = String(describing: fieldValue)
            let valueString = String(describing: value)
            return fieldString.hasSuffix(valueString)
        case .in:
            // Handle array containment
            if let array = value as? [any Sendable] {
                return array.contains { compareValues(fieldValue, $0) == .orderedSame }
            }
            return false
        }
    }

    /// Compare two models by a field with type-safe comparison
    private func compareModels<T: Persistable>(_ lhs: T, _ rhs: T, by fieldName: String) -> ComparisonResult {
        let lhsValues = try? DataAccess.extractField(from: lhs, keyPath: fieldName)
        let rhsValues = try? DataAccess.extractField(from: rhs, keyPath: fieldName)

        guard let lhsValue = lhsValues?.first,
              let rhsValue = rhsValues?.first else {
            return .orderedSame
        }

        return compareValues(lhsValue, rhsValue)
    }

    /// Type-safe comparison of two values
    ///
    /// Compares values with proper numeric/date ordering instead of string comparison.
    /// Falls back to string comparison for non-comparable types.
    private func compareValues(_ lhs: any Sendable, _ rhs: any Sendable) -> ComparisonResult {
        // Try numeric comparison first
        if let result = compareNumericValues(lhs, rhs) {
            return result
        }

        // Try string comparison
        if let lhsString = lhs as? String, let rhsString = rhs as? String {
            if lhsString < rhsString { return .orderedAscending }
            if lhsString > rhsString { return .orderedDescending }
            return .orderedSame
        }

        // Try boolean comparison
        if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
            if lhsBool == rhsBool { return .orderedSame }
            return lhsBool ? .orderedDescending : .orderedAscending  // true > false
        }

        // Try Date comparison (stored as Double timestamp)
        if let lhsDate = lhs as? Date, let rhsDate = rhs as? Date {
            if lhsDate < rhsDate { return .orderedAscending }
            if lhsDate > rhsDate { return .orderedDescending }
            return .orderedSame
        }

        // Try UUID comparison (lexicographic)
        if let lhsUUID = lhs as? UUID, let rhsUUID = rhs as? UUID {
            let lhsStr = lhsUUID.uuidString
            let rhsStr = rhsUUID.uuidString
            if lhsStr < rhsStr { return .orderedAscending }
            if lhsStr > rhsStr { return .orderedDescending }
            return .orderedSame
        }

        // Fall back to string comparison for unknown types
        let lhsString = String(describing: lhs)
        let rhsString = String(describing: rhs)
        if lhsString < rhsString { return .orderedAscending }
        if lhsString > rhsString { return .orderedDescending }
        return .orderedSame
    }

    /// Compare numeric values with type coercion
    private func compareNumericValues(_ lhs: any Sendable, _ rhs: any Sendable) -> ComparisonResult? {
        // Convert both values to Double for comparison if they're numeric
        let lhsDouble: Double?
        let rhsDouble: Double?

        // Extract Double value from lhs
        switch lhs {
        case let v as Int: lhsDouble = Double(v)
        case let v as Int64: lhsDouble = Double(v)
        case let v as Int32: lhsDouble = Double(v)
        case let v as Int16: lhsDouble = Double(v)
        case let v as Int8: lhsDouble = Double(v)
        case let v as UInt: lhsDouble = Double(v)
        case let v as UInt64: lhsDouble = Double(v)
        case let v as UInt32: lhsDouble = Double(v)
        case let v as UInt16: lhsDouble = Double(v)
        case let v as UInt8: lhsDouble = Double(v)
        case let v as Double: lhsDouble = v
        case let v as Float: lhsDouble = Double(v)
        default: lhsDouble = nil
        }

        // Extract Double value from rhs
        switch rhs {
        case let v as Int: rhsDouble = Double(v)
        case let v as Int64: rhsDouble = Double(v)
        case let v as Int32: rhsDouble = Double(v)
        case let v as Int16: rhsDouble = Double(v)
        case let v as Int8: rhsDouble = Double(v)
        case let v as UInt: rhsDouble = Double(v)
        case let v as UInt64: rhsDouble = Double(v)
        case let v as UInt32: rhsDouble = Double(v)
        case let v as UInt16: rhsDouble = Double(v)
        case let v as UInt8: rhsDouble = Double(v)
        case let v as Double: rhsDouble = v
        case let v as Float: rhsDouble = Double(v)
        default: rhsDouble = nil
        }

        // If both are numeric, compare as doubles
        if let l = lhsDouble, let r = rhsDouble {
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        }

        return nil  // Not both numeric
    }

    // MARK: - Clear Operations

    /// Clear all records of a type
    func clearAll<T: Persistable>(_ type: T.Type) async throws {
        try await database.withTransaction { transaction in
            let typeSubspace = self.recordSubspace.subspace(T.persistableType)
            let (begin, end) = typeSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)

            // Also clear indexes for this type
            for descriptor in T.indexDescriptors {
                let indexRange = self.indexSubspace.subspace(descriptor.name).range()
                transaction.clearRange(beginKey: indexRange.0, endKey: indexRange.1)
            }
        }
    }
}

// MARK: - FDBIndexError

/// Errors that can occur during index operations
public enum FDBIndexError: Error, CustomStringConvertible {
    /// Unique constraint violation: duplicate value exists for another record
    case uniqueConstraintViolation(indexName: String, values: [String])

    /// Index not found in schema
    case indexNotFound(indexName: String)

    /// Unsupported index kind for operation
    case unsupportedIndexKind(indexName: String, kindIdentifier: String)

    public var description: String {
        switch self {
        case .uniqueConstraintViolation(let indexName, let values):
            return "Unique constraint violation on index '\(indexName)': values [\(values.joined(separator: ", "))] already exist for another record"
        case .indexNotFound(let indexName):
            return "Index '\(indexName)' not found in schema"
        case .unsupportedIndexKind(let indexName, let kindIdentifier):
            return "Unsupported index kind '\(kindIdentifier)' for index '\(indexName)'"
        }
    }
}
