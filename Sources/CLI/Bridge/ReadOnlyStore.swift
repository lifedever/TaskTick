import Foundation
import SwiftData
import TaskTickCore

/// Read-only wrapper around a SwiftData ModelContainer. CLI commands use this
/// to query the same store TaskTick.app writes to without ever risking a
/// concurrent write from the CLI side.
@MainActor
final class ReadOnlyStore {
    let container: ModelContainer

    init(url: URL? = nil) throws {
        // Default to the bundle-namespaced store path the GUI uses.
        let storeURL = url ?? StoreMigration.resolveStoreURL()
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])

        // SwiftData refuses to open a non-existent store with allowsSave: false
        // (CoreData error 260 — "Attempt to open missing file read only"). When
        // the GUI has never run, there's no store yet and the CLI should still
        // start up cleanly and report "no tasks". Detect that case and fall
        // back to an in-memory empty container; the caller never gets to write
        // through it because we don't expose a save path.
        if !FileManager.default.fileExists(atPath: storeURL.path) {
            // In-memory containers require allowsSave: true to initialize
            // (SwiftData/CoreData rejects an in-memory read-only store with
            // "you don't have permission to view /dev/null"). The CLI surface
            // stays read-only by API design — we don't expose any insert /
            // update / delete / save paths to callers.
            let cfg = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            self.container = try ModelContainer(for: schema, configurations: [cfg])
            return
        }

        // Checkpoint any -wal sidecar from the GUI before we open. Concurrent
        // SQLite reads work fine, but if the GUI just wrote and the WAL hasn't
        // been merged, our read might miss the latest data.
        StoreHardener.hardenStore(at: storeURL)

        let cfg = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: false  // ← CLI never writes
        )
        self.container = try ModelContainer(for: schema, configurations: [cfg])
    }

    func fetchTasks() throws -> [ScheduledTask] {
        let descriptor = FetchDescriptor<ScheduledTask>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try container.mainContext.fetch(descriptor)
    }

    func fetchTask(byId id: UUID) throws -> ScheduledTask? {
        let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == id })
        return try container.mainContext.fetch(descriptor).first
    }

    /// Most recent execution log for a task. Skips in-progress runs because
    /// their stdout/stderr live in GUI memory (LiveOutputManager) and aren't
    /// flushed to SwiftData until the run completes — fetching them here
    /// would always return empty strings. Use `tail` for live streaming.
    /// Also skips `.skipped` entries: they mark a run that never happened,
    /// so they carry no output, exit code or duration (issue #59).
    func fetchLatestLog(forTaskId taskId: UUID) throws -> ExecutionLog? {
        let runningRaw = ExecutionStatus.running.rawValue
        let skippedRaw = ExecutionStatus.skipped.rawValue
        var descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate {
                $0.task?.id == taskId && $0.statusRaw != runningRaw && $0.statusRaw != skippedRaw
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try container.mainContext.fetch(descriptor).first
    }
}
