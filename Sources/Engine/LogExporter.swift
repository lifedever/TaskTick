import AppKit
import Foundation
import UniformTypeIdentifiers
import TaskTickCore

/// Exports execution logs as plain-text `.log` files.
///
/// - A single log exports to one `.log` file.
/// - A batch ("Export All") exports to a `.zip` archive holding one `.log`
///   file per log entry — one file per list row, named by the run's date —
///   so the archive mirrors the on-screen log list.
///
/// The file body uses fixed, locale-neutral English field labels (Task, Status,
/// Duration, STDOUT, …) on purpose: a `.log` artifact is a technical document
/// that should stay stable and greppable regardless of the app's UI language.
/// Only the surrounding UI (buttons, save-panel title) is localized.
@MainActor
struct LogExporter {

    /// Export a single log to a `.log` file.
    static func exportLog(_ log: ExecutionLog) {
        let base = "\(fileStamp.string(from: log.startedAt))-\(sanitize(log.task?.name ?? L10n.tr("log.unknown_task")))"
        save(render: { try renderOne(log).write(to: $0, atomically: true, encoding: .utf8) },
             contentType: UTType(filenameExtension: "log") ?? .plainText,
             suggestedName: "\(base).log")
    }

    /// Export a batch of logs to a `.zip` archive, one `.log` per entry.
    /// `nameHint` seeds the archive name (e.g. a task name, or "TaskTick").
    static func exportLogs(_ logs: [ExecutionLog], nameHint: String) {
        guard !logs.isEmpty else { return }
        let hint = sanitize(nameHint)
        let folder = "\(hint)-logs-\(fileStamp.string(from: Date()))"
        let files = namedFiles(for: logs)

        save(render: { try makeZip(folderName: folder, files: files, to: $0) },
             contentType: .zip,
             suggestedName: "\(folder).zip")
    }

    // MARK: - Save panel

    /// Runs the save panel, then hands the chosen URL to `render` (which writes
    /// the file/archive). Write failures surface through the shared error alert.
    private static func save(render: (URL) throws -> Void,
                             contentType: UTType,
                             suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedName
        panel.title = L10n.tr("log.export.title")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try render(url)
            // Reveal the exported file in Finder (selected, not opened — so a
            // .zip isn't auto-unarchived).
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentErrorAlert(titleKey: "error.export_failed.title",
                              messageKey: "error.export_failed.message",
                              error: error)
        }
    }

    // MARK: - Zip

    /// One `<date>-<task>.log` file per log, with the date leading so the archive
    /// sorts chronologically. Collisions (same task, same second) get a numeric suffix.
    private static func namedFiles(for logs: [ExecutionLog]) -> [(name: String, contents: String)] {
        var used = Set<String>()
        return logs.map { log in
            let base = "\(fileStamp.string(from: log.startedAt))-\(sanitize(log.task?.name ?? L10n.tr("log.unknown_task")))"
            var name = "\(base).log"
            var n = 2
            while used.contains(name) {
                name = "\(base)-\(n).log"
                n += 1
            }
            used.insert(name)
            return (name, renderOne(log))
        }
    }

    /// Build a `.zip` at `destination` from in-memory log files. Uses
    /// `NSFileCoordinator(.forUploading)` — the system's dependency-free zipper —
    /// over a temporary folder so the archive contains `<folderName>/<file>.log`.
    private static func makeZip(folderName: String,
                                files: [(name: String, contents: String)],
                                to destination: URL) throws {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("tasktick-export-\(UUID().uuidString)", isDirectory: true)
        let dir = tmpRoot.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }

        for file in files {
            try file.contents.write(to: dir.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        }

        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zippedURL in
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: zippedURL, to: destination)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    // MARK: - Rendering

    private static func renderOne(_ log: ExecutionLog) -> String {
        let sep = String(repeating: "=", count: 64)
        var lines: [String] = []
        lines.append(sep)
        lines.append(field("Task", log.task?.name ?? L10n.tr("log.unknown_task")))
        lines.append(field("Status", log.status.displayName))
        if log.status == .skipped {
            lines.append(field("Reason", log.skipReason?.displayName ?? L10n.tr("log.skipped.generic")))
        }
        lines.append(field("Trigger", log.triggeredBy.displayName))
        lines.append(field("Started", bodyStamp.string(from: log.startedAt)))
        if let finished = log.finishedAt {
            lines.append(field("Finished", bodyStamp.string(from: finished)))
        }
        if let ms = log.durationMs {
            lines.append(field("Duration", ExecutionLog.formatDuration(ms)))
        }
        if let code = log.exitCode {
            lines.append(field("Exit Code", "\(code)"))
        }
        lines.append(sep)

        if let stdout = log.stdout, !stdout.isEmpty {
            lines.append("STDOUT:")
            lines.append(stdout)
        }
        if let stderr = log.stderr, !stderr.isEmpty {
            if log.stdout?.isEmpty == false { lines.append("") }
            lines.append("STDERR:")
            lines.append(stderr)
        }
        return lines.joined(separator: "\n")
    }

    private static func field(_ label: String, _ value: String) -> String {
        // Pad labels to a column so the header block lines up.
        let padded = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        return "\(padded)\(value)"
    }

    // MARK: - Formatters

    /// Compact, filesystem-safe timestamp for filenames.
    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Readable timestamp for the file body.
    private static let bodyStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Strip characters that are illegal or awkward in filenames.
    private static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "TaskTick" : cleaned
    }
}
