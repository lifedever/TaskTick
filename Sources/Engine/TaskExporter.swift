import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers
import TaskTickCore

/// Exports and imports tasks as JSON files.
@MainActor
struct TaskExporter {

    struct ExportedTask: Codable {
        let name: String
        let scriptBody: String
        let scriptFilePath: String?
        /// Optional so exports produced by older versions (without this field) still decode.
        let preRunCommand: String?
        let shell: String
        let scheduledDate: Date?
        let repeatType: String
        let endRepeatType: String
        let endRepeatDate: Date?
        let endRepeatCount: Int?
        let cronExpression: String?
        let intervalSeconds: Int?
        let workingDirectory: String?
        let timeoutSeconds: Int
        let notifyOnSuccess: Bool
        let notifyOnFailure: Bool
        let isEnabled: Bool
        // Fields added later — Optional so older exports still decode.
        let serialNumber: Int?
        let customIntervalValue: Int?
        let customIntervalUnit: String?
        let runMissedExecution: Bool?
        let runOnLaunch: Bool?
        let strongReminder: Bool?
        let ignoreExitCode: Bool?
        let notifyOnlyWhenOutput: Bool?
        /// Preserved across backup/restore so the user's original task ordering
        /// (which @Query sorts by createdAt) survives a restore. Optional for
        /// compat with backups produced before this field existed.
        let createdAt: Date?
        let isManualOnly: Bool?
        /// Extra fire times — JSON array of "HH:mm" strings. Optional for compat.
        let additionalTimes: [String]?
        /// Cron-as-first-class + jitter (issue #38). Optional for older exports.
        let scheduleType: String?
        let jitterSeconds: Int?
        /// Per-task schedule time zone (issue #41). Optional for older exports;
        /// nil = follow the system time zone.
        let timeZoneIdentifier: String?
        /// Per-task remote-push opt-in. Optional so older exports still decode.
        /// Legacy field names — the storage predates issue #51's multi-provider
        /// channels and renaming them would break every existing backup.
        let barkPushEnabled: Bool?
        let barkNotifyOnOutputChange: Bool?
        /// Which channels the task pushes to (issue #51), as channel UUID
        /// strings. Only the *reference* travels — a channel carries an app
        /// token, and a backup file is not the place for one. nil = the task
        /// pushes to every enabled channel.
        let pushChannelIDs: [String]?
        /// Custom reminder body shared by all channels (issue #48). Optional so
        /// older exports still decode; nil restores as "default wording".
        let notificationTemplateEnabled: Bool?
        let notificationTemplate: String?
        /// Push-side switches and template, split from the notification ones
        /// (issue #55). Optional so older exports still decode. The last three
        /// carry the task's raw override: nil restores as "follow the
        /// notification side", which is how a pre-split task behaves.
        let pushOnSuccess: Bool?
        let pushOnFailure: Bool?
        let pushOnlyWhenOutput: Bool?
        let pushTemplateEnabled: Bool?
        let pushTemplate: String?
        /// Custom-sort position (issue #56). Optional for older exports; nil
        /// when 0, so tasks never dragged keep their backup hash unchanged.
        let sortOrder: Int?
    }

    /// Export all tasks to a JSON file
    static func exportTasks(from context: ModelContext) {
        let descriptor = FetchDescriptor<ScheduledTask>()
        guard let tasks = try? context.fetch(descriptor), !tasks.isEmpty else { return }

        let exported = tasks.map(makeExported)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "TaskTick-export.json"
        panel.title = "Export Tasks"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(exported)
            try data.write(to: url)
        } catch {
            presentErrorAlert(titleKey: "error.export_failed.title",
                              messageKey: "error.export_failed.message",
                              error: error)
        }
    }

    /// Import tasks from a JSON file
    static func importTasks(into context: ModelContext) -> Int {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Tasks"

        guard panel.runModal() == .OK, let url = panel.url else { return 0 }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentErrorAlert(titleKey: "error.import_failed.title",
                              messageKey: "error.import_read_failed",
                              error: error)
            return 0
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exported: [ExportedTask]
        do {
            exported = try decoder.decode([ExportedTask].self, from: data)
        } catch {
            presentErrorAlert(titleKey: "error.import_failed.title",
                              messageKey: "error.import_decode_failed",
                              error: error)
            return 0
        }

        var count = 0
        var insertedTasks: [ScheduledTask] = []
        for item in exported {
            let task = makeTask(from: item)
            if task.isEnabled {
                task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
            }
            context.insert(task)
            insertedTasks.append(task)
            count += 1
        }

        do {
            try context.save()
        } catch {
            // Roll back unsaved inserts so the UI doesn't flash phantom tasks.
            for task in insertedTasks {
                context.delete(task)
            }
            presentErrorAlert(titleKey: "error.import_failed.title",
                              messageKey: "error.import_save_failed",
                              error: error)
            return 0
        }
        TaskScheduler.shared.rebuildSchedule()
        return count
    }

    // MARK: - Shared conversion (also used by DatabaseBackup)

    /// Snapshot a `ScheduledTask` into a transferable struct. Captures user-authored config
    /// only — runtime state (`lastRunAt`, `executionCount`, `nextRunAt`) is intentionally
    /// excluded so restoring a backup leaves scheduling decisions to the live scheduler.
    nonisolated static func makeExported(_ task: ScheduledTask) -> ExportedTask {
        ExportedTask(
            name: task.name,
            scriptBody: task.scriptBody,
            scriptFilePath: task.scriptFilePath,
            preRunCommand: task.preRunCommand,
            shell: task.shell,
            scheduledDate: task.scheduledDate,
            repeatType: task.repeatTypeRaw,
            endRepeatType: task.endRepeatTypeRaw,
            endRepeatDate: task.endRepeatDate,
            endRepeatCount: task.endRepeatCount,
            cronExpression: task.cronExpression,
            intervalSeconds: task.intervalSeconds,
            workingDirectory: task.workingDirectory,
            timeoutSeconds: task.timeoutSeconds,
            notifyOnSuccess: task.notifyOnSuccess,
            notifyOnFailure: task.notifyOnFailure,
            isEnabled: task.isEnabled,
            serialNumber: task.serialNumber > 0 ? task.serialNumber : nil,
            customIntervalValue: task.customIntervalValue,
            customIntervalUnit: task.customIntervalUnitRaw,
            runMissedExecution: task.runMissedExecution,
            runOnLaunch: task.runOnLaunch,
            strongReminder: task.strongReminder,
            ignoreExitCode: task.ignoreExitCode,
            notifyOnlyWhenOutput: task.notifyOnlyWhenOutput,
            createdAt: task.createdAt,
            isManualOnly: task.isManualOnly,
            additionalTimes: {
                let raw = task.additionalTimes.compactMap { comps -> String? in
                    guard let h = comps.hour, let m = comps.minute else { return nil }
                    return String(format: "%02d:%02d", h, m)
                }
                return raw.isEmpty ? nil : raw
            }(),
            scheduleType: task.scheduleType,
            jitterSeconds: task.jitterSeconds > 0 ? task.jitterSeconds : nil,
            timeZoneIdentifier: task.timeZoneIdentifier,
            barkPushEnabled: task.barkPushEnabled,
            barkNotifyOnOutputChange: task.barkNotifyOnOutputChange,
            pushChannelIDs: task.pushChannelIDs?.map(\.uuidString),
            notificationTemplateEnabled: task.notificationTemplateEnabled ? true : nil,
            notificationTemplate: task.notificationTemplate.isEmpty ? nil : task.notificationTemplate,
            pushOnSuccess: task.pushOnSuccess,
            pushOnFailure: task.pushOnFailure,
            pushOnlyWhenOutput: task.pushOnlyWhenOutputOverride,
            pushTemplateEnabled: task.pushTemplateEnabledOverride,
            pushTemplate: task.pushTemplateOverride,
            sortOrder: task.sortOrder != 0 ? task.sortOrder : nil
        )
    }

    /// Maps an export's channel references onto the channels this machine
    /// actually has.
    ///
    /// A backup restored onto a different Mac names channel ids that don't
    /// exist here. Keeping the dangling ids would leave the task's push switch
    /// on while nothing could ever receive it — a silent failure with no UI
    /// trace. When *nothing* matches we fall back to nil ("every enabled
    /// channel"), which is what the task meant before #51 split channels apart.
    /// A partial match is kept as-is: the user's intent to narrow down survives.
    nonisolated private static func restoredChannelIDs(from raw: [String]?) -> [UUID]? {
        guard let raw else { return nil }
        let requested = raw.compactMap(UUID.init(uuidString:))
        let known = Set(PushChannelStore.load().map(\.id))
        let matched = requested.filter { known.contains($0) }
        return matched.isEmpty ? nil : matched
    }

    /// Materialize an `ExportedTask` back into a `ScheduledTask`. The task is NOT inserted
    /// into a context — caller decides where it lives. `nextRunAt` is left nil so the
    /// scheduler recomputes it on insertion (preserves the restored `scheduledDate`).
    nonisolated static func makeTask(from item: ExportedTask) -> ScheduledTask {
        let task = ScheduledTask(
            name: item.name,
            scriptBody: item.scriptBody,
            shell: item.shell,
            scheduledDate: item.scheduledDate,
            repeatType: RepeatType(rawValue: item.repeatType) ?? .daily,
            endRepeatType: EndRepeatType(rawValue: item.endRepeatType) ?? .never,
            endRepeatDate: item.endRepeatDate,
            endRepeatCount: item.endRepeatCount,
            isEnabled: item.isEnabled,
            workingDirectory: item.workingDirectory,
            timeoutSeconds: item.timeoutSeconds,
            notifyOnSuccess: item.notifyOnSuccess,
            notifyOnFailure: item.notifyOnFailure
        )
        task.scriptFilePath = item.scriptFilePath
        task.preRunCommand = item.preRunCommand ?? ""
        task.cronExpression = item.cronExpression
        task.intervalSeconds = item.intervalSeconds
        if let st = item.scheduleType {
            task.scheduleType = st
        } else if item.cronExpression != nil {
            // Pre-jitter exports carried no scheduleType, and cronExpression
            // only ever accompanied cron tasks — restore them as cron.
            task.schedule = .cron
        }
        task.jitterSeconds = item.jitterSeconds ?? 0
        task.timeZoneIdentifier = item.timeZoneIdentifier
        // ScheduledTask.init bumps the global serial counter; overwrite with the
        // backup's value so restored tasks keep their original numbering.
        if let n = item.serialNumber, n > 0 {
            task.serialNumber = n
        }
        if let v = item.customIntervalValue { task.customIntervalValue = v }
        if let u = item.customIntervalUnit { task.customIntervalUnitRaw = u }
        if let v = item.runMissedExecution { task.runMissedExecution = v }
        if let v = item.runOnLaunch { task.runOnLaunch = v }
        if let v = item.strongReminder { task.strongReminder = v }
        if let v = item.ignoreExitCode { task.ignoreExitCode = v }
        if let v = item.notifyOnlyWhenOutput { task.notifyOnlyWhenOutput = v }
        if let v = item.barkPushEnabled { task.barkPushEnabled = v }
        if let v = item.barkNotifyOnOutputChange { task.barkNotifyOnOutputChange = v }
        task.pushChannelIDs = restoredChannelIDs(from: item.pushChannelIDs)
        if let v = item.notificationTemplateEnabled { task.notificationTemplateEnabled = v }
        if let v = item.notificationTemplate { task.notificationTemplate = v }
        if let v = item.pushOnSuccess { task.pushOnSuccess = v }
        if let v = item.pushOnFailure { task.pushOnFailure = v }
        task.pushOnlyWhenOutputOverride = item.pushOnlyWhenOutput
        task.pushTemplateEnabledOverride = item.pushTemplateEnabled
        task.pushTemplateOverride = item.pushTemplate
        if let v = item.sortOrder { task.sortOrder = v }
        if let v = item.isManualOnly { task.isManualOnly = v }
        if let strings = item.additionalTimes, !strings.isEmpty {
            let comps = strings.compactMap { s -> DateComponents? in
                let parts = s.split(separator: ":")
                guard parts.count == 2,
                      let h = Int(parts[0]), (0...23).contains(h),
                      let m = Int(parts[1]), (0...59).contains(m)
                else { return nil }
                return DateComponents(hour: h, minute: m)
            }
            task.additionalTimes = comps
        }
        if let v = item.createdAt {
            task.createdAt = v
            task.updatedAt = v
        }
        return task
    }
}
