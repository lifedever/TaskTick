import Foundation
import SwiftData

public enum ExecutionStatus: String, Codable, CaseIterable, Sendable {
    case running = "running"
    case success = "success"
    case failure = "failure"
    case timeout = "timeout"
    case cancelled = "cancelled"
    /// A scheduled run that came due but never started — the Mac was asleep,
    /// TaskTick wasn't running, … — and the task doesn't opt into
    /// `runMissedExecution`. Recorded so the history shows the gap instead of
    /// the next run silently moving a day ahead (issue #59). Never counts as
    /// an execution: `executionCount` and the after-N end condition ignore it.
    case skipped = "skipped"

    public var displayName: String {
        switch self {
        case .running: L10n.tr("status.running")
        case .success: L10n.tr("status.success")
        case .failure: L10n.tr("status.failure")
        case .timeout: L10n.tr("status.timeout")
        case .cancelled: L10n.tr("status.cancelled")
        case .skipped: L10n.tr("status.skipped")
        }
    }

    public var iconName: String {
        switch self {
        case .running: "play.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .timeout: "clock.badge.exclamationmark.fill"
        case .cancelled: "stop.circle.fill"
        case .skipped: "forward.end.circle.fill"
        }
    }

    /// Optical size compensation, to be applied as `.scaleEffect`.
    ///
    /// `clock.badge.exclamationmark.fill` is the only badged symbol here and
    /// renders 16×16 at a font size where the `*.circle.fill` family renders
    /// 15×15 — untreated, a timeout row visibly outsizes every other row.
    /// A ratio rather than an absolute size, so the same value works at every
    /// call site (13pt in the task list, `.caption2` in the badge, `.title3`
    /// in the log header).
    public var iconScale: CGFloat {
        switch self {
        case .timeout: 15.0 / 16.0
        default: 1
        }
    }
}

/// Why a due run was skipped instead of run late. Stored on the `.skipped`
/// log as a raw string so the history can say what happened in the reader's
/// language, whatever language was active when it was recorded.
public enum SkipReason: String, Codable, CaseIterable, Sendable {
    /// The Mac slept through the scheduled time.
    case asleep = "asleep"
    /// The scheduled time fell before TaskTick launched.
    case notRunning = "not_running"
    /// The task's previous run was still going at the scheduled time.
    case stillRunning = "still_running"
    /// TaskTick was running and the Mac awake, but the run didn't start
    /// within the on-time window (e.g. the main thread was held up).
    case late = "late"

    public var displayName: String {
        switch self {
        case .asleep: L10n.tr("log.skipped.asleep")
        case .notRunning: L10n.tr("log.skipped.not_running")
        case .stillRunning: L10n.tr("log.skipped.still_running")
        case .late: L10n.tr("log.skipped.late")
        }
    }
}

public enum TriggerType: String, Codable, Sendable {
    case schedule = "schedule"
    case manual = "manual"
    case launch = "launch"

    public var displayName: String {
        switch self {
        case .schedule: L10n.tr("log.detail.trigger.schedule")
        case .manual:   L10n.tr("log.detail.trigger.manual")
        case .launch:   L10n.tr("log.detail.trigger.launch")
        }
    }
}

@Model
public final class ExecutionLog {
    public var id: UUID = UUID()
    public var task: ScheduledTask?
    public var startedAt: Date = Date()
    public var finishedAt: Date?
    public var statusRaw: String = ExecutionStatus.running.rawValue
    public var exitCode: Int?
    public var stdout: String?
    public var stderr: String?
    public var durationMs: Int?
    public var triggeredByRaw: String = TriggerType.manual.rawValue

    /// PID of the process group leader (set by setpgid in ScriptExecutor).
    /// Nil for logs from before this feature shipped, and for runs whose
    /// process never reached `setpgid` (start failure).
    public var pid: Int32?

    /// Output of `ps -p <pid> -o lstart=` captured right after spawn.
    /// Used as a PID-reuse fingerprint on reconcile: if the live PID's
    /// current lstart differs from this string, the PID has been recycled
    /// to a different process and we must NOT signal it.
    public var processStartTime: String?

    /// `SkipReason` raw value, set only on `.skipped` logs (issue #59).
    public var skipReasonRaw: String?

    public init(
        task: ScheduledTask? = nil,
        triggeredBy: TriggerType = .manual
    ) {
        self.id = UUID()
        self.task = task
        self.startedAt = Date()
        self.statusRaw = ExecutionStatus.running.rawValue
        self.triggeredByRaw = triggeredBy.rawValue
    }

    public var status: ExecutionStatus {
        get { ExecutionStatus(rawValue: statusRaw) ?? .running }
        set { statusRaw = newValue.rawValue }
    }

    public var triggeredBy: TriggerType {
        get { TriggerType(rawValue: triggeredByRaw) ?? .manual }
        set { triggeredByRaw = newValue.rawValue }
    }

    public var skipReason: SkipReason? {
        get { skipReasonRaw.flatMap(SkipReason.init(rawValue:)) }
        set { skipReasonRaw = newValue?.rawValue }
    }

    /// Maximum output size: 512KB
    public static let maxOutputSize = 512 * 1024

    /// Truncate large output by keeping the *suffix* — for build/start
    /// scripts the tail carries the stack trace, exit reason, and final
    /// status, which is the part users actually look at. Earlier versions
    /// kept the prefix and silently dropped the failure context.
    public static func truncateOutput(_ output: String) -> String {
        if output.utf8.count > maxOutputSize {
            let truncated = String(output.suffix(maxOutputSize / 2))
            return "--- 输出已截断 (超过 512KB，仅显示末尾) ---\n\n" + truncated
        }
        return output
    }

    /// Human-readable duration from a raw millisecond count.
    /// Auto-selects the unit so logs stop showing everything as raw `ms`:
    /// `120ms` · `1.2s` · `1m 5s` · `1h 2m`. Units are locale-neutral symbols
    /// (ms/s/m/h) so no localization churn and the output stays greppable.
    public static func formatDuration(_ ms: Int) -> String {
        guard ms > 0 else { return "0ms" }
        if ms < 1000 { return "\(ms)ms" }

        let totalSeconds = ms / 1000
        if totalSeconds < 60 {
            // Sub-minute: one decimal of seconds, trimming a trailing ".0".
            let secs = String(format: "%.1f", Double(ms) / 1000)
            let trimmed = secs.hasSuffix(".0") ? String(secs.dropLast(2)) : secs
            return "\(trimmed)s"
        }

        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }

    /// This log's duration as a human-readable string, or `nil` if it never finished.
    public var durationDisplay: String? {
        durationMs.map(Self.formatDuration)
    }
}
