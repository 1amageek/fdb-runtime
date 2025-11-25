import Foundation
import FoundationDB

/// Global FDB initialization task
///
/// Created once at module load time. All tests await this task to ensure
/// FDB is initialized before running. This pattern ensures initialization
/// happens exactly once, even with concurrent test execution.
private let fdbInitializationTask: Task<Void, Never> = Task {
    do {
        try await FDBClient.initialize()
    } catch {
        // Initialization may fail if already initialized by another process
        // This is acceptable in test environments
        print("FDB initialization note: \(error)")
    }
}

/// FDB test environment manager
///
/// Ensures FDBClient is initialized exactly once across all tests.
/// Uses a global Task to guarantee single initialization with concurrent access.
actor FDBTestEnvironment {
    /// Shared singleton instance
    static let shared = FDBTestEnvironment()

    /// Private initializer (use shared instance)
    private init() {}

    /// Ensure FDB client is initialized
    ///
    /// Safe to call multiple times - initialization happens only once via
    /// the global fdbInitializationTask. All calls await the same task.
    func ensureInitialized() async {
        _ = await fdbInitializationTask.value
    }
}
