import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum ScriptSource: String, CaseIterable {
    case inline
    case file
    case template

    var label: String {
        switch self {
        case .inline: L10n.tr("editor.script.source.inline")
        case .file: L10n.tr("editor.script.source.file")
        case .template: L10n.tr("editor.script.source.template")
        }
    }
}

struct TaskEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var editorState = EditorState.shared

    var task: ScheduledTask? { editorState.taskToEdit }

    // Basic
    @State private var name = ""
    @State private var isEnabled = true

    // Schedule
    @State private var hasDate = true
    @State private var hasTime = true
    @State private var scheduledDate = Date()
    @State private var repeatType: RepeatType = .daily
    @State private var endRepeatType: EndRepeatType = .never
    @State private var endRepeatDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var endRepeatCount = 10

    // Script
    @State private var shell = "/bin/zsh"
    @State private var scriptBody = ""
    @State private var scriptSource: ScriptSource = .inline
    @State private var scriptFilePath = ""
    @State private var workingDirectory = ""
    @State private var timeoutSeconds = 300

    // Custom repeat
    @State private var customIntervalValue = 1
    @State private var customIntervalUnit: CustomRepeatUnit = .day
    @State private var showingCustomRepeat = false

    // Missed execution
    @State private var runMissedExecution = false

    // Notification
    @State private var notifyOnSuccess = false
    @State private var notifyOnFailure = true

    @State private var selectedTab = 0
    @State private var loadedTaskId: UUID?
    @State private var loadedForNew = false

    // Script validation
    @State private var isValidating = false
    @State private var validationResult: ScriptValidationResult?

    // Templates
    @State private var showingTemplateOverwriteConfirm = false
    @State private var pendingTemplate: ScriptTemplate?
    @ObservedObject private var templateStore = ScriptTemplateStore.shared

    enum ScriptValidationResult {
        case success
        case error(String)
    }

    var isEditing: Bool { task != nil }

    var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasScript: Bool
        switch scriptSource {
        case .inline, .template:
            hasScript = !scriptBody.trimmingCharacters(in: .whitespaces).isEmpty
        case .file:
            hasScript = !scriptFilePath.isEmpty && FileManager.default.fileExists(atPath: scriptFilePath)
        }
        return hasName && hasScript
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            basicTab
                .tabItem { Label(L10n.tr("editor.tab.basic"), systemImage: "square.and.pencil") }
                .tag(0)

            scheduleTab
                .tabItem { Label(L10n.tr("editor.tab.schedule"), systemImage: "calendar.badge.clock") }
                .tag(1)

            scriptTab
                .tabItem { Label(L10n.tr("editor.tab.script"), systemImage: "terminal") }
                .tag(2)

            notificationTab
                .tabItem { Label(L10n.tr("editor.tab.notification"), systemImage: "bell") }
                .tag(3)
        }
        .frame(width: 500)
        .fixedSize(horizontal: true, vertical: true)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button(L10n.tr("editor.cancel")) {
                        closeWindow()
                    }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                    Button(L10n.tr("editor.save")) {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .pointerCursor()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .onAppear { loadTask() }
        .onChange(of: editorState.taskToEdit?.id) { _, _ in
            loadTask()
        }
    }

    // MARK: - Basic Tab

    private var basicTab: some View {
        Form {
            Section(L10n.tr("editor.section.basic")) {
                TextField(L10n.tr("editor.name"), text: $name, prompt: Text(L10n.tr("editor.name.placeholder")))
                Toggle(L10n.tr("editor.enabled"), isOn: $isEnabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Schedule Tab

    private var scheduleTab: some View {
        Form {
            Section(L10n.tr("schedule.date_time")) {
                Toggle(isOn: $hasDate) {
                    Label(L10n.tr("schedule.date"), systemImage: "calendar")
                }

                if hasDate {
                    DatePicker(L10n.tr("schedule.date"), selection: $scheduledDate, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                }

                Toggle(isOn: $hasTime) {
                    Label(L10n.tr("schedule.time"), systemImage: "clock")
                }

                if hasTime {
                    DatePicker(L10n.tr("schedule.time"), selection: $scheduledDate, displayedComponents: .hourAndMinute)
                }
            }

            Section(L10n.tr("schedule.repeat_section")) {
                Picker(selection: $repeatType) {
                    Text(RepeatType.never.displayName).tag(RepeatType.never)
                    Divider()
                    ForEach(RepeatType.allCases.filter { $0 != .never && $0 != .custom }, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                    Divider()
                    Text(RepeatType.custom.displayName).tag(RepeatType.custom)
                } label: {
                    Label(L10n.tr("schedule.repeat"), systemImage: "repeat")
                }
                .onChange(of: repeatType) { _, newValue in
                    if newValue == .custom {
                        showingCustomRepeat = true
                    }
                }

                if repeatType == .custom {
                    LabeledContent(L10n.tr("repeat.every")) {
                        HStack(spacing: 6) {
                            TextField("", value: $customIntervalValue, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.center)
                            Picker("", selection: $customIntervalUnit) {
                                ForEach(CustomRepeatUnit.allCases, id: \.self) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                        }
                    }
                }

                if repeatType != .never {
                    Picker(selection: $endRepeatType) {
                        ForEach(EndRepeatType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    } label: {
                        Label(L10n.tr("schedule.end_repeat"), systemImage: "stop.circle")
                    }

                    if endRepeatType == .onDate {
                        DatePicker(L10n.tr("schedule.end_date"), selection: $endRepeatDate, displayedComponents: .date)
                    }

                    if endRepeatType == .afterCount {
                        LabeledContent(L10n.tr("schedule.end_count")) {
                            HStack(spacing: 6) {
                                TextField("", value: $endRepeatCount, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .multilineTextAlignment(.trailing)
                                Text(L10n.tr("schedule.times"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $runMissedExecution) {
                        Label(L10n.tr("schedule.run_missed"), systemImage: "clock.arrow.2.circlepath")
                    }
                }
            }

            if let nextDate = previewNextRun() {
                Section {
                    LabeledContent {
                        Text(nextDate.formatted(date: .abbreviated, time: .standard))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(L10n.tr("task.detail.next_run"), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Script Tab

    private var scriptTab: some View {
        Form {
            Section {
                Picker(L10n.tr("editor.script.source"), selection: $scriptSource) {
                    ForEach(ScriptSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                switch scriptSource {
                case .inline:
                    ScriptEditorView(scriptBody: $scriptBody)
                case .file:
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        if scriptFilePath.isEmpty {
                            Text(L10n.tr("editor.script.no_file"))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(scriptFilePath)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(L10n.tr("editor.script.choose_file")) {
                            chooseFile()
                        }
                        .pointerCursor()
                    }

                    if !scriptFilePath.isEmpty,
                       let content = try? String(contentsOfFile: scriptFilePath, encoding: .utf8) {
                        Text(content.prefix(500) + (content.count > 500 ? "\n..." : ""))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                case .template:
                    templatePicker
                }

                if scriptSource != .template {
                    HStack(spacing: 10) {
                        Button {
                            validateScript()
                        } label: {
                            if isValidating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(L10n.tr("editor.script.validate"))
                            }
                        }
                        .disabled(isValidating || currentScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointerCursor()

                        if let result = validationResult {
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

                        Button(L10n.tr("template.save_as")) {
                            SaveTemplateView.open(scriptBody: scriptBody, shell: shell, workingDirectory: workingDirectory, openWindow: openWindow)
                        }
                        .disabled(scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointerCursor()
                    }
                }
            }

            Section(L10n.tr("editor.section.script")) {
                Picker(L10n.tr("editor.shell"), selection: $shell) {
                    Text("/bin/zsh").tag("/bin/zsh")
                    Text("/bin/bash").tag("/bin/bash")
                    Text("/bin/sh").tag("/bin/sh")
                }

                WorkingDirectoryField(path: $workingDirectory)

                LabeledContent(L10n.tr("editor.timeout")) {
                    HStack(spacing: 6) {
                        TextField("", value: $timeoutSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text(L10n.tr("editor.timeout.seconds"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(L10n.tr("template.overwrite.title"), isPresented: $showingTemplateOverwriteConfirm) {
            Button(L10n.tr("editor.cancel"), role: .cancel) {
                pendingTemplate = nil
            }
            Button(L10n.tr("template.overwrite.confirm"), role: .destructive) {
                if let template = pendingTemplate {
                    applyTemplate(template)
                }
                pendingTemplate = nil
            }
        } message: {
            Text(L10n.tr("template.overwrite.message"))
        }
    }

    // MARK: - Template Picker

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(templateStore.groupedTemplates, id: \.category) { group in
                    if group.category.isEmpty {
                        ForEach(group.templates) { template in
                            Button(template.name) {
                                selectTemplate(template)
                            }
                        }
                    } else {
                        Menu(group.category) {
                            ForEach(group.templates) { template in
                                Button(template.name) {
                                    selectTemplate(template)
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(L10n.tr("template.menu"), systemImage: "doc.on.doc")
            }
            .pointerCursor()

            if !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                scriptBody != "#!/bin/zsh\n" && scriptBody != "#!/bin/bash\n" && scriptBody != "#!/bin/sh\n" {
                Text(scriptBody.prefix(300) + (scriptBody.count > 300 ? "\n..." : ""))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: 120)
            }
        }
    }

    private func selectTemplate(_ template: ScriptTemplate) {
        let hasContent = !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            scriptBody != "#!/bin/zsh\n" && scriptBody != "#!/bin/bash\n" && scriptBody != "#!/bin/sh\n"
        if hasContent {
            pendingTemplate = template
            showingTemplateOverwriteConfirm = true
        } else {
            applyTemplate(template)
        }
    }

    private func applyTemplate(_ template: ScriptTemplate) {
        scriptBody = template.scriptBody
        shell = template.shell
        if !template.workingDirectory.isEmpty {
            workingDirectory = template.workingDirectory
        }
        scriptSource = .inline
        validationResult = nil
    }

    // MARK: - Notification Tab

    private var notificationTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("editor.notify_success"), isOn: $notifyOnSuccess)
                Toggle(L10n.tr("editor.notify_failure"), isOn: $notifyOnFailure)
            } header: {
                Text(L10n.tr("editor.section.notification"))
            } footer: {
                Text(L10n.tr("editor.notify_hint"))
            }
        }
        .formStyle(.grouped)
        .onChange(of: shell) { _, newShell in
            if scriptSource == .inline {
                let newShebang = "#!\(newShell)"
                if scriptBody.hasPrefix("#!") {
                    // Replace existing shebang line
                    if let firstNewline = scriptBody.firstIndex(of: "\n") {
                        scriptBody = newShebang + scriptBody[firstNewline...]
                    } else {
                        scriptBody = newShebang + "\n"
                    }
                } else if scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scriptBody = newShebang + "\n"
                }
            }
        }
    }

    // MARK: - Script Validation

    private var currentScript: String {
        if scriptSource == .file {
            if scriptFilePath.isEmpty { return "" }
            return (try? String(contentsOfFile: scriptFilePath, encoding: .utf8)) ?? ""
        }
        return scriptBody
    }

    private func validateScript() {
        let script = currentScript
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isValidating = true
        validationResult = nil
        let selectedShell = shell

        Task.detached {
            let result: ScriptValidationResult

            if selectedShell.contains("python") {
                // Python: compile check
                result = await Self.runValidation(
                    executable: selectedShell,
                    arguments: ["-c", "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)", "-"],
                    input: script
                )
            } else {
                // Shell: syntax check with -n, then verify commands exist
                let syntaxResult = await Self.runValidation(
                    executable: selectedShell,
                    arguments: ["-n"],
                    input: script
                )

                switch syntaxResult {
                case .error:
                    result = syntaxResult
                case .success:
                    // Also check if commands in the script exist
                    let checkScript = """
                    check_cmd() {
                        command -v "$1" >/dev/null 2>&1 || echo "command not found: $1"
                    }
                    \(script.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
                        .compactMap { line -> String? in
                            // Extract first word (the command) from simple lines
                            let stripped = line
                                .replacingOccurrences(of: "^(if|then|else|fi|for|do|done|while|case|esac|function|export|local|declare|readonly|unset)\\b.*", with: "", options: .regularExpression)
                                .trimmingCharacters(in: .whitespaces)
                            guard !stripped.isEmpty else { return nil }
                            // Get the first token, skip variable assignments
                            let tokens = stripped.components(separatedBy: .whitespaces)
                            guard let first = tokens.first,
                                  !first.contains("="),
                                  !first.hasPrefix("$"),
                                  !first.hasPrefix("\""),
                                  !first.hasPrefix("'"),
                                  !first.hasPrefix("{"),
                                  !first.hasPrefix("}"),
                                  !first.hasPrefix("("),
                                  !first.hasPrefix(")"),
                                  !first.hasPrefix("|"),
                                  !first.hasPrefix("&"),
                                  !first.hasPrefix(";"),
                                  !first.hasPrefix("[")
                            else { return nil }
                            return "check_cmd \(first)"
                        }
                        .joined(separator: "\n"))
                    """
                    let warnings = await Self.runCommandCheck(executable: selectedShell, script: checkScript)
                    if let warnings, !warnings.isEmpty {
                        result = .error(warnings)
                    } else {
                        result = .success
                    }
                }
            }

            await MainActor.run {
                validationResult = result
                isValidating = false
            }
        }
    }

    private static func runValidation(executable: String, arguments: [String], input: String) async -> ScriptValidationResult {
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

    private static func runCommandCheck(executable: String, script: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", script]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func closeWindow() {
        loadedForNew = false
        editorState.close()
        // Close the editor window by finding it
        for window in NSApp.windows where window.identifier?.rawValue == "editor" || window.title == L10n.tr("editor.title.edit") || window.title == L10n.tr("editor.title.new") {
            window.close()
            return
        }
        NSApp.keyWindow?.close()
    }

    private func previewNextRun() -> Date? {
        guard hasDate || hasTime else { return nil }
        let tempTask = ScheduledTask()
        tempTask.scheduledDate = scheduledDate
        tempTask.repeatType = repeatType
        tempTask.endRepeatType = endRepeatType
        tempTask.endRepeatDate = endRepeatDate
        tempTask.endRepeatCount = endRepeatCount
        return TaskScheduler.shared.computeNextRunDate(for: tempTask)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .shellScript, .pythonScript,
            .plainText, .sourceCode,
            .unixExecutable,
            UTType(filenameExtension: "sh")!,
            UTType(filenameExtension: "zsh") ?? .plainText,
            UTType(filenameExtension: "rb") ?? .plainText,
            UTType(filenameExtension: "js") ?? .plainText,
        ]
        panel.message = L10n.tr("editor.script.choose_file")

        if panel.runModal() == .OK, let url = panel.url {
            scriptFilePath = url.path(percentEncoded: false)
        }
    }

    private func loadTask() {
        let currentId = task?.id
        if currentId == nil {
            guard !loadedForNew else { return }
            loadedForNew = true
        } else {
            guard currentId != loadedTaskId else { return }
            loadedForNew = false
        }
        loadedTaskId = currentId

        // Reset to defaults for new task
        name = ""
        isEnabled = true
        scheduledDate = Date()
        hasDate = true
        hasTime = true
        repeatType = .daily
        endRepeatType = .never
        endRepeatDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        endRepeatCount = 10
        customIntervalValue = 1
        customIntervalUnit = .day
        shell = "/bin/zsh"
        scriptBody = "#!/bin/zsh\n"
        scriptSource = .inline
        scriptFilePath = ""
        workingDirectory = ""
        timeoutSeconds = 300
        runMissedExecution = false
        notifyOnSuccess = false
        notifyOnFailure = true
        selectedTab = 0

        // Apply template if present (for new task from template)
        if let template = editorState.pendingTemplate, task == nil {
            name = template.name
            scriptBody = template.scriptBody
            shell = template.shell
            if !template.workingDirectory.isEmpty {
                workingDirectory = template.workingDirectory
            }
            scriptSource = .inline
            editorState.pendingTemplate = nil
        }

        guard let task else { return }
        name = task.name
        isEnabled = task.isEnabled
        shell = task.shell
        scriptBody = task.scriptBody
        workingDirectory = task.workingDirectory ?? ""
        timeoutSeconds = task.timeoutSeconds
        notifyOnSuccess = task.notifyOnSuccess
        notifyOnFailure = task.notifyOnFailure
        repeatType = task.repeatType
        endRepeatType = task.endRepeatType
        endRepeatDate = task.endRepeatDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        endRepeatCount = task.endRepeatCount ?? 10
        customIntervalValue = task.customIntervalValue
        customIntervalUnit = task.customIntervalUnit
        runMissedExecution = task.runMissedExecution

        if let date = task.scheduledDate {
            scheduledDate = date
            hasDate = true
            hasTime = true
        }

        if let filePath = task.scriptFilePath, !filePath.isEmpty {
            scriptSource = .file
            scriptFilePath = filePath
        } else {
            scriptSource = .inline
        }
    }

    private func save() {
        let target = task ?? ScheduledTask()

        target.name = name.trimmingCharacters(in: .whitespaces)
        target.shell = shell
        target.workingDirectory = workingDirectory.isEmpty ? nil : workingDirectory
        target.timeoutSeconds = timeoutSeconds
        target.notifyOnSuccess = notifyOnSuccess
        target.notifyOnFailure = notifyOnFailure
        target.isEnabled = isEnabled
        target.updatedAt = Date()

        // Always set scheduledDate so the scheduler has a base time
        target.scheduledDate = scheduledDate
        target.repeatType = repeatType
        target.endRepeatType = repeatType == .never ? .never : endRepeatType
        target.endRepeatDate = endRepeatType == .onDate ? endRepeatDate : nil
        target.endRepeatCount = endRepeatType == .afterCount ? endRepeatCount : nil
        target.customIntervalValue = customIntervalValue
        target.customIntervalUnit = customIntervalUnit
        target.runMissedExecution = runMissedExecution

        target.cronExpression = nil
        target.intervalSeconds = nil

        if scriptSource == .file {
            target.scriptFilePath = scriptFilePath
            target.scriptBody = ""
        } else {
            target.scriptFilePath = nil
            target.scriptBody = scriptBody
        }

        if isEnabled {
            target.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: target)
        } else {
            target.nextRunAt = nil
        }

        if task == nil {
            modelContext.insert(target)
        }

        try? modelContext.save()
        TaskScheduler.shared.rebuildSchedule()
        EditorState.shared.lastSavedTask = target
        closeWindow()
    }
}
