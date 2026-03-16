import SwiftUI

/// Reusable script validation result type and runner.
enum ScriptValidationResult {
    case success
    case error(String)
}

/// Runs syntax validation on a shell or python script.
enum ScriptValidator {
    static func validate(script: String, shell: String) async -> ScriptValidationResult {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("Empty script")
        }

        if shell.contains("python") {
            return await runProcess(
                executable: shell,
                arguments: ["-c", "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)", "-"],
                input: script
            )
        }

        // Shell: syntax check with -n
        let syntaxResult = await runProcess(executable: shell, arguments: ["-n"], input: script)
        guard case .success = syntaxResult else { return syntaxResult }

        // Check commands exist
        let checkScript = """
        check_cmd() {
            command -v "$1" >/dev/null 2>&1 || echo "command not found: $1"
        }
        \(script.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
            .compactMap { line -> String? in
                let stripped = line
                    .replacingOccurrences(of: "^(if|then|else|fi|for|do|done|while|case|esac|function|export|local|declare|readonly|unset)\\b.*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                guard !stripped.isEmpty else { return nil }
                let tokens = stripped.components(separatedBy: .whitespaces)
                guard let first = tokens.first,
                      !first.contains("="), !first.hasPrefix("$"), !first.hasPrefix("\""),
                      !first.hasPrefix("'"), !first.hasPrefix("{"), !first.hasPrefix("}"),
                      !first.hasPrefix("("), !first.hasPrefix(")"), !first.hasPrefix("|"),
                      !first.hasPrefix("&"), !first.hasPrefix(";"), !first.hasPrefix("[")
                else { return nil }
                return "check_cmd \(first)"
            }
            .joined(separator: "\n"))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", checkScript]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !output.isEmpty {
                return .error(output)
            }
        } catch {}

        return .success
    }

    private static func runProcess(executable: String, arguments: [String], input: String) async -> ScriptValidationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return .success
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .error(errorMessage.isEmpty ? "Exit code: \(process.terminationStatus)" : errorMessage)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// Reusable validation button + result display row.
struct ScriptValidationRow: View {
    let script: String
    let shell: String
    @State private var isValidating = false
    @State private var result: ScriptValidationResult?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                validate()
            } label: {
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.tr("editor.script.validate"))
                }
            }
            .disabled(isValidating || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .pointerCursor()

            if let result {
                switch result {
                case .success:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(L10n.tr("editor.script.valid"))
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                case .error(let message):
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text(message)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            Spacer()
        }
    }

    private func validate() {
        isValidating = true
        result = nil
        let s = script
        let sh = shell
        Task.detached {
            let r = await ScriptValidator.validate(script: s, shell: sh)
            await MainActor.run {
                result = r
                isValidating = false
            }
        }
    }
}
