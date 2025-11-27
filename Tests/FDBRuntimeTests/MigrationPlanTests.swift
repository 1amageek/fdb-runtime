import Testing
import Foundation
import FoundationDB
import FDBModel
@testable import FDBRuntime
@testable import FDBCore
@testable import FDBIndexing

/// Tests for SwiftData-like Migration API
///
/// **Coverage**:
/// - VersionedSchema protocol
/// - SchemaMigrationPlan protocol
/// - MigrationStage enum
/// - FDBContainer.migrateIfNeeded()
@Suite("Migration Plan Tests")
struct MigrationPlanTests {

    // MARK: - Test Schema Versions

    /// Schema V1: Basic user with email index
    enum TestSchemaV1: VersionedSchema {
        static let versionIdentifier = Schema.Version(1, 0, 0)
        static let models: [any Persistable.Type] = [UserV1.self]

        struct UserV1: Persistable, Codable, Sendable {
            typealias ID = String

            var id: String = ULID().ulidString

            static let persistableType = "TestUser"
            static let allFields = ["id", "name", "email"]

            static let indexDescriptors: [IndexDescriptor] = [
                IndexDescriptor(
                    name: "TestUser_email",
                    keyPaths: ["email"],
                    kind: ScalarIndexKind(),
                    commonOptions: .init(unique: true)
                )
            ]

            static func fieldNumber(for fieldName: String) -> Int? {
                switch fieldName {
                case "id": return 1
                case "name": return 2
                case "email": return 3
                default: return nil
                }
            }

            static func enumMetadata(for fieldName: String) -> EnumMetadata? {
                return nil
            }

            var name: String
            var email: String

            subscript(dynamicMember member: String) -> (any Sendable)? {
                switch member {
                case "id": return id
                case "name": return name
                case "email": return email
                default: return nil
                }
            }
        }
    }

    /// Schema V2: User with additional age field and index
    enum TestSchemaV2: VersionedSchema {
        static let versionIdentifier = Schema.Version(2, 0, 0)
        static let models: [any Persistable.Type] = [UserV2.self]

        struct UserV2: Persistable, Codable, Sendable {
            typealias ID = String

            var id: String = ULID().ulidString

            static let persistableType = "TestUser"
            static let allFields = ["id", "name", "email", "age"]

            static let indexDescriptors: [IndexDescriptor] = [
                IndexDescriptor(
                    name: "TestUser_email",
                    keyPaths: ["email"],
                    kind: ScalarIndexKind(),
                    commonOptions: .init(unique: true)
                ),
                IndexDescriptor(
                    name: "TestUser_age",
                    keyPaths: ["age"],
                    kind: ScalarIndexKind(),
                    commonOptions: .init()
                )
            ]

            static func fieldNumber(for fieldName: String) -> Int? {
                switch fieldName {
                case "id": return 1
                case "name": return 2
                case "email": return 3
                case "age": return 4
                default: return nil
                }
            }

            static func enumMetadata(for fieldName: String) -> EnumMetadata? {
                return nil
            }

            var name: String
            var email: String
            var age: Int = 0

            subscript(dynamicMember member: String) -> (any Sendable)? {
                switch member {
                case "id": return id
                case "name": return name
                case "email": return email
                case "age": return age
                default: return nil
                }
            }
        }
    }

    /// Schema V3: User with removed age index, added createdAt
    enum TestSchemaV3: VersionedSchema {
        static let versionIdentifier = Schema.Version(3, 0, 0)
        static let models: [any Persistable.Type] = [UserV3.self]

        struct UserV3: Persistable, Codable, Sendable {
            typealias ID = String

            var id: String = ULID().ulidString

            static let persistableType = "TestUser"
            static let allFields = ["id", "name", "email", "age", "createdAt"]

            static let indexDescriptors: [IndexDescriptor] = [
                IndexDescriptor(
                    name: "TestUser_email",
                    keyPaths: ["email"],
                    kind: ScalarIndexKind(),
                    commonOptions: .init(unique: true)
                ),
                IndexDescriptor(
                    name: "TestUser_createdAt",
                    keyPaths: ["createdAt"],
                    kind: ScalarIndexKind(),
                    commonOptions: .init()
                )
            ]

            static func fieldNumber(for fieldName: String) -> Int? {
                switch fieldName {
                case "id": return 1
                case "name": return 2
                case "email": return 3
                case "age": return 4
                case "createdAt": return 5
                default: return nil
                }
            }

            static func enumMetadata(for fieldName: String) -> EnumMetadata? {
                return nil
            }

            var name: String
            var email: String
            var age: Int = 0
            var createdAt: Double = 0

            subscript(dynamicMember member: String) -> (any Sendable)? {
                switch member {
                case "id": return id
                case "name": return name
                case "email": return email
                case "age": return age
                case "createdAt": return createdAt
                default: return nil
                }
            }
        }
    }

    // MARK: - Test Migration Plans

    /// Simple migration plan V1 -> V2
    enum SimpleMigrationPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [TestSchemaV1.self, TestSchemaV2.self]
        }

        static var stages: [MigrationStage] {
            [migrateV1toV2]
        }

        static let migrateV1toV2 = MigrationStage.lightweight(
            fromVersion: TestSchemaV1.self,
            toVersion: TestSchemaV2.self
        )
    }

    /// Complex migration plan V1 -> V2 -> V3
    enum ComplexMigrationPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [TestSchemaV1.self, TestSchemaV2.self, TestSchemaV3.self]
        }

        static var stages: [MigrationStage] {
            [migrateV1toV2, migrateV2toV3]
        }

        static let migrateV1toV2 = MigrationStage.lightweight(
            fromVersion: TestSchemaV1.self,
            toVersion: TestSchemaV2.self
        )

        static let migrateV2toV3 = MigrationStage.custom(
            fromVersion: TestSchemaV2.self,
            toVersion: TestSchemaV3.self,
            willMigrate: nil,
            didMigrate: nil
        )
    }

    /// Single schema (no migration needed)
    enum SingleSchemaPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [TestSchemaV1.self]
        }

        static var stages: [MigrationStage] {
            []  // No migrations for single schema
        }
    }

    // MARK: - VersionedSchema Tests

    /// Test: VersionedSchema creates Schema correctly
    @Test("VersionedSchema creates Schema correctly")
    func versionedSchemaCreatesSchema() {
        let schema = TestSchemaV1.makeSchema()

        #expect(schema.version == Schema.Version(1, 0, 0))
        #expect(schema.entities.count == 1)
        #expect(schema.entities.first?.name == "TestUser")
    }

    /// Test: VersionedSchema collects all index descriptors
    @Test("VersionedSchema collects all index descriptors")
    func versionedSchemaCollectsIndexDescriptors() {
        let descriptors = TestSchemaV2.allIndexDescriptors

        #expect(descriptors.count == 2)
        #expect(descriptors.contains(where: { $0.name == "TestUser_email" }))
        #expect(descriptors.contains(where: { $0.name == "TestUser_age" }))
    }

    /// Test: VersionedSchema detects index changes
    @Test("VersionedSchema detects index changes")
    func versionedSchemaDetectsIndexChanges() {
        let changes = TestSchemaV2.indexChanges(from: TestSchemaV1.self)

        #expect(changes.added == Set(["TestUser_age"]))
        #expect(changes.removed.isEmpty)
    }

    /// Test: VersionedSchema detects lightweight migration possibility
    @Test("VersionedSchema detects lightweight migration possibility")
    func versionedSchemaDetectsLightweightMigration() {
        // V1 -> V2: Adding field and index (lightweight)
        #expect(TestSchemaV2.canLightweightMigrate(from: TestSchemaV1.self))

        // V2 -> V3: Adding field and index, removing index (lightweight)
        #expect(TestSchemaV3.canLightweightMigrate(from: TestSchemaV2.self))
    }

    // MARK: - SchemaMigrationPlan Tests

    /// Test: SchemaMigrationPlan validation passes for valid plan
    @Test("SchemaMigrationPlan validation passes for valid plan")
    func migrationPlanValidationPasses() throws {
        try SimpleMigrationPlan.validate()
        try ComplexMigrationPlan.validate()
        try SingleSchemaPlan.validate()
    }

    /// Test: SchemaMigrationPlan finds migration path
    @Test("SchemaMigrationPlan finds migration path")
    func migrationPlanFindsPath() throws {
        let path = try ComplexMigrationPlan.findPath(
            from: Schema.Version(1, 0, 0),
            to: Schema.Version(3, 0, 0)
        )

        #expect(path.count == 2)
        #expect(path[0].fromVersionIdentifier == Schema.Version(1, 0, 0))
        #expect(path[0].toVersionIdentifier == Schema.Version(2, 0, 0))
        #expect(path[1].fromVersionIdentifier == Schema.Version(2, 0, 0))
        #expect(path[1].toVersionIdentifier == Schema.Version(3, 0, 0))
    }

    /// Test: SchemaMigrationPlan returns empty path for same version
    @Test("SchemaMigrationPlan returns empty path for same version")
    func migrationPlanReturnsEmptyPathForSameVersion() throws {
        let path = try SimpleMigrationPlan.findPath(
            from: Schema.Version(1, 0, 0),
            to: Schema.Version(1, 0, 0)
        )

        #expect(path.isEmpty)
    }

    /// Test: SchemaMigrationPlan throws for downgrade
    @Test("SchemaMigrationPlan throws for downgrade")
    func migrationPlanThrowsForDowngrade() {
        do {
            _ = try SimpleMigrationPlan.findPath(
                from: Schema.Version(2, 0, 0),
                to: Schema.Version(1, 0, 0)
            )
            Issue.record("Expected downgradeNotSupported error")
        } catch let error as MigrationPlanError {
            if case .downgradeNotSupported(let from, let to) = error {
                #expect(from == Schema.Version(2, 0, 0))
                #expect(to == Schema.Version(1, 0, 0))
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// Test: SchemaMigrationPlan currentVersion returns latest
    @Test("SchemaMigrationPlan currentVersion returns latest")
    func migrationPlanCurrentVersion() {
        #expect(SimpleMigrationPlan.currentVersion == Schema.Version(2, 0, 0))
        #expect(ComplexMigrationPlan.currentVersion == Schema.Version(3, 0, 0))
        #expect(SingleSchemaPlan.currentVersion == Schema.Version(1, 0, 0))
    }

    // MARK: - MigrationStage Tests

    /// Test: MigrationStage.lightweight properties
    @Test("MigrationStage.lightweight properties")
    func lightweightStageProperties() {
        let stage = MigrationStage.lightweight(
            fromVersion: TestSchemaV1.self,
            toVersion: TestSchemaV2.self
        )

        #expect(stage.isLightweight)
        #expect(stage.fromVersionIdentifier == Schema.Version(1, 0, 0))
        #expect(stage.toVersionIdentifier == Schema.Version(2, 0, 0))
        #expect(stage.willMigrate == nil)
        #expect(stage.didMigrate == nil)
    }

    /// Test: MigrationStage.custom properties
    @Test("MigrationStage.custom properties")
    func customStageProperties() {
        let stage = MigrationStage.custom(
            fromVersion: TestSchemaV1.self,
            toVersion: TestSchemaV2.self,
            willMigrate: { _ in /* pre-migration */ },
            didMigrate: { _ in /* post-migration */ }
        )

        #expect(!stage.isLightweight)
        #expect(stage.fromVersionIdentifier == Schema.Version(1, 0, 0))
        #expect(stage.toVersionIdentifier == Schema.Version(2, 0, 0))
        #expect(stage.willMigrate != nil)
        #expect(stage.didMigrate != nil)
    }

    /// Test: MigrationStage detects index changes
    @Test("MigrationStage detects index changes")
    func stageDetectsIndexChanges() {
        let stage = MigrationStage.lightweight(
            fromVersion: TestSchemaV1.self,
            toVersion: TestSchemaV2.self
        )

        let changes = stage.indexChanges
        #expect(changes.added == Set(["TestUser_age"]))
        #expect(changes.removed.isEmpty)

        let addedDescriptors = stage.addedIndexDescriptors
        #expect(addedDescriptors.count == 1)
        #expect(addedDescriptors.first?.name == "TestUser_age")
    }

    /// Test: MigrationStage detects index removal
    @Test("MigrationStage detects index removal")
    func stageDetectsIndexRemoval() {
        let stage = MigrationStage.lightweight(
            fromVersion: TestSchemaV2.self,
            toVersion: TestSchemaV3.self
        )

        let changes = stage.indexChanges
        #expect(changes.added == Set(["TestUser_createdAt"]))
        #expect(changes.removed == Set(["TestUser_age"]))
    }

    /// Test: MigrationStage.automatic selects lightweight when possible
    @Test("MigrationStage.automatic selects lightweight when possible")
    func automaticSelectsLightweight() {
        let stage = MigrationStage.automatic(
            from: TestSchemaV1.self,
            to: TestSchemaV2.self
        )

        #expect(stage.isLightweight)
    }

    /// Test: MigrationStage.automatic selects custom when hooks provided
    @Test("MigrationStage.automatic selects custom when hooks provided")
    func automaticSelectsCustomWithHooks() {
        let stage = MigrationStage.automatic(
            from: TestSchemaV1.self,
            to: TestSchemaV2.self,
            willMigrate: { _ in }
        )

        #expect(!stage.isLightweight)
    }

    // MARK: - Validation Error Tests

    /// Invalid plan with wrong stage count
    enum InvalidStageCoun: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [TestSchemaV1.self, TestSchemaV2.self, TestSchemaV3.self]
        }
        static var stages: [MigrationStage] {
            [MigrationStage.lightweight(fromVersion: TestSchemaV1.self, toVersion: TestSchemaV2.self)]
            // Missing V2 -> V3 stage
        }
    }

    /// Test: Validation fails for wrong stage count
    @Test("Validation fails for wrong stage count")
    func validationFailsForWrongStageCount() {
        do {
            try InvalidStageCoun.validate()
            Issue.record("Expected stageCountMismatch error")
        } catch let error as MigrationPlanError {
            if case .stageCountMismatch(let expected, let actual) = error {
                #expect(expected == 2)
                #expect(actual == 1)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// Invalid plan with out-of-order versions
    enum OutOfOrderPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] {
            [TestSchemaV2.self, TestSchemaV1.self]  // Wrong order
        }
        static var stages: [MigrationStage] {
            [MigrationStage.lightweight(fromVersion: TestSchemaV2.self, toVersion: TestSchemaV1.self)]
        }
    }

    /// Test: Validation fails for out-of-order versions
    @Test("Validation fails for out-of-order versions")
    func validationFailsForOutOfOrderVersions() {
        do {
            try OutOfOrderPlan.validate()
            Issue.record("Expected versionsNotOrdered error")
        } catch let error as MigrationPlanError {
            if case .versionsNotOrdered = error {
                // Expected
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
