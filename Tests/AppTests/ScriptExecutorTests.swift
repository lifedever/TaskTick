import Testing
import Foundation
import SwiftData
import TaskTickCore
@testable import TaskTickApp

@Suite("ScriptExecutor Tests")
struct ScriptExecutorTests {

    @Test("Executor singleton exists")
    @MainActor
    func executorExists() {
        let executor = ScriptExecutor.shared
        #expect(executor != nil)
    }

    @Test("Executing a task increments its stored log counter")
    @MainActor
    func executionIncrementsStoredCounter() async throws {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let task = ScheduledTask(name: "counter", scriptBody: "printf ok")
        task.notifyOnSuccess = false
        task.notifyOnFailure = false
        context.insert(task)
        try context.save()

        let log = await ScriptExecutor.shared.execute(task: task, modelContext: context)

        #expect(log.status == .success)
        #expect(task.executionCount == 1)
        #expect(task.executionLogs.count == 1)
    }

    /// Reproduces the ipcheck output-truncation bug: runs the same ipcheck
    /// script through the exact Process+Pipe+decode+clean pipeline the app
    /// uses, and asserts that the proxycheck section and 综合建议 block — both
    /// emitted from a single inline `python3 -c` heredoc — survive intact.
    ///
    /// Skipped automatically when the script or a local proxy on 127.0.0.1:7890
    /// isn't available, so CI without network doesn't fail.
    @Test("ipcheck output is not silently truncated")
    func ipcheckOutputSurvivesProcessingPipeline() async throws {
        let scriptPath = "/Users/gefangshuai/Documents/Dev/script/paths/ipcheck"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            // Local dev machine fixture — not available in CI
            return
        }
        guard let scriptBody = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return
        }

        let preRun = """
        export https_proxy=http://127.0.0.1:7890
        export http_proxy=http://127.0.0.1:7890
        export all_proxy=socks5://127.0.0.1:7891
        """
        // Exactly matches ScriptExecutor.runProcess assembly
        let fm = FileManager.default
        let brewPrefix: String
        if fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
            brewPrefix = "eval \"$(/opt/homebrew/bin/brew shellenv 2>/dev/null)\"; "
        } else if fm.isExecutableFile(atPath: "/usr/local/bin/brew") {
            brewPrefix = "eval \"$(/usr/local/bin/brew shellenv 2>/dev/null)\"; "
        } else {
            brewPrefix = ""
        }
        let rcFile = brewPrefix + "[ -f ~/.bashrc ] && source ~/.bashrc 2>/dev/null; "
        let fullScript = rcFile + preRun + "\n" + scriptBody

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-l", "-c", fullScript]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let stdoutBox = Box()
        let stderrBox = Box()

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        outHandle.readabilityHandler = { handle in
            let d = handle.availableData
            guard !d.isEmpty else { handle.readabilityHandler = nil; return }
            stdoutBox.append(d)
        }
        errHandle.readabilityHandler = { handle in
            let d = handle.availableData
            guard !d.isEmpty else { handle.readabilityHandler = nil; return }
            stderrBox.append(d)
        }

        try process.run()
        process.waitUntilExit()

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        stdoutBox.append(outHandle.readDataToEndOfFile())
        stderrBox.append(errHandle.readDataToEndOfFile())
        let stdoutData = stdoutBox.read()
        let stderrData = stderrBox.read()

        // Pipeline the app applies to captured bytes
        let rawStdout = decodeProcessOutput(stdoutData)
        let cleanedStdout = cleanTerminalOutput(rawStdout)
        let rawStderr = decodeProcessOutput(stderrData)

        // If there's no proxy locally, skip — otherwise the script fails as
        // expected and the assertions wouldn't be meaningful.
        if cleanedStdout.contains("无法获取出口 IP") {
            return
        }

        // These three fragments are each emitted by a different layer of the
        // script. If any single one is missing, we know which layer got eaten.
        let expectations: [(label: String, needle: String)] = [
            ("ipinfo.io bash section",          "归属信息 (ipinfo.io)"),
            ("proxycheck header (bash echo)",   "风控评分 (proxycheck.io)"),
            ("proxycheck details (python3)",    "Risk Score"),
            ("综合建议 block (python3)",         "💡 综合建议"),
            ("链接尾部 (bash echo)",             "查住宅代理挂靠"),
        ]

        for (label, needle) in expectations {
            #expect(
                cleanedStdout.contains(needle),
                "Missing '\(label)' in app-processed output.\nSTDOUT:\n\(cleanedStdout)\n\nSTDERR:\n\(rawStderr)"
            )
        }
    }

    // MARK: - Shebang / interpreter resolution

    @Test("Shebang parsing handles env form, absolute paths and junk")
    @MainActor
    func shebangParsing() {
        // `#!/usr/bin/env <name>` yields a bare name, left for the shell to resolve on PATH.
        #expect(ScriptExecutor.parseShebang(from: "#!/usr/bin/env python3\nprint(1)") == "python3")
        #expect(ScriptExecutor.parseShebang(from: "#!/usr/bin/env -S python3 -u\n") == "python3")
        #expect(ScriptExecutor.parseShebang(from: "#!/usr/bin/env bash\n") == "bash")
        // Absolute interpreters are only accepted when they exist on disk.
        #expect(ScriptExecutor.parseShebang(from: "#!/bin/bash\necho hi") == "/bin/bash")
        #expect(ScriptExecutor.parseShebang(from: "#!/nope/nonexistent\n") == nil)
        // Malformed / absent.
        #expect(ScriptExecutor.parseShebang(from: "echo hi") == nil)
        #expect(ScriptExecutor.parseShebang(from: "") == nil)
        #expect(ScriptExecutor.parseShebang(from: "#!/usr/bin/env\n") == nil)
    }

    @Test("Shell interpreters are told apart from language interpreters")
    @MainActor
    func shellInterpreterDetection() {
        #expect(ScriptExecutor.isShellInterpreter("/bin/bash"))
        #expect(ScriptExecutor.isShellInterpreter("/bin/zsh"))
        #expect(ScriptExecutor.isShellInterpreter("bash"))  // bare name from the env form
        #expect(!ScriptExecutor.isShellInterpreter("python3"))
        #expect(!ScriptExecutor.isShellInterpreter("/usr/bin/python3"))
        #expect(!ScriptExecutor.isShellInterpreter("node"))
    }

    @Test("Non-shell script files are exec'd instead of pasted into the shell")
    @MainActor
    func nonShellFileIsExeced() {
        let resolved = ScriptExecutor.resolveFileExecution(
            fileContent: "#!/usr/bin/env python3\nprint(1)",
            filePath: "/tmp/a b.py",  // space in the path must survive quoting
            uiShell: "/bin/zsh"
        )
        #expect(resolved.shell == "/bin/zsh")
        #expect(resolved.body == "exec 'python3' '/tmp/a b.py'")
    }

    /// A quote in the path must not be able to end the quoted argument and let the
    /// rest of the filename run as shell code.
    @Test("Quotes in the script path are neutralised")
    @MainActor
    func quotesInPathAreEscaped() {
        let resolved = ScriptExecutor.resolveFileExecution(
            fileContent: "#!/usr/bin/env python3\n",
            filePath: "/tmp/it's; rm -rf ~/.py",
            uiShell: "/bin/zsh"
        )
        #expect(resolved.body == "exec 'python3' '/tmp/it'\\''s; rm -rf ~/.py'")
    }

    @Test("An absolute non-shell interpreter also gets the exec path")
    @MainActor
    func absoluteNonShellInterpreterIsExeced() {
        let resolved = ScriptExecutor.resolveFileExecution(
            fileContent: "#!/usr/bin/python3\nprint(1)",
            filePath: "/tmp/x.py",
            uiShell: "/bin/zsh"
        )
        #expect(resolved.shell == "/bin/zsh")
        #expect(resolved.body == "exec '/usr/bin/python3' '/tmp/x.py'")
    }

    @Test("Absolute-shell script files keep the legacy inline-contents path")
    @MainActor
    func shellFileKeepsLegacyPath() {
        let content = "#!/bin/bash\necho hi"
        let resolved = ScriptExecutor.resolveFileExecution(
            fileContent: content, filePath: "/tmp/x.sh", uiShell: "/bin/zsh"
        )
        #expect(resolved.shell == "/bin/bash")
        #expect(resolved.body == content)
    }

    @Test("Missing shebang falls back to the shell picked in the UI")
    @MainActor
    func noShebangFallsBack() {
        let resolved = ScriptExecutor.resolveFileExecution(
            fileContent: "echo hi", filePath: "/tmp/x", uiShell: "/bin/zsh"
        )
        #expect(resolved.shell == "/bin/zsh")
        #expect(resolved.body == "echo hi")
    }

    /// Regression for the `zsh:76: parse error near ')'` report: a
    /// `#!/usr/bin/env python3` file used to be pasted verbatim into `zsh -l -c`,
    /// so zsh tried to parse Python and died on the first parenthesis. Runs the
    /// real assembly through a real Process, the way `runProcess` does.
    @Test("A python script file actually runs end to end")
    @MainActor
    func pythonFileRunsEndToEnd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-shebang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Parentheses and quotes on purpose — this is exactly what a shell chokes on.
        let file = dir.appendingPathComponent("probe.py")
        try """
        #!/usr/bin/env python3
        import os
        values = (1, 2, 3)
        print("sum=%d" % sum(values))
        print("pid=%d" % os.getpid())
        """.write(to: file, atomically: true, encoding: .utf8)

        let content = try String(contentsOf: file, encoding: .utf8)
        let resolved = ScriptExecutor.resolveFileExecution(
            fileContent: content, filePath: file.path, uiShell: "/bin/zsh"
        )

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: resolved.shell)
        process.arguments = ["-l", "-c", resolved.body]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let shellPID = process.processIdentifier
        let out = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(out.contains("sum=6"), "stdout: \(out)\nstderr: \(err)")
        #expect(process.terminationStatus == 0, "stderr: \(err)")

        // `exec` must replace the shell rather than fork a child, otherwise the
        // timeout's SIGTERM/SIGKILL and cancellation would hit an idle wrapper
        // while the interpreter kept running.
        #expect(
            out.contains("pid=\(shellPID)"),
            "interpreter should inherit the shell's PID via exec. stdout: \(out)"
        )
    }
}
