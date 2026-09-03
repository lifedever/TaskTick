import Foundation
import SwiftData
import TaskTickCore

/// Strip ANSI escape sequences and terminal control codes.
/// Safe for plain text — only removes invisible control characters.
func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(
        of: "\\x1b\\[[0-9;]*[A-Za-z]|\\x1b\\][^\u{07}]*\u{07}|\\x1b[()][A-Za-z0-9]|[\\x00-\\x08\\x0e-\\x1f]",
        with: "",
        options: .regularExpression
    )
}

/// Strip ANSI codes, simulate \r overwrites, and collapse consecutive empty lines.
/// Use for final output (not live streaming).
func cleanTerminalOutput(_ text: String) -> String {
    var cleaned = stripANSI(text)
    // Simulate \r: for lines containing \r, keep only the text after the last \r
    if cleaned.contains("\r") {
        cleaned = cleaned
            .components(separatedBy: "\n")
            .map { line in
                guard line.contains("\r") else { return line }
                let parts = line.components(separatedBy: "\r")
                return parts.last(where: { !$0.isEmpty }) ?? ""
            }
            .joined(separator: "\n")
    }
    // Collapse runs of blank lines into a single blank line
    cleaned = cleaned.replacingOccurrences(
        of: "\\n{3,}",
        with: "\n\n",
        options: .regularExpression
    )
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Decode process output data, stripping ANSI escape sequences at the byte level first
/// to avoid corrupted multi-byte UTF-8 sequences (ANSI codes can split CJK characters).
func decodeProcessOutput(_ data: Data) -> String {
    var cleaned = Data()
    cleaned.reserveCapacity(data.count)
    var i = data.startIndex
    while i < data.endIndex {
        if data[i] == 0x1B { // ESC
            i = data.index(after: i)
            guard i < data.endIndex else { break }
            if data[i] == 0x5B { // [ → CSI: skip until letter
                i = data.index(after: i)
                while i < data.endIndex {
                    let b = data[i]; i = data.index(after: i)
                    if (0x40...0x7E).contains(b) { break }
                }
            } else if data[i] == 0x5D { // ] → OSC: skip until BEL
                i = data.index(after: i)
                while i < data.endIndex && data[i] != 0x07 { i = data.index(after: i) }
                if i < data.endIndex { i = data.index(after: i) }
            } else if data[i] == 0x28 || data[i] == 0x29 { // charset
                i = data.index(after: i)
                if i < data.endIndex { i = data.index(after: i) }
            }
        } else if data[i] < 0x20 && data[i] != 0x09 && data[i] != 0x0A && data[i] != 0x0D {
            i = data.index(after: i) // strip control chars except tab/newline/CR
        } else {
            cleaned.append(data[i]); i = data.index(after: i)
        }
    }
    return String(decoding: cleaned, as: UTF8.self)
}

/// Executes shell scripts using Process (NSTask) with async output capture.
@MainActor
final class ScriptExecutor: ObservableObject {

    @Published var runningProcesses: [UUID: Process] = [:]

    /// Processes that were running when a previous TaskTick session ended
    /// and we re-acquired on launch. Only have a bare PID — no Foundation
    /// `Process`, no live output capture. Cancellation works via direct
    /// signals to the process group.
    @Published var adoptedProcesses: [UUID: Int32] = [:]

    static let shared = ScriptExecutor()
    private let executionSemaphore = DispatchSemaphore(value: 8)

    private init() {}

    /// Run a task's script and return the execution log entry.
    @discardableResult
    func execute(task: ScheduledTask, triggeredBy: TriggerType = .manual, modelContext: ModelContext) async -> ExecutionLog {
        // Mark as running so every UI surface (list dot animation, menu bar
        // spinner, detail view stop button) reacts consistently regardless of
        // which entry point triggered the run. Set is idempotent, so callers
        // that also insert (TaskScheduler.fireTask) stay correct.
        TaskScheduler.shared.runningTaskIDs.insert(task.id)
        defer { TaskScheduler.shared.runningTaskIDs.remove(task.id) }

        let log = ExecutionLog(task: task, triggeredBy: triggeredBy)
        modelContext.insert(log)
        // Keep this denormalized counter hot-path friendly. The scheduler and UI
        // must not fault and walk an unbounded to-many relationship on every run.
        task.executionCount += 1
        let startTime = Date()
        // Bump the manual-run recency NOW (not at end) so long-running scripts
        // — dev servers, watchers, anything that runs for hours — surface to
        // the top of the lists immediately when the user hits play, instead
        // of staying buried until the process eventually exits.
        if triggeredBy == .manual {
            task.lastManualRunAt = startTime
        }
        do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }

        // Capture task properties before going off main actor
        let shell = task.shell
        let preRunCommand = task.preRunCommand
        let workingDirectory = task.workingDirectory
        let envVars = task.environmentVariables
        let timeoutSeconds = task.timeoutSeconds
        let taskId = task.id
        let ignoreExitCode = task.ignoreExitCode
        let taskName = task.name
        let notifyOnSuccess = task.notifyOnSuccess
        let notifyOnFailure = task.notifyOnFailure
        let notifyOnlyWhenOutput = task.notifyOnlyWhenOutput
        let pushEnabled = task.pushEnabled
        let pushOnlyWhenOutputChanged = task.pushOnlyWhenOutputChanged
        // Resolved up front, alongside every other captured property: the task
        // can be deleted mid-run, and the completion push should still reach
        // the channels the user picked for it.
        let pushChannels = pushEnabled ? PushChannelStore.resolve(for: task) : []
        let strongReminder = task.strongReminder
        // Switch off → empty template → every channel keeps its default wording,
        // while the text the user wrote stays on the task for later.
        let notificationTemplate = task.notificationTemplateEnabled ? task.notificationTemplate : ""
        let logId = log.id

        // Shortcut tasks bypass the shell pipeline entirely. The editor blocks
        // users from setting shell / preRun / cwd / env on shortcut tasks, so
        // we don't need to honor those fields here.
        let shortcutName = task.shortcutName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShortcutTask = !(shortcutName?.isEmpty ?? true)

        // Resolve script: inline body or file content (only used for shell-script tasks)
        let scriptBody: String
        let effectiveShell: String
        if isShortcutTask {
            scriptBody = ""
            effectiveShell = shell
        } else if let filePath = task.scriptFilePath, !filePath.isEmpty {
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                // Respect the shebang — but a shebang names an interpreter, not a shell,
                // so a .py/.rb/.js file gets exec'd rather than pasted into `<shell> -c`.
                let resolved = ScriptExecutor.resolveFileExecution(
                    fileContent: content,
                    filePath: filePath,
                    uiShell: shell
                )
                effectiveShell = resolved.shell
                scriptBody = resolved.body
            } else {
                // File not readable
                log.status = .failure
                log.stderr = "Cannot read script file: \(filePath)"
                log.finishedAt = Date()
                log.durationMs = 0
                do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }
                return log
            }
        } else {
            scriptBody = task.scriptBody
            effectiveShell = shell
        }

        // Prepend pre-run commands (e.g. proxy exports) into the same shell invocation
        // so exported env vars are visible to the script that follows.
        let finalScript: String = {
            let trimmed = preRunCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? scriptBody : trimmed + "\n" + scriptBody
        }()

        LiveOutputManager.shared.startTracking(taskId: taskId)

        // Manual scripts (dev servers, on-demand jobs) optionally tee their
        // output to ~/Library/Logs/TaskTick/<slug>.log so the user can
        // `tail -f` from a terminal or drop the file into Console.app.
        // Scheduled jobs are excluded — short bursty runs would just churn
        // the file and the database log already covers their needs.
        let logFileWriter: LogFileWriter? = {
            guard task.isManualOnly else { return nil }
            let enabled = UserDefaults.standard.object(forKey: "logs.streamManualToFile") as? Bool ?? true
            guard enabled else { return nil }
            return LogFileWriter(taskName: taskName)
        }()

        let result: ProcessResult
        if isShortcutTask, let name = shortcutName {
            // Invoke /usr/bin/shortcuts directly — no shell wrapping. Working
            // directory and env vars are nil: Shortcuts CLI runs in a system
            // service context that doesn't honor them anyway, and the editor
            // hides those fields for shortcut tasks.
            result = await runProcessCore(
                executableURL: URL(fileURLWithPath: "/usr/bin/shortcuts"),
                arguments: ["run", name],
                workingDirectory: nil,
                environmentVariables: nil,
                timeoutSeconds: timeoutSeconds,
                taskId: taskId,
                logId: logId,
                ignoreExitCode: ignoreExitCode,
                logFileWriter: logFileWriter
            )
        } else {
            result = await runProcess(
                shell: effectiveShell,
                script: finalScript,
                workingDirectory: workingDirectory,
                environmentVariables: envVars,
                timeoutSeconds: timeoutSeconds,
                taskId: taskId,
                logId: logId,
                ignoreExitCode: ignoreExitCode,
                logFileWriter: logFileWriter
            )
        }

        let endTime = Date()
        let durationMs = Int(endTime.timeIntervalSince(startTime) * 1000)

        // After await, task or log may have been deleted (user deleted task during execution).
        // Re-fetch from context to check they still exist before writing.
        let logDescriptor = FetchDescriptor<ExecutionLog>(predicate: #Predicate { $0.id == logId })
        let taskDescriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        let fetchedLog = try? modelContext.fetch(logDescriptor).first
        let fetchedTask = try? modelContext.fetch(taskDescriptor).first

        if let fetchedLog {
            fetchedLog.stdout = ExecutionLog.truncateOutput(result.stdout)
            fetchedLog.stderr = ExecutionLog.truncateOutput(result.stderr)
            fetchedLog.exitCode = result.exitCode
            fetchedLog.status = result.status
            fetchedLog.finishedAt = endTime
            fetchedLog.durationMs = durationMs
        }

        if let fetchedTask {
            fetchedTask.lastRunAt = endTime
            // Note: lastManualRunAt is set at task START (above) so running
            // scripts surface immediately. No need to update it again here.
            fetchedTask.updatedAt = endTime
        }

        do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }
        LiveOutputManager.shared.stopTracking(taskId: taskId)

        // Send notification using pre-captured properties (safe even if task was deleted)
        let globalNotificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        let durationText = "\(L10n.tr("notification.duration")) \(ExecutionLog.formatDuration(durationMs))"

        // A task's custom reminder text (issue #48) is rendered once and shared
        // by all three channels below — notification, remote push, strong reminder —
        // so the same run reads identically wherever the user sees it. nil
        // means "no template configured": each channel keeps its own wording.
        let customBody = NotificationTemplate.render(
            notificationTemplate,
            context: NotificationTemplate.Context(
                taskName: taskName,
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                durationMs: durationMs,
                succeeded: result.status == .success
            )
        )
        let customPushBody = customBody.map(NotificationTemplate.clampForPush)

        if result.status != .success {
            let exitInfo = "Exit code: \(result.exitCode ?? -1)"
            let stderrLine = result.stderr.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            let body = customPushBody
                ?? [exitInfo, durationText, stderrLine].filter { !$0.isEmpty }.joined(separator: " · ")
            let title = "[\(L10n.tr("notification.failed"))] \(taskName)"
            if globalNotificationsEnabled && notifyOnFailure {
                NotificationManager.shared.sendNotification(title: title, body: body)
            }
            sendPushIfNeeded(
                enabled: pushEnabled,
                onlyOnChange: pushOnlyWhenOutputChanged,
                channels: pushChannels,
                title: title,
                body: body,
                stdout: result.stdout,
                stderr: result.stderr,
                task: fetchedTask,
                modelContext: modelContext
            )
        } else {
            // "Notify only when output present" mode: polling scripts stay silent on
            // empty runs and only chirp when they `echo` something meaningful.
            // Whitespace-only stdout counts as no output (a script ending in a stray
            // newline shouldn't fire a notification).
            let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(notifyOnlyWhenOutput && trimmedStdout.isEmpty) {
                // Prefer stdout, fall back to stderr when stdout has no meaningful content
                let outputSource = ScriptExecutor.hasMeaningfulContent(result.stdout) ? result.stdout : result.stderr
                let outputLine = NotificationTemplate.firstMeaningfulLine(of: outputSource)
                let body = [durationText, outputLine].filter { !$0.isEmpty }.joined(separator: " · ")
                let title = "[\(L10n.tr("notification.succeeded"))] \(taskName)"
                let resolvedBody = customPushBody
                    ?? (body.isEmpty ? L10n.tr("notification.success") : body)
                if globalNotificationsEnabled && notifyOnSuccess {
                    NotificationManager.shared.sendNotification(title: title, body: resolvedBody)
                }
                sendPushIfNeeded(
                    enabled: pushEnabled,
                    onlyOnChange: pushOnlyWhenOutputChanged,
                    channels: pushChannels,
                    title: title,
                    body: resolvedBody,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    task: fetchedTask,
                    modelContext: modelContext
                )
            }
        }

        // Strong reminder: show floating panel with the custom reminder text, or
        // the full output when the task has no template.
        // Prefer stdout (actual results); fall back to stderr only if stdout is truly empty
        if result.status == .success && strongReminder {
            let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // The panel scrolls, so it shows the unclamped text.
            let output = customBody ?? (trimmedStdout.isEmpty ? result.stderr : result.stdout)
            StrongReminderPanel.shared.show(
                taskName: taskName,
                output: output,
                durationMs: durationMs
            )
        }

        return log
    }

    /// Remote push is independent of the macOS notification switch. When
    /// `onlyOnChange` is on, compare this run's output to the last
    /// fingerprinted run and stay silent if nothing changed.
    ///
    /// `channels` is resolved before the run rather than here: the task may
    /// have been deleted while the script was running, and the user's channel
    /// choice shouldn't disappear with it.
    private func sendPushIfNeeded(
        enabled: Bool,
        onlyOnChange: Bool,
        channels: [PushChannel],
        title: String,
        body: String,
        stdout: String,
        stderr: String,
        task: ScheduledTask?,
        modelContext: ModelContext
    ) {
        guard enabled, !channels.isEmpty else { return }
        if onlyOnChange {
            let fingerprint = PushDispatcher.outputFingerprint(stdout: stdout, stderr: stderr)
            let shouldSend = PushDispatcher.shouldNotifyOnOutputChange(
                previousFingerprint: task?.lastPushOutputFingerprint,
                currentFingerprint: fingerprint
            )
            if let task {
                task.lastPushOutputFingerprint = fingerprint
                do { try modelContext.save() } catch { NSLog("⚠️ Push fingerprint save failed: \(error)") }
            }
            guard shouldSend else { return }
        }
        PushDispatcher.shared.send(title: title, body: body, to: channels)
    }

    /// Cancel a running task. Hits both the immediate child (zsh) and the
    /// whole process group so descendants like `node`, `python`, etc. don't
    /// orphan when zsh exits without forwarding SIGTERM.
    ///
    /// Adopted entries (re-acquired from a previous session) only have a
    /// bare PID — no `Process` object, no waitpid (we're not the parent).
    /// They get SIGTERM with a 3s SIGKILL escalation; we don't waitpid
    /// because launchd has the parent slot.
    func cancel(taskId: UUID) {
        if let process = runningProcesses[taskId], process.isRunning {
            let pid = process.processIdentifier
            kill(-pid, SIGTERM)   // process group (no-op if setpgid lost the race)
            process.terminate()   // belt and suspenders for the immediate child
        }
        runningProcesses.removeValue(forKey: taskId)

        if let adoptedPID = adoptedProcesses[taskId] {
            kill(-adoptedPID, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
                if ProcessReconciler.isAlive(pid: adoptedPID) {
                    kill(-adoptedPID, SIGKILL)
                }
            }
            adoptedProcesses.removeValue(forKey: taskId)
            TaskScheduler.shared.runningTaskIDs.remove(taskId)
            // Normal-spawn cancels finalize the log when `execute(...)`'s
            // waitUntilExit returns; adopted entries have no such await
            // loop (launchd is the parent, not us). Write the terminal
            // state here so the UI stops showing the task as running.
            finalizeAdoptedLog(taskId: taskId, pid: adoptedPID, reason: "[TaskTick] Adopted process \(adoptedPID) was stopped by user.")
        }
    }

    /// Walk the most-recent `.running` log for `taskId` to a `.cancelled`
    /// terminal state. Used after we signal an adopted process — we don't
    /// have a `Process.waitUntilExit` to flush the log row for us.
    private func finalizeAdoptedLog(taskId: UUID, pid: Int32, reason: String) {
        let ctx = TaskTickApp._sharedModelContainer.mainContext
        let runningRaw = ExecutionStatus.running.rawValue
        let descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.statusRaw == runningRaw && $0.task?.id == taskId }
        )
        guard let log = try? ctx.fetch(descriptor).first else { return }
        let now = Date()
        log.status = .cancelled
        log.finishedAt = now
        if log.durationMs == nil {
            log.durationMs = Int(now.timeIntervalSince(log.startedAt) * 1000)
        }
        if (log.stderr ?? "").isEmpty {
            log.stderr = reason
        }
        try? ctx.save()
    }

    /// Synchronously terminate every running script. Designed for app-quit:
    /// SIGTERM the whole tree, give it `graceful` seconds to clean up, then
    /// SIGKILL anything still alive. Blocks the caller — ok during
    /// applicationWillTerminate, since the app is dying anyway.
    ///
    /// Adopted processes (re-acquired from a previous session, PID-only)
    /// go through the same two-stage flow via process-group signals.
    func cancelAll(graceful: TimeInterval = 0.3) {
        let processSnapshot = Array(runningProcesses.values)
        let adoptedSnapshot = Array(adoptedProcesses.values)
        runningProcesses.removeAll()
        adoptedProcesses.removeAll()

        guard !processSnapshot.isEmpty || !adoptedSnapshot.isEmpty else { return }

        for process in processSnapshot where process.isRunning {
            let pid = process.processIdentifier
            kill(-pid, SIGTERM)
            process.terminate()
        }
        for pid in adoptedSnapshot {
            kill(-pid, SIGTERM)
        }

        Thread.sleep(forTimeInterval: graceful)

        for process in processSnapshot where process.isRunning {
            let pid = process.processIdentifier
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        for pid in adoptedSnapshot where ProcessReconciler.isAlive(pid: pid) {
            kill(-pid, SIGKILL)
        }
    }

    /// Persist the running process's PID + start-time fingerprint to its
    /// ExecutionLog row. Called from a background queue right after
    /// `setpgid`. Uses the shared model container directly (mirrors
    /// AppDelegate's same-singleton access pattern) so we don't have to
    /// thread a non-Sendable `ModelContext` through cross-actor closures.
    private func persistRunningPID(logId: UUID, pid: Int32, startTime: String?) {
        let ctx = TaskTickApp._sharedModelContainer.mainContext
        let desc = FetchDescriptor<ExecutionLog>(predicate: #Predicate { $0.id == logId })
        if let live = try? ctx.fetch(desc).first {
            live.pid = pid
            live.processStartTime = startTime
            try? ctx.save()
        }
    }

    // MARK: - Private

    /// Thread-safe buffer for collecting pipe output from readabilityHandler closures.
    private final class PipeOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let _stdout = MutableDataBox()
        private let _stderr = MutableDataBox()

        func appendStdout(_ data: Data) {
            lock.lock()
            _stdout.data.append(data)
            lock.unlock()
        }

        func appendStderr(_ data: Data) {
            lock.lock()
            _stderr.data.append(data)
            lock.unlock()
        }

        func read() -> (stdout: Data, stderr: Data) {
            lock.lock()
            let result = (_stdout.data, _stderr.data)
            lock.unlock()
            return result
        }

        private final class MutableDataBox: @unchecked Sendable {
            var data = Data()
        }
    }

    /// Extract the interpreter from a shebang line.
    ///
    /// - `#!/opt/homebrew/bin/bash` → `/opt/homebrew/bin/bash` (must exist on disk)
    /// - `#!/usr/bin/env python3` → `python3` — a *bare name*, deliberately left for the
    ///   wrapping shell to resolve at run time. By then `runProcess` has applied Homebrew's
    ///   shellenv, so it lands on the same binary the user gets in an interactive terminal.
    ///   Resolving it here against the app's own PATH would pick /usr/bin/python3 (3.9)
    ///   instead — the exact mismatch the brewPrefix in `runProcess` exists to avoid.
    ///
    /// Returns nil when there's no shebang, or an absolute interpreter doesn't exist.
    ///
    /// Note: extra interpreter arguments (`#!/usr/bin/env -S python3 -u`) are dropped —
    /// only the interpreter itself is honored.
    nonisolated static func parseShebang(from script: String) -> String? {
        guard let firstLine = script.components(separatedBy: .newlines).first,
              firstLine.hasPrefix("#!") else { return nil }
        // Strip "#!" and trim whitespace, take the first token
        let interpreterLine = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let parts = interpreterLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = parts.first, !first.isEmpty else { return nil }
        // "#!/usr/bin/env <interpreter>" — skip env's own flags (e.g. -S), keep the name.
        if first == "/usr/bin/env" {
            guard let cmd = parts.dropFirst().first(where: { !$0.hasPrefix("-") }),
                  !cmd.isEmpty else { return nil }
            return cmd
        }
        // Direct path like "#!/opt/homebrew/bin/bash"
        if FileManager.default.isExecutableFile(atPath: first) {
            return first
        }
        return nil
    }

    /// Shell prelude that drops a run into the user's interactive environment:
    /// Homebrew's shellenv, then the rc file matching the shell.
    ///
    /// Shared by execution and validation so `python3` / `node` / `jq` resolve to the
    /// same binaries in both. Without the Homebrew part they fall back to the system
    /// copies (e.g. /usr/bin/python3 3.9) rather than what's on the user's interactive
    /// $PATH — the mismatch that once surfaced as "script output gets truncated" when
    /// an inline python3 hit a syntax feature newer than 3.9.
    nonisolated static func environmentPrelude(for shell: String) -> String {
        let fm = FileManager.default
        let brewPrefix: String
        if fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
            brewPrefix = "eval \"$(/opt/homebrew/bin/brew shellenv 2>/dev/null)\"; "
        } else if fm.isExecutableFile(atPath: "/usr/local/bin/brew") {
            brewPrefix = "eval \"$(/usr/local/bin/brew shellenv 2>/dev/null)\"; "
        } else {
            brewPrefix = ""
        }
        if shell.hasSuffix("zsh") {
            return brewPrefix + "[ -f ~/.zshrc ] && source ~/.zshrc 2>/dev/null; "
        }
        if shell.hasSuffix("bash") {
            return brewPrefix + "[ -f ~/.bashrc ] && source ~/.bashrc 2>/dev/null; "
        }
        return brewPrefix
    }

    /// Whether an interpreter speaks the `-l -c "<script text>"` calling convention
    /// that `runProcess` uses. Only shells do; python/ruby/node reject `-l` outright.
    ///
    /// The list comes from `/etc/shells` at run time rather than a hardcoded set of
    /// names, so a user's non-standard login shell is recognized too. Compared by
    /// basename because a shebang may name the interpreter without a path.
    nonisolated static func isShellInterpreter(_ interpreter: String) -> Bool {
        let name = (interpreter as NSString).lastPathComponent
        return AvailableShells.load().contains { ($0 as NSString).lastPathComponent == name }
    }

    /// Wrap a value in single quotes so spaces/quotes in a path can't split the command.
    nonisolated static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Decide which shell wraps the run, and what text that shell is handed, for a
    /// task backed by a script *file*.
    ///
    /// The distinction that matters: a shebang names an **interpreter**, which is not
    /// necessarily a **shell**. `runProcess` always invokes `<shell> -l -c "<text>"`, so
    /// the file's contents may only be pasted into `<text>` when the interpreter is
    /// itself a shell. For anything else (python/ruby/node/…) we keep the user's shell
    /// as the wrapper — preserving rc files, preRunCommand, env and cwd — and have it
    /// `exec` the real interpreter against the file on disk.
    ///
    /// `exec` matters: it replaces the shell process instead of forking a child, so the
    /// interpreter inherits the same PID. Timeout (SIGTERM→SIGKILL), cancellation and
    /// `ProcessReconciler`'s orphan adoption all act on the process actually doing the
    /// work, not on an idle shell wrapper.
    ///
    /// Pure function so it can be tested without SwiftData — see ScriptExecutorTests.
    nonisolated static func resolveFileExecution(
        fileContent: String,
        filePath: String,
        uiShell: String
    ) -> (shell: String, body: String) {
        guard let interpreter = parseShebang(from: fileContent) else {
            // No usable shebang: fall back to the shell picked in the UI, as before.
            return (uiShell, fileContent)
        }
        // An absolute shell path can run the contents directly — this is the long-standing
        // path for .sh files, kept byte-for-byte identical to avoid any regression.
        if interpreter.hasPrefix("/"), isShellInterpreter(interpreter) {
            return (interpreter, fileContent)
        }
        // Everything else — non-shell interpreters, and bare names like `bash` from
        // `#!/usr/bin/env bash` (which can't be a Process executableURL anyway) — is
        // handed to the interpreter as a file path.
        return (uiShell, "exec \(singleQuoted(interpreter)) \(singleQuoted(filePath))")
    }

    /// Check if a string contains meaningful printable content (not just whitespace).
    /// Pure string math with no actor state, so `NotificationTemplate` can pick
    /// the same output stream off the main actor.
    nonisolated static func hasMeaningfulContent(_ text: String) -> Bool {
        text.contains(where: { !$0.isWhitespace && !$0.isNewline && ($0.asciiValue.map({ $0 >= 32 }) ?? true) })
    }

    private struct ProcessResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int?
        let status: ExecutionStatus
    }

    private func runProcess(
        shell: String,
        script: String,
        workingDirectory: String?,
        environmentVariables: [String: String]?,
        timeoutSeconds: Int,
        taskId: UUID,
        logId: UUID,
        ignoreExitCode: Bool = false,
        logFileWriter: LogFileWriter? = nil
    ) async -> ProcessResult {
        // Use login shell (-l) for .zprofile, then source .zshrc/.bashrc
        // for user environment variables without full interactive mode
        // (which would load oh-my-zsh etc. and slow down execution).
        //
        let rcFile = ScriptExecutor.environmentPrelude(for: shell)

        return await runProcessCore(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-l", "-c", rcFile + script],
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables,
            timeoutSeconds: timeoutSeconds,
            taskId: taskId,
            logId: logId,
            ignoreExitCode: ignoreExitCode,
            logFileWriter: logFileWriter
        )
    }

    /// Lower-level Process runner shared by shell-script execution and direct
    /// CLI invocations (e.g. `shortcuts run`). Handles live output streaming,
    /// timeout (SIGTERM/SIGKILL), cancellation registration, and the bounded-task
    /// semaphore. Callers provide the executable + arguments; this method makes
    /// no assumptions about shell wrapping.
    private func runProcessCore(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String?,
        environmentVariables: [String: String]?,
        timeoutSeconds: Int,
        taskId: UUID,
        logId: UUID,
        ignoreExitCode: Bool = false,
        logFileWriter: LogFileWriter? = nil
    ) async -> ProcessResult {
        // Treat any non-positive value as "no timeout" — the script runs until it
        // exits on its own (or the user cancels). Lets users keep dev servers /
        // long-running interactive processes alive without TaskTick killing them.
        let isUnlimited = timeoutSeconds <= 0

        // Run the entire process on a background queue to avoid blocking the main thread
        return await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            // Bounded tasks share an 8-slot semaphore to prevent resource exhaustion.
            // Unlimited tasks would hold their slot indefinitely and starve the
            // scheduler, so they bypass the semaphore entirely.
            if !isUnlimited {
                self.executionSemaphore.wait()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if let dir = workingDirectory, !dir.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }

                if let envVars = environmentVariables {
                    var env = ProcessInfo.processInfo.environment
                    for (key, value) in envVars {
                        env[key] = value
                    }
                    process.environment = env
                }

                // Collect output incrementally via readabilityHandler for real-time streaming
                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                let outputBuffer = PipeOutputBuffer()
                // Coalesce pipe chunks at 50ms intervals before dispatching to
                // the main thread. With high-output scripts (npm run dev +
                // Spring Boot) the pipe can fire 100+ times/sec — without
                // batching each fire becomes a separate main-queue hop,
                // saturating the run loop. 50ms is well under perceptible UI
                // lag for live logs and lets us amortize the dispatch cost.
                let batcher = IOBatcher(taskId: taskId)

                // Scan stdout for `@tasktick:notify {…}` directives, strip them
                // from the sinks, and fire one TaskTick notification each.
                // Per-execution state: each run gets its own buffer + cap counter.
                let directiveScanner = NotificationDirectiveScanner()
                let directiveGate = DirectiveNotificationGate()
                // Dispatch on main (FIFO) so notifications fire in the order the
                // script printed them, and the cap counter stays single-threaded.
                let fireDirective: @Sendable (NotificationDirective) -> Void = { directive in
                    DispatchQueue.main.async {
                        guard directiveGate.count < DirectiveNotificationGate.maxPerRun else { return }
                        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
                        guard enabled else { return }
                        directiveGate.count += 1
                        NotificationManager.shared.sendNotification(title: directive.title, body: directive.body ?? "")
                    }
                }

                stdoutHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        stdoutHandle.readabilityHandler = nil
                        return
                    }
                    let (passthrough, directives) = directiveScanner.feed(data)
                    for directive in directives { fireDirective(directive) }
                    guard !passthrough.isEmpty else { return }
                    outputBuffer.appendStdout(passthrough)
                    logFileWriter?.append(passthrough)
                    batcher.appendStdout(passthrough)
                }

                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        stderrHandle.readabilityHandler = nil
                        return
                    }
                    outputBuffer.appendStderr(data)
                    logFileWriter?.append(data)
                    batcher.appendStderr(data)
                }

                do {
                    try process.run()
                } catch {
                    if !isUnlimited { self.executionSemaphore.signal() }
                    continuation.resume(returning: ProcessResult(
                        stdout: "",
                        stderr: "Failed to start process: \(error.localizedDescription)",
                        exitCode: nil,
                        status: .failure
                    ))
                    return
                }

                // Make the child its own process group leader so we can later
                // signal the entire descendant tree with `kill(-pgid, sig)`.
                // Without this, a `npm run dev` style script (zsh → npm → node)
                // would leave the node grandchild orphaned when we SIGTERM only
                // zsh — exactly the leak this app's quit-time cleanup must
                // avoid. Race window is the gap between run() and setpgid; in
                // practice scripts don't fork that early.
                setpgid(process.processIdentifier, process.processIdentifier)

                // Snapshot pid + start-time so the next app launch can tell
                // whether this exact process is still alive (vs. PID recycled
                // to a different program). Both fields are persisted to the
                // log so a crash here doesn't lose the breadcrumb. lstart is
                // captured here on the bg queue (not on @MainActor) so the
                // ~10ms `ps` subprocess doesn't stall the UI.
                let capturedPID = process.processIdentifier
                let capturedStart = ProcessReconciler.startTime(pid: capturedPID)

                Task { @MainActor in
                    self.runningProcesses[taskId] = process
                    self.persistRunningPID(logId: logId, pid: capturedPID, startTime: capturedStart)
                }

                // Timeout handling: send SIGTERM first, then SIGKILL 3s later if still alive.
                // Prevents scripts that ignore SIGTERM from blocking waitUntilExit forever,
                // which would leak the execution semaphore slot.
                // Skipped entirely for unlimited tasks (timeoutSeconds <= 0).
                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                let killWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                if !isUnlimited {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutWorkItem)
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds + 3), execute: killWorkItem)
                }

                // Wait for process to finish (on background thread — won't block UI)
                process.waitUntilExit()
                timeoutWorkItem.cancel()
                killWorkItem.cancel()

                // Drain remaining pipe data after process exits
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                let remainingStdout = stdoutHandle.readDataToEndOfFile()
                let remainingStderr = stderrHandle.readDataToEndOfFile()
                // The drained stdout tail goes through the scanner too (feed then
                // flush), so a directive printed right before exit — or one with no
                // trailing newline — is detected and stripped, not leaked to the log.
                let (drainPass, drainDirectives) = directiveScanner.feed(remainingStdout)
                let (flushPass, flushDirectives) = directiveScanner.flush()
                for directive in drainDirectives + flushDirectives { fireDirective(directive) }
                var tailStdout = drainPass
                tailStdout.append(flushPass)
                if !tailStdout.isEmpty {
                    outputBuffer.appendStdout(tailStdout)
                    logFileWriter?.append(tailStdout)
                    batcher.appendStdout(tailStdout)
                }
                if !remainingStderr.isEmpty {
                    outputBuffer.appendStderr(remainingStderr)
                    logFileWriter?.append(remainingStderr)
                    batcher.appendStderr(remainingStderr)
                }
                logFileWriter?.close()
                // Make sure any pending batched data lands in LiveOutputManager
                // before the executor flips the task off — otherwise the live
                // viewer can miss the last frame between exit and stopTracking.
                batcher.flushNow()

                // Remove from running processes
                Task { @MainActor in
                    self.runningProcesses.removeValue(forKey: taskId)
                }

                let (stdoutData, stderrData) = outputBuffer.read()
                let stdout = cleanTerminalOutput(decodeProcessOutput(stdoutData))
                let stderr = cleanTerminalOutput(decodeProcessOutput(stderrData))

                let exitCode = Int(process.terminationStatus)

                let status: ExecutionStatus
                switch process.terminationReason {
                case .uncaughtSignal:
                    status = .timeout
                case .exit:
                    status = (exitCode == 0 || ignoreExitCode) ? .success : .failure
                @unknown default:
                    status = .failure
                }

                if !isUnlimited { self.executionSemaphore.signal() }
                continuation.resume(returning: ProcessResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode,
                    status: status
                ))
            }
        }
    }
}
