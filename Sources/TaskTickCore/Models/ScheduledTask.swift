import Foundation
import SwiftData

// MARK: - Repeat Type

public enum RepeatType: String, Codable, CaseIterable, Sendable {
    case never = "never"
    case everyMinute = "everyMinute"
    case every5Minutes = "every5Minutes"
    case every15Minutes = "every15Minutes"
    case every30Minutes = "every30Minutes"
    case hourly = "hourly"
    case daily = "daily"
    case weekdays = "weekdays"
    case weekends = "weekends"
    case weekly = "weekly"
    case biweekly = "biweekly"
    case monthly = "monthly"
    case every3Months = "every3Months"
    case every6Months = "every6Months"
    case yearly = "yearly"
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .never: L10n.tr("repeat.never")
        case .everyMinute: L10n.tr("repeat.every_minute")
        case .every5Minutes: L10n.tr("repeat.every_5_minutes")
        case .every15Minutes: L10n.tr("repeat.every_15_minutes")
        case .every30Minutes: L10n.tr("repeat.every_30_minutes")
        case .hourly: L10n.tr("repeat.hourly")
        case .daily: L10n.tr("repeat.daily")
        case .weekdays: L10n.tr("repeat.weekdays")
        case .weekends: L10n.tr("repeat.weekends")
        case .weekly: L10n.tr("repeat.weekly")
        case .biweekly: L10n.tr("repeat.biweekly")
        case .monthly: L10n.tr("repeat.monthly")
        case .every3Months: L10n.tr("repeat.every_3_months")
        case .every6Months: L10n.tr("repeat.every_6_months")
        case .yearly: L10n.tr("repeat.yearly")
        case .custom: L10n.tr("repeat.custom")
        }
    }

    /// Whether this repeat type can carry multiple time-of-day points per
    /// occurrence. Sub-day intervals (everyMinute, hourly, etc.) and types
    /// with no fixed day stride (custom) don't benefit from extra times.
    public var supportsAdditionalTimes: Bool {
        switch self {
        case .daily, .weekdays, .weekends, .weekly, .biweekly:
            return true
        default:
            return false
        }
    }

    /// Calendar component and value for computing next date
    public var calendarInterval: (component: Calendar.Component, value: Int)? {
        switch self {
        case .never: nil
        case .everyMinute: (.minute, 1)
        case .every5Minutes: (.minute, 5)
        case .every15Minutes: (.minute, 15)
        case .every30Minutes: (.minute, 30)
        case .hourly: (.hour, 1)
        case .daily, .weekdays, .weekends: (.day, 1)
        case .weekly: (.weekOfYear, 1)
        case .biweekly: (.weekOfYear, 2)
        case .monthly: (.month, 1)
        case .every3Months: (.month, 3)
        case .every6Months: (.month, 6)
        case .yearly: (.year, 1)
        case .custom: nil // handled separately with customInterval fields
        }
    }
}

/// Unit for custom repeat interval
public enum CustomRepeatUnit: String, Codable, CaseIterable, Sendable {
    case second = "second"
    case minute = "minute"
    case hour = "hour"
    case day = "day"
    case week = "week"
    case month = "month"
    case year = "year"

    public var displayName: String {
        switch self {
        case .second: L10n.tr("repeat.unit.second")
        case .minute: L10n.tr("repeat.unit.minute")
        case .hour: L10n.tr("repeat.unit.hour")
        case .day: L10n.tr("repeat.unit.day")
        case .week: L10n.tr("repeat.unit.week")
        case .month: L10n.tr("repeat.unit.month")
        case .year: L10n.tr("repeat.unit.year")
        }
    }

    public var calendarComponent: Calendar.Component {
        switch self {
        case .second: .second
        case .minute: .minute
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

// MARK: - End Repeat Type

public enum EndRepeatType: String, Codable, CaseIterable, Sendable {
    case never = "never"
    case onDate = "onDate"
    case afterCount = "afterCount"

    public var displayName: String {
        switch self {
        case .never: L10n.tr("end_repeat.never")
        case .onDate: L10n.tr("end_repeat.on_date")
        case .afterCount: L10n.tr("end_repeat.after_count")
        }
    }
}

// MARK: - Legacy ScheduleType (for migration)

public enum ScheduleType: String, Codable, CaseIterable, Sendable {
    case cron = "cron"
    case interval = "interval"

    public var displayName: String {
        switch self {
        case .cron: L10n.tr("schedule.cron")
        case .interval: L10n.tr("schedule.interval")
        }
    }
}

// MARK: - Model

@Model
public final class ScheduledTask {
    public var id: UUID
    public var serialNumber: Int = 0
    public var name: String
    public var scriptBody: String
    public var scriptFilePath: String?
    /// When set, this task runs `shortcuts run <name>` instead of a shell script.
    /// Mutually exclusive with `scriptBody` / `scriptFilePath` at the editor layer;
    /// the executor branches on this field before reading either.
    public var shortcutName: String? = nil
    /// Commands to run before the main script body (e.g. `export` proxy vars).
    /// Executed in the same shell invocation so env changes propagate to the script.
    public var preRunCommand: String = ""
    public var shell: String

    // Legacy fields (kept for data migration)
    public var scheduleType: String
    public var cronExpression: String?
    public var intervalSeconds: Int?

    // New schedule fields
    public var scheduledDate: Date?
    /// Whether the user wants the schedule anchored to a specific date.
    /// Default `true` preserves legacy behavior on SwiftData migration.
    public var hasDate: Bool = true
    /// Whether the user wants the schedule anchored to a specific time of day.
    public var hasTime: Bool = true
    public var repeatTypeRaw: String = RepeatType.daily.rawValue
    public var endRepeatTypeRaw: String = EndRepeatType.never.rawValue
    public var endRepeatDate: Date?
    public var endRepeatCount: Int?
    public var executionCount: Int = 0
    public var customIntervalValue: Int = 1
    public var customIntervalUnitRaw: String = CustomRepeatUnit.day.rawValue
    /// Extra time-of-day points (in addition to `scheduledDate`'s time) at which
    /// this task fires on each occurrence. Stored as a JSON array of `"HH:mm"`
    /// strings to keep SwiftData migration trivial — nil/empty for tasks with
    /// only a single time. Only honored by day-aligned RepeatTypes (daily,
    /// weekdays, weekends, weekly, biweekly).
    public var additionalTimesJSON: String?

    public var isEnabled: Bool
    /// When true, the task has no schedule — it only runs when triggered manually
    /// (right-click "Run", menu bar ▶, etc.). All schedule fields are ignored.
    /// Default `false` preserves legacy behavior on SwiftData migration.
    public var isManualOnly: Bool = false
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?
    /// Most recent time this task was run *manually* (UI play button, Quick
    /// Launcher Enter, menu bar ▶). Scheduled triggers do not bump this —
    /// it's the signal we sort by so user-initiated runs surface to the top
    /// across sidebar / Quick Launcher / menu bar without scheduled cron
    /// jobs constantly churning the order.
    public var lastManualRunAt: Date?
    public var nextRunAt: Date?
    public var workingDirectory: String?
    public var environmentVariablesJSON: String?
    public var timeoutSeconds: Int
    public var notifyOnSuccess: Bool
    public var notifyOnFailure: Bool
    /// When true and the script exits successfully but produces no stdout (after
    /// trimming), TaskTick suppresses the success notification. Lets polling-style
    /// scripts stay silent on no-op runs and only chirp when they actually do work
    /// (`echo` something). Default `false` keeps existing tasks' behavior unchanged.
    public var notifyOnlyWhenOutput: Bool = false
    public var runMissedExecution: Bool = false
    /// When true, fires once every time `TaskScheduler.start()` runs (i.e. each
    /// app launch). Independent of any time-based schedule. See issue #25.
    public var runOnLaunch: Bool = false
    public var strongReminder: Bool = false
    public var ignoreExitCode: Bool = false
    /// When true, running/stopping/restarting THIS task fires a macOS
    /// "action feedback" banner (Started/Stopped/Restarted). Default `false`
    /// keeps these banners off unless the user opts in per task.
    public var notifyOnAction: Bool = false
    /// When true, this task sends a Bark push on completion (success and
    /// failure). The device URL is app-wide (`barkServerURL`); default `false`
    /// keeps existing tasks unchanged on SwiftData migration.
    public var barkPushEnabled: Bool = false
    /// When true (and Bark is on), a completion push is sent only if this
    /// run's script output differs from the previous run. Default `false`
    /// keeps existing tasks notifying on every completion.
    public var barkNotifyOnOutputChange: Bool = false
    /// SHA-256 of the last compared script output. Runtime only — not
    /// exported. nil means no previous run has been fingerprinted yet.
    public var lastBarkOutputFingerprint: String? = nil
    /// Upper bound (seconds) for random scheduling jitter — issue #38. When > 0
    /// every computed fire time gets a deterministic pseudo-random 0...N second
    /// delay so repeats don't hit machine-precise instants. Default 0 keeps
    /// existing tasks unchanged on SwiftData migration.
    public var jitterSeconds: Int = 0
    /// IANA time zone identifier (e.g. "Asia/Shanghai") the schedule's wall-clock
    /// times are interpreted in — issue #41. nil (default) follows the system
    /// time zone, preserving pre-existing behavior on SwiftData migration.
    public var timeZoneIdentifier: String? = nil

    @Relationship(deleteRule: .cascade, inverse: \ExecutionLog.task)
    public var executionLogs: [ExecutionLog]

    public init(
        name: String = "",
        scriptBody: String = "",
        shell: String = "/bin/zsh",
        scheduledDate: Date? = nil,
        repeatType: RepeatType = .daily,
        endRepeatType: EndRepeatType = .never,
        endRepeatDate: Date? = nil,
        endRepeatCount: Int? = nil,
        isEnabled: Bool = true,
        workingDirectory: String? = nil,
        environmentVariablesJSON: String? = nil,
        timeoutSeconds: Int = 300,
        notifyOnSuccess: Bool = true,
        notifyOnFailure: Bool = true
    ) {
        self.id = UUID()
        let nextSerial = UserDefaults.standard.integer(forKey: "taskSerialCounter") + 1
        UserDefaults.standard.set(nextSerial, forKey: "taskSerialCounter")
        self.serialNumber = nextSerial
        self.name = name
        self.scriptBody = scriptBody
        self.shell = shell
        self.scheduleType = "interval" // legacy default
        self.cronExpression = nil
        self.intervalSeconds = nil
        self.scheduledDate = scheduledDate
        self.repeatTypeRaw = repeatType.rawValue
        self.endRepeatTypeRaw = endRepeatType.rawValue
        self.endRepeatDate = endRepeatDate
        self.endRepeatCount = endRepeatCount
        self.executionCount = 0
        self.isEnabled = isEnabled
        self.createdAt = Date()
        self.updatedAt = Date()
        self.workingDirectory = workingDirectory
        self.environmentVariablesJSON = environmentVariablesJSON
        self.timeoutSeconds = timeoutSeconds
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
        self.executionLogs = []
        self.scriptFilePath = nil
    }

    // MARK: - Computed Properties

    public var schedule: ScheduleType {
        get { ScheduleType(rawValue: scheduleType) ?? .interval }
        set { scheduleType = newValue.rawValue }
    }

    public var repeatType: RepeatType {
        get { RepeatType(rawValue: repeatTypeRaw) ?? .daily }
        set { repeatTypeRaw = newValue.rawValue }
    }

    public var endRepeatType: EndRepeatType {
        get { EndRepeatType(rawValue: endRepeatTypeRaw) ?? .never }
        set { endRepeatTypeRaw = newValue.rawValue }
    }

    public var customIntervalUnit: CustomRepeatUnit {
        get { CustomRepeatUnit(rawValue: customIntervalUnitRaw) ?? .day }
        set { customIntervalUnitRaw = newValue.rawValue }
    }

    /// The task's schedule time zone, or nil to follow the system time zone.
    /// An identifier the current tz database no longer recognizes degrades to
    /// nil (system) rather than crashing or silently freezing the schedule.
    public var scheduleTimeZone: TimeZone? {
        get {
            guard let id = timeZoneIdentifier else { return nil }
            return TimeZone(identifier: id)
        }
        set { timeZoneIdentifier = newValue?.identifier }
    }

    /// Calendar for interpreting this task's schedule: system calendar, with
    /// the task's time zone applied when one is set.
    public var scheduleCalendar: Calendar {
        var calendar = Calendar.current
        if let tz = scheduleTimeZone {
            calendar.timeZone = tz
        }
        return calendar
    }

    /// Extra time-of-day points decoded from `additionalTimesJSON`. Each entry
    /// is a `DateComponents` carrying only `.hour` and `.minute`. Duplicates and
    /// values that match `scheduledDate`'s time are tolerated by the scheduler
    /// (de-duped at runtime), but the editor strips them on save.
    public var additionalTimes: [DateComponents] {
        get {
            guard let json = additionalTimesJSON,
                  let data = json.data(using: .utf8),
                  let strings = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return strings.compactMap(Self.parseHHmm)
        }
        set {
            let strings = newValue.compactMap(Self.formatHHmm)
            guard !strings.isEmpty,
                  let data = try? JSONEncoder().encode(strings)
            else {
                additionalTimesJSON = nil
                return
            }
            additionalTimesJSON = String(data: data, encoding: .utf8)
        }
    }

    private static func parseHHmm(_ s: String) -> DateComponents? {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        var c = DateComponents()
        c.hour = h
        c.minute = m
        return c
    }

    private static func formatHHmm(_ c: DateComponents) -> String? {
        guard let h = c.hour, (0...23).contains(h),
              let m = c.minute, (0...59).contains(m)
        else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    public var environmentVariables: [String: String]? {
        get {
            guard let json = environmentVariablesJSON,
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        }
        set {
            guard let value = newValue,
                  let data = try? JSONEncoder().encode(value) else {
                environmentVariablesJSON = nil
                return
            }
            environmentVariablesJSON = String(data: data, encoding: .utf8)
        }
    }

    /// Repeat cadence for display, cron-aware: cron tasks describe their
    /// expression instead of the placeholder `repeatType`.
    public var repeatDisplayName: String {
        if schedule == .cron, let expr = cronExpression, !expr.isEmpty {
            return (try? CronExpression(parsing: expr))?.humanReadable ?? expr
        }
        return repeatType.displayName
    }

    /// Human-readable schedule description
    public var scheduleDescription: String {
        if isManualOnly {
            return L10n.tr("schedule.manual_only")
        }

        var parts: [String] = []

        if let date = scheduledDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            if let tz = scheduleTimeZone {
                // Custom-zone schedule (issue #41): show the configured
                // wall-clock and flag the zone so it isn't read as local time.
                formatter.timeZone = tz
                let offset = tz.abbreviation(for: date) ?? tz.identifier
                parts.append("\(formatter.string(from: date)) (\(offset))")
            } else {
                parts.append(formatter.string(from: date))
            }
        }

        parts.append(repeatDisplayName)

        // Cron tasks are inherently repeating regardless of repeatType.
        if schedule == .cron || repeatType != .never {
            switch endRepeatType {
            case .never:
                break
            case .onDate:
                if let endDate = endRepeatDate {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    parts.append(L10n.tr("schedule.until", formatter.string(from: endDate)))
                }
            case .afterCount:
                if let count = endRepeatCount {
                    parts.append(L10n.tr("schedule.after_n_times", count))
                }
            }
        }

        return parts.joined(separator: " · ")
    }
}
