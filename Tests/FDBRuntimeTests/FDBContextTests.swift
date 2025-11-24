import Testing
import Foundation
import FoundationDB
@testable import FDBRuntime
@testable import FDBCore

/// Tests for FDBContext functionality
///
/// **Coverage**:
/// - Autosave functionality
/// - Concurrent save serialization
/// - Change tracking
/// - Fetch operations
@Suite("FDBContext Tests")
struct FDBContextTests {

    // MARK: - Helper Types

    struct TestItem: Codable, Sendable {
        var id: Int64
        var name: String
    }

    // MARK: - Helper Methods

    private func setupDatabase() async throws -> (any DatabaseProtocol, FDBContainer, Subspace) {
        // Ensure FDB is initialized (safe to call multiple times)
        await FDBTestEnvironment.shared.ensureInitialized()
        let database = try FDBClient.openDatabase()

        // Create test schema
        let schema = Schema(entities: [], version: Schema.Version(1, 0, 0))

        // Create test subspace (isolated)
        let testSubspace = Subspace(prefix: Tuple("context_test", UUID().uuidString).pack())

        // Create test-specific DirectoryLayer to ensure test isolation
        let testDirectoryLayer = DirectoryLayer(
            database: database,
            nodeSubspace: testSubspace.subspace(0xFE),
            contentSubspace: testSubspace
        )

        // Create container with custom DirectoryLayer
        let container = FDBContainer(
            database: database,
            schema: schema,
            rootSubspace: testSubspace,
            directoryLayer: testDirectoryLayer
        )

        let itemSubspace = testSubspace.subspace("items")

        return (database, container, itemSubspace)
    }

    // MARK: - Tests

    /// Test: Autosave disabled by default
    @Test("Autosave disabled by default")
    func autosaveDisabledByDefault() async throws {
        let (_, container, _) = try await setupDatabase()

        let context = FDBContext(container: container)
        #expect(context.autosaveEnabled == false)
    }

    /// Test: Autosave can be enabled
    @Test("Autosave can be enabled")
    func autosaveCanBeEnabled() async throws {
        let (_, container, _) = try await setupDatabase()

        let context = FDBContext(container: container, autosaveEnabled: false)
        #expect(context.autosaveEnabled == false)

        context.autosaveEnabled = true
        #expect(context.autosaveEnabled == true)
    }

    /// Test: HasChanges tracking
    @Test("HasChanges tracking")
    func hasChangesTracking() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        // Initially no changes
        #expect(context.hasChanges == false)

        // After insert, has changes
        let item = TestItem(id: 1, name: "Test")
        let data = try JSONEncoder().encode(item)
        context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        #expect(context.hasChanges == true)

        // After save, no changes
        try await context.save()
        #expect(context.hasChanges == false)

        // After delete, has changes
        context.delete(for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        #expect(context.hasChanges == true)

        // After rollback, no changes
        context.rollback()
        #expect(context.hasChanges == false)
    }

    /// Test: Insert and delete cancel each other
    @Test("Insert and delete cancel each other")
    func insertAndDeleteCancel() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        let item = TestItem(id: 1, name: "Test")
        let data = try JSONEncoder().encode(item)

        // Insert then delete
        context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        #expect(context.hasChanges == true)

        context.delete(for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        // Should have no changes (insert canceled by delete)
        #expect(context.hasChanges == false)

        // Delete then insert
        context.delete(for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        #expect(context.hasChanges == true)

        context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        // Should have changes (delete canceled, insert remains)
        #expect(context.hasChanges == true)
    }

    /// Test: Save with no changes does nothing
    @Test("Save with no changes does nothing")
    func saveWithNoChanges() async throws {
        let (_, container, _) = try await setupDatabase()

        let context = FDBContext(container: container)

        // Should not throw, just return immediately
        try await context.save()
    }

    /// Test: Concurrent saves are serialized
    @Test("Concurrent saves are serialized")
    func concurrentSavesAreSerialized() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        // Insert multiple items
        let items = (1...10).map { TestItem(id: Int64($0), name: "Item \($0)") }
        for item in items {
            let data = try! JSONEncoder().encode(item)
            context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        }

        // Try concurrent saves
        let save1 = Task {
            try await context.save()
        }

        let save2 = Task {
            try await context.save()
        }

        // Wait for both to complete
        _ = try await save1.value
        _ = try await save2.value

        // Should not have errors (second save should see no changes)
        #expect(context.hasChanges == false)
    }

    /// Test: Fetch single item
    @Test("Fetch single item")
    func fetchSingleItem() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        // Insert and save
        let item = TestItem(id: 1, name: "Test Item")
        let data = try JSONEncoder().encode(item)
        context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        try await context.save()

        // Fetch
        let fetchedData = try await context.fetch(for: "TestItem", primaryKey: Tuple(item.id), from: itemSubspace)
        #expect(fetchedData != nil)

        let fetchedItem = try JSONDecoder().decode(TestItem.self, from: fetchedData!)
        #expect(fetchedItem.id == item.id)
        #expect(fetchedItem.name == item.name)
    }

    /// Test: Fetch returns nil for missing item
    @Test("Fetch returns nil for missing item")
    func fetchReturnsNilForMissingItem() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        let fetchedData = try await context.fetch(for: "TestItem", primaryKey: Tuple(999), from: itemSubspace)
        #expect(fetchedData == nil)
    }

    /// Test: Fetch all items
    @Test("Fetch all items")
    func fetchAllItems() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        // Insert multiple items
        let items = (1...5).map { TestItem(id: Int64($0), name: "Item \($0)") }
        for item in items {
            let data = try JSONEncoder().encode(item)
            context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        }
        try await context.save()

        // Fetch all
        var fetchedItems: [(primaryKey: Tuple, data: Data)] = []
        for try await item in context.fetch(for: "TestItem", from: itemSubspace) {
            fetchedItems.append(item)
        }

        #expect(fetchedItems.count == 5)

        // Verify IDs
        let ids = fetchedItems.compactMap { $0.primaryKey[0] as? Int64 }.sorted()
        #expect(ids == [1, 2, 3, 4, 5])
    }

    /// Test: Rollback clears changes
    @Test("Rollback clears changes")
    func rollbackClearsChanges() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        let item = TestItem(id: 1, name: "Test")
        let data = try JSONEncoder().encode(item)
        context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        #expect(context.hasChanges == true)

        context.rollback()
        #expect(context.hasChanges == false)

        // Save should do nothing
        try await context.save()
    }

    /// Test: Reset is equivalent to rollback
    @Test("Reset is equivalent to rollback")
    func resetEquivalentToRollback() async throws {
        let (_, container, itemSubspace) = try await setupDatabase()

        let context = FDBContext(container: container)

        let item = TestItem(id: 1, name: "Test")
        let data = try JSONEncoder().encode(item)
        context.insert(data: data, for: "TestItem", primaryKey: Tuple(item.id), subspace: itemSubspace)
        #expect(context.hasChanges == true)

        context.reset()
        #expect(context.hasChanges == false)
    }
}
