import SwiftUI
import SwiftData
import KeyboardShortcuts
import UniformTypeIdentifiers
import TaskTickCore

enum ScriptSource: String, CaseIterable {
    case inline
    case file
    case template
    case shortcut

    var label: String {
        switch self {
        case .inline: L10n.tr("editor.script.source.inline")
        case .file: L10n.tr("editor.script.source.file")
        case .template: L10n.tr("editor.script.source.template")
        case .shortcut: L10n.tr("editor.script.source.shortcut")
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
    /// Whoever already owns the chord staged in the draft, or nil when it's
    /// free. Recomputed on every recording so the user finds out before saving,
    /// not after pressing a key that silently does nothing.
    @State private var hotkeyConflictOwner: String?

    // Schedule
    @State private var isManualOnly = false
    @State private var hasDate = true
    @State private var hasTime = true
    @State private var scheduledDate = Date()
    /// Extra fire times in addition to `scheduledDate`'s time. Each Date here
    /// is anchored to "today" — only the hour+minute matter; the day-of-week
    /// and date come from the schedule's recurrence at save / runtime.
    @State private var additionalTimes: [Date] = []
    @State private var repeatType: RepeatType = .daily
    /// Cron mode rides the legacy schedule channel (`scheduleType` +
    /// `cronExpression`) — TaskScheduler prefers it over the RepeatType system
    /// whenever `schedule == .cron`. See issue #38.
    @State private var useCron = false
    @State private var cronExpression = "*/5 * * * *"
    @State private var jitterSeconds = 0
    /// IANA identifier the schedule's wall-clock times are interpreted in;
    /// nil = follow the system time zone (issue #41).
    @State private var timeZoneID: String? = nil
    @State private var endRepeatType: EndRepeatType = .never
    @State private var endRepeatDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var endRepeatCount = 10

    // Script
    @State private var shell = "/bin/zsh"
    @State private var scriptBody = ""
    @State private var scriptSource: ScriptSource = .inline
    @State private var scriptFilePath = ""
    @State private var preRunCommand = ""
    @State private var preRunEnabled = false
    @State private var workingDirectory = ""
    @State private var timeoutSeconds = 300

    // Shortcut (source == .shortcut)
    @State private var shortcutName: String = ""
    @State private var availableShortcuts: [String] = []
    @State private var isLoadingShortcuts = false
    @State private var shortcutsLoadError: String?

    // Custom repeat
    @State private var customIntervalValue = 1
    @State private var customIntervalUnit: CustomRepeatUnit = .day
    @State private var showingCustomRepeat = false

    // Missed execution
    @State private var runMissedExecution = false

    // Run on each app launch (issue #25)
    @State private var runOnLaunch = false

    // Notification
    @State private var notifyOnSuccess = true
    @State private var notifyOnFailure = true
    @State private var notifyOnAction = false
    @State private var notifyOnlyWhenOutput = false
    @State private var notificationTemplateEnabled = false
    @State private var notificationTemplate = ""
    @State private var pushEnabled = false
    @State private var pushOnSuccess = true
    @State private var pushOnFailure = true
    @State private var pushOnlyWhenOutput = false
    @State private var pushOnlyWhenOutputChanged = false
    @State private var pushTemplateEnabled = false
    @State private var pushTemplate = ""
    /// nil = "every enabled channel" (see `selectedChannelIDs`).
    @State private var pushChannelIDs: [UUID]?
    @ObservedObject private var pushSettings = PushChannelSettings.shared
    @State private var strongReminder = false
    @State private var ignoreExitCode = false

    @State private var selectedTab: Tab = .basic
    @State private var loadedTrigger = -1

    // Script validation
    @State private var isValidating = false
    @State private var validationResult: ScriptValidationResult?

    // Templates
    @State private var showingTemplateOverwriteConfirm = false
    @State private var pendingTemplate: ScriptTemplate?
    @ObservedObject private var templateStore = ScriptTemplateStore.shared

    var isEditing: Bool { task != nil }

    var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasScript: Bool
        switch scriptSource {
        case .inline, .template:
            hasScript = !scriptBody.trimmingCharacters(in: .whitespaces).isEmpty
        case .file:
            hasScript = fileExistsAtScriptPath
        case .shortcut:
            hasScript = !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let hasValidCron = !useCron || (try? CronExpression(parsing: cronExpression)) != nil
        return hasName && hasScript && hasValidCron
    }

    /// Selection surface for the repeat picker: the 16 RepeatType cases plus
    /// the cron-expression mode, which lives outside the enum (model-side it
    /// maps to `scheduleType == "cron"`, keeping RepeatType's raw values
    /// untouched for data compatibility).
    private enum RepeatChoice: Hashable {
        case repeats(RepeatType)
        case cron
    }

    private var repeatChoice: Binding<RepeatChoice> {
        Binding(
            get: { useCron ? .cron : .repeats(repeatType) },
            set: { choice in
                switch choice {
                case .cron:
                    useCron = true
                case .repeats(let type):
                    useCron = false
                    repeatType = type
                }
            }
        )
    }

    enum Tab: String, CaseIterable {
        case basic = "editor.tab.basic"
        case script = "editor.tab.script"
        case schedule = "editor.tab.schedule"
        case settings = "editor.tab.settings"
        case notification = "editor.tab.notification"
        case push = "editor.tab.push"

        var title: String { L10n.tr(rawValue) }

        var symbol: String {
            switch self {
            case .basic: return "square.and.pencil"
            case .script: return "terminal"
            case .schedule: return "calendar.badge.clock"
            case .settings: return "gearshape"
            case .notification: return "bell"
            case .push: return "paperplane"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            basicTab
                .tabItem { Label(Tab.basic.title, systemImage: Tab.basic.symbol) }
                .tag(Tab.basic)

            scriptContentTab
                .tabItem { Label(Tab.script.title, systemImage: Tab.script.symbol) }
                .tag(Tab.script)

            scheduleTab
                .tabItem { Label(Tab.schedule.title, systemImage: Tab.schedule.symbol) }
                .tag(Tab.schedule)

            scriptSettingsTab
                .tabItem { Label(Tab.settings.title, systemImage: Tab.settings.symbol) }
                .tag(Tab.settings)

            notificationTab
                .tabItem { Label(Tab.notification.title, systemImage: Tab.notification.symbol) }
                .tag(Tab.notification)

            pushTab
                .tabItem { Label(Tab.push.title, systemImage: Tab.push.symbol) }
                .tag(Tab.push)
        }
        .frame(width: Self.windowWidth())
        // Height comes from `resizableToTabContent` below, not `fixedSize`.
        .fixedSize(horizontal: true, vertical: false)
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
            // A tab taller than the screen now scrolls (issue #55), and its
            // rows pass underneath this bar — without a fill they show through
            // the buttons. The window's own background keeps it seamless with
            // the form at rest, white in light mode and dark in dark mode.
            .background(Color(nsColor: .windowBackgroundColor))
        }
        // Short tabs lock the window to their content, as before; a tab taller
        // than this (schedule, notifications) opens at it and drags up to show
        // the rest. Applied outside the button bar so the bar is counted in
        // both ends of the range — inside, its slack let short tabs drag.
        .resizableToTabContent(defaultHeight: Self.defaultContentHeight)
        // The window's own title (TaskTickApp.swift) is evaluated once when the
        // Scene is declared, so it keeps saying "New Task" even when opened via
        // Edit. Setting it from inside the view re-evaluates with `editorState`,
        // which is observed here.
        .navigationTitle(task == nil ? L10n.tr("editor.title.new") : L10n.tr("editor.title.edit"))
        .onAppear { loadTask() }
        .onChange(of: editorState.openTrigger) { _, _ in
            loadTask()
        }
        .onDisappear {
            // Covers the paths that never reach closeWindow() — the red button,
            // ⌘W, the window being torn down. A draft left behind would keep
            // its chord claimed system-wide with nothing listening.
            TaskHotkeyManager.shared.discardDraft()
        }
    }

    /// How wide the editor has to be for its whole tab bar to stay visible.
    ///
    /// Since macOS 15 the tab bar sits in the title bar, centered, with the
    /// traffic lights to its left; when it doesn't fit, macOS folds tabs into a
    /// "»" overflow menu and the `.contentSize` window can't be dragged wider
    /// (issue #39 item 1). A fixed 720 held five tabs in German with little to
    /// spare; the Push tab (issue #55) made that a coin toss, so — as
    /// `SettingsView.windowWidth` does — measure the titles about to be drawn.
    static func windowWidth(screenWidth: CGFloat? = nil) -> CGFloat {
        windowWidth(titles: Tab.allCases.map(\.title), screenWidth: screenWidth)
    }

    /// Split out so tests can feed it every language's titles straight from the
    /// `.strings` files.
    static func windowWidth(titles: [String], screenWidth: CGFloat? = nil) -> CGFloat {
        let bar = tabBarWidth(titles: titles)
        // Never below the familiar 720; never wider than the display either —
        // "»" is the lesser evil next to a window that runs off screen.
        let available = (screenWidth ?? NSScreen.main?.visibleFrame.width ?? 1440) - 80
        return min(max(720, ceil(bar) + 2 * titleBarReserve), max(720, available))
    }

    static func tabBarWidth(titles: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return titles.reduce(CGFloat.zero) { total, title in
            total + ceil((title as NSString).size(withAttributes: [.font: font]).width) + tabItemPadding
        }
    }

    /// Measured on the live macOS 27 tab bar: each item is its 13pt title plus
    /// ~23pt of padding.
    static let tabItemPadding: CGFloat = 24

    /// Opening height of a tab whose content is taller, Cancel/Save bar
    /// included: ~520pt of form, so the window stays around 640pt and fits a
    /// 1280×800-class display. The schedule tab alone used to open ~900pt.
    static let defaultContentHeight: CGFloat = 580
    /// Room the centered bar needs on each side: the traffic lights end ~80pt
    /// in, plus a gap before the first tab.
    static let titleBarReserve: CGFloat = 96

    // MARK: - Basic Tab

    private var basicTab: some View {
        Form {
            Section(L10n.tr("editor.section.basic")) {
                TextField(L10n.tr("editor.name"), text: $name, prompt: Text(L10n.tr("editor.name.placeholder")))
                Toggle(L10n.tr("editor.enabled"), isOn: $isEnabled)
            }

            Section {
                // Records into a draft name, not the task's own — the Recorder
                // writes through on every keystroke, so binding it directly
                // would make this window's Cancel button a lie. `save()` is
                // what promotes the draft onto the task.
                // The library's stock Recorder, untouched. Two attempts at
                // dressing it up (overlay chrome, rewriting its placeholder
                // while recording) both killed the recording session — writing
                // `placeholderString` during active editing tears down the
                // field editor, which ends the recording and uninstalls the
                // library's event monitor. Don't poke this control's internals
                // while it's live; static copy goes in the footer below.
                KeyboardShortcuts.Recorder(
                    L10n.tr("editor.hotkey.section"),
                    name: TaskHotkeys.draft,
                    onChange: { shortcut in
                        hotkeyConflictOwner = shortcut.flatMap {
                            TaskHotkeyManager.shared.conflictOwner(for: $0, excluding: task?.id)
                        }
                    }
                )
                if let hotkeyConflictOwner {
                    Label(L10n.tr("editor.hotkey.conflict", hotkeyConflictOwner),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !isEnabled && TaskHotkeys.draft.shortcut != nil {
                    Label(L10n.tr("editor.hotkey.needs_enabled"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.tr("editor.hotkey.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .groupedFormSizing(minHeight: 237, resizable: true)
    }

    // MARK: - Schedule Tab

    private var scheduleTab: some View {
        Form {
            Section {
                Toggle(isOn: $isManualOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L10n.tr("schedule.manual_only"), systemImage: "hand.tap")
                        Text(L10n.tr("schedule.manual_only.help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.tr("schedule.trigger_section"))
            }

            if !isManualOnly {
            Section {
                Toggle(isOn: $runOnLaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L10n.tr("schedule.run_on_launch"), systemImage: "power")
                        Text(L10n.tr("schedule.run_on_launch.help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.tr("schedule.launch_section"))
            }

            if !useCron {
            Section {
                Toggle(isOn: $hasDate) {
                    Label(L10n.tr("schedule.date"), systemImage: "calendar")
                }

                if hasDate {
                    HStack {
                        Spacer()
                        DatePicker("", selection: $scheduledDate, displayedComponents: .date)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                    }
                }

                Toggle(isOn: $hasTime) {
                    Label(L10n.tr("schedule.time"), systemImage: "clock")
                }

                if hasTime {
                    if repeatType.supportsAdditionalTimes {
                        // Day-aligned repeat → render the full chip-flow with
                        // main + extras + ⊕. Editing a time never reorders.
                        ChipFlow(spacing: 12, lineSpacing: 10, alignment: .trailing) {
                            DatePicker("", selection: $scheduledDate, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.stepperField)
                                .labelsHidden()

                            ForEach(Array(additionalTimes.enumerated()), id: \.offset) { index, _ in
                                DatePicker(
                                    "",
                                    selection: Binding(
                                        get: { additionalTimes[index] },
                                        set: { additionalTimes[index] = $0 }
                                    ),
                                    displayedComponents: .hourAndMinute
                                )
                                .datePickerStyle(.stepperField)
                                .labelsHidden()
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        additionalTimes.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, Color.secondary)
                                            .imageScale(.small)
                                    }
                                    .buttonStyle(.plain)
                                    .help(L10n.tr("schedule.additional_time.remove"))
                                    .offset(x: 5, y: -5)
                                }
                            }

                            Button {
                                let anchor = additionalTimes.max() ?? scheduledDate
                                let next = Calendar.current.date(byAdding: .hour, value: 1, to: anchor) ?? anchor
                                additionalTimes.append(next)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.tr("schedule.additional_time.add"))
                        }
                        .padding(.vertical, 4)
                    } else {
                        // Repeat type doesn't support multiple times — show
                        // only the main picker, right-aligned. Any extras the
                        // user previously configured stay in state and reappear
                        // if they switch back to a supported repeat type.
                        HStack {
                            Spacer()
                            DatePicker("", selection: $scheduledDate, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                }

                TimeZonePickerRow(selection: $timeZoneID, onUserChange: timeZoneChanged)
            } header: {
                Text(L10n.tr("schedule.date_time"))
            } footer: {
                if hasTime && repeatType.supportsAdditionalTimes && !additionalTimes.isEmpty {
                    Text(L10n.tr("schedule.additional_time.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            }

            // Its own section with the trade-off spelled out: with it off, a
            // run that comes due while the Mac sleeps is skipped (issue #59).
            if useCron || repeatType != .never {
                Section {
                    Toggle(isOn: $runMissedExecution) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(L10n.tr("schedule.run_missed"), systemImage: "clock.arrow.2.circlepath")
                            Text(L10n.tr("schedule.run_missed.help"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(L10n.tr("schedule.missed_section"))
                }
            }

            Section(L10n.tr("schedule.repeat_section")) {
                Picker(selection: repeatChoice) {
                    Text(RepeatType.never.displayName).tag(RepeatChoice.repeats(.never))
                    Divider()
                    ForEach(RepeatType.allCases.filter { $0 != .never && $0 != .custom }, id: \.self) { type in
                        Text(type.displayName).tag(RepeatChoice.repeats(type))
                    }
                    Divider()
                    Text(RepeatType.custom.displayName).tag(RepeatChoice.repeats(.custom))
                    Text(L10n.tr("schedule.repeat.cron")).tag(RepeatChoice.cron)
                } label: {
                    Label(L10n.tr("schedule.repeat"), systemImage: "repeat")
                }
                .onChange(of: repeatType) { _, newValue in
                    if newValue == .custom {
                        showingCustomRepeat = true
                    }
                }

                if useCron {
                    CronEditorView(expression: $cronExpression, timeZoneID: timeZoneID)
                    TimeZonePickerRow(selection: $timeZoneID, onUserChange: timeZoneChanged)
                }

                if !useCron && repeatType == .custom {
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

                if useCron || repeatType != .never {
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

                    LabeledContent {
                        HStack(spacing: 6) {
                            TextField("", value: $jitterSeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Text(L10n.tr("schedule.jitter.unit"))
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label(L10n.tr("schedule.jitter"), systemImage: "dice")
                    }

                    if jitterSeconds > 0 {
                        Text(L10n.tr("schedule.jitter.help"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            } // end !isManualOnly
        }
        .formStyle(.grouped)
        .groupedFormSizing(minHeight: 428, resizable: true)
        // Schedule DatePickers read wall-clock values in the task's zone —
        // "09:00" with tz Asia/Shanghai means 09:00 Shanghai (issue #41).
        .environment(\.timeZone, editorTimeZone)
    }

    // MARK: - Script Content Tab

    private var scriptContentTab: some View {
        Form {
            if scriptSource != .shortcut {
                Section {
                    Toggle(L10n.tr("editor.pre_run.enable"), isOn: $preRunEnabled)
                        .onChange(of: preRunEnabled) { _, on in
                            if !on { preRunCommand = "" }
                        }
                    if preRunEnabled {
                        TextEditor(text: $preRunCommand)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 60)
                            .scrollContentBackground(.hidden)
                    }
                } header: {
                    Text(L10n.tr("editor.pre_run.section"))
                } footer: {
                    Text(L10n.tr("editor.pre_run.hint"))
                }
            }

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
                        // Typed as well as picked: pasting a path is often
                        // faster than navigating the open panel to it.
                        TextField(L10n.tr("editor.script.path_placeholder"),
                                  text: $scriptFilePath)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { scriptFilePath = Self.normalizePath(scriptFilePath) }
                        Button(L10n.tr("editor.script.choose_file")) {
                            chooseFile()
                        }
                        .pointerCursor()
                    }

                    if !scriptFilePath.isEmpty, !fileExistsAtScriptPath {
                        Label(L10n.tr("editor.script.file_missing"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if !scriptFilePath.isEmpty,
                       let content = try? String(contentsOfFile: Self.normalizePath(scriptFilePath), encoding: .utf8) {
                        ScrollView {
                            Text(content.prefix(2000) + (content.count > 2000 ? "\n..." : ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)
                    }
                case .template:
                    templatePicker
                case .shortcut:
                    shortcutPickerView
                }

                if scriptSource == .inline || scriptSource == .file {
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
                            ScriptValidationResultLabel(result: result)
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

        }
        .formStyle(.grouped)
        .groupedFormSizing(minHeight: 388, resizable: true)
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

    // MARK: - Script Settings Tab

    private var scriptSettingsTab: some View {
        Form {
            if scriptSource != .shortcut {
                Section(L10n.tr("editor.section.script")) {
                    Picker(L10n.tr("editor.shell"), selection: $shell) {
                        ForEach(AvailableShells.load(including: shell), id: \.self) { s in
                            Text(s).tag(s)
                        }
                    }

                    WorkingDirectoryField(path: $workingDirectory)
                }
            }

            Section {
                LabeledContent(L10n.tr("editor.timeout")) {
                    HStack(spacing: 6) {
                        TextField("", value: $timeoutSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        if timeoutSeconds <= 0 {
                            Text(L10n.tr("editor.timeout.unlimited"))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.tr("editor.timeout.seconds"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text(L10n.tr("editor.timeout.hint"))
            }

            Section {
                Toggle(L10n.tr("editor.ignore_exit_code"), isOn: $ignoreExitCode)
            } footer: {
                Text(L10n.tr("editor.ignore_exit_code.hint"))
            }
        }
        .formStyle(.grouped)
        .groupedFormSizing(minHeight: 337, resizable: true)
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

    // MARK: - Shortcut Picker

    @ViewBuilder
    private var shortcutPickerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoadingShortcuts {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("editor.shortcut.loading"))
                        .foregroundStyle(.secondary)
                }
            } else if let error = shortcutsLoadError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .foregroundStyle(.red)
                    Button(L10n.tr("editor.shortcut.retry")) {
                        loadShortcuts()
                    }
                    .pointerCursor()
                }
            } else if availableShortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("editor.shortcut.empty"))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button(L10n.tr("editor.shortcut.open_app")) {
                            openShortcutsApp()
                        }
                        .pointerCursor()
                        Button {
                            loadShortcuts()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help(L10n.tr("editor.shortcut.refresh"))
                        .pointerCursor()
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $shortcutName) {
                        Text(L10n.tr("editor.shortcut.placeholder")).tag("")
                        ForEach(availableShortcuts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    Button {
                        loadShortcuts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L10n.tr("editor.shortcut.refresh"))
                    .pointerCursor()
                }
                Text(L10n.tr("editor.shortcut.hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            if availableShortcuts.isEmpty && shortcutsLoadError == nil && !isLoadingShortcuts {
                loadShortcuts()
            }
        }
    }

    private enum ShortcutListResult {
        case success([String])
        case failure(String)
    }

    private func loadShortcuts() {
        isLoadingShortcuts = true
        shortcutsLoadError = nil
        Task {
            let result = await Self.fetchShortcuts()
            await MainActor.run {
                isLoadingShortcuts = false
                switch result {
                case .success(let list):
                    availableShortcuts = list
                    // If the currently selected name disappeared (renamed/deleted),
                    // leave the field in place so the user sees what was selected;
                    // the save guard already blocks empty names, and runtime will
                    // fail loudly via stderr if it no longer resolves.
                case .failure(let message):
                    shortcutsLoadError = message
                }
            }
        }
    }

    private static func fetchShortcuts() async -> ShortcutListResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShortcutListResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["list"]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: .failure(error.localizedDescription))
                    return
                }
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: .failure(L10n.tr("editor.shortcut.load_failed")))
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                // Preserve user's Shortcut order from `shortcuts list` (which is
                // already grouped/sorted by the system). Just trim, drop blanks,
                // and de-duplicate while keeping first occurrence.
                var seen = Set<String>()
                let names = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                continuation.resume(returning: .success(names))
            }
        }
    }

    private func openShortcutsApp() {
        // shortcuts:// is the documented URL scheme for Shortcuts.app on macOS 12+.
        // TaskTick min target is macOS 14, so it's always present.
        if let url = URL(string: "shortcuts://") {
            NSWorkspace.shared.open(url)
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
                // Inline hint (issue #39): the label alone doesn't tell users
                // what "Action Feedback" actually does.
                Toggle(isOn: $notifyOnAction) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("editor.notify_action"))
                        Text(L10n.tr("editor.notify_action.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Inline label so the helper text sits right under its toggle row
                // (Section footer would push it to the bottom of the whole section card,
                // visually divorcing it from the toggle that controls it).
                Toggle(isOn: $notifyOnlyWhenOutput) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("editor.notify_only_when_output"))
                        if notifyOnSuccess && notifyOnlyWhenOutput {
                            Text(L10n.tr("editor.notify_only_when_output.hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .disabled(!notifyOnSuccess)
            } header: {
                Text(L10n.tr("editor.section.notification"))
            } footer: {
                Text(L10n.tr("editor.notify_hint"))
            }

            // *What* the banner and the strong reminder say (issue #48), below
            // the section that picks *when* — the Push tab is laid out the same
            // way, so the two read as a pair. Off by default, so the wording
            // only changes when the user asks for it. Remote push has its own
            // template on its own tab (issue #55) — nothing here reaches it.
            Section {
                Toggle(isOn: $notificationTemplateEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("editor.notify_template.enable"))
                        Text(L10n.tr("editor.notify_template.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if notificationTemplateEnabled {
                    TextEditor(text: $notificationTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                }
            } header: {
                Text(L10n.tr("editor.notify_template"))
            } footer: {
                if notificationTemplateEnabled {
                    Text(L10n.tr("editor.notify_template.placeholders"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle(L10n.tr("editor.strong_reminder"), isOn: $strongReminder)
            } footer: {
                Text(L10n.tr("editor.strong_reminder_hint"))
            }
        }
        .formStyle(.grouped)
        .groupedFormSizing(minHeight: 471, resizable: true)
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

    // MARK: - Push Tab

    /// Remote push, set up on its own (issue #55): where it goes, when, and
    /// what it says. Before the split these rows shared the Notification tab,
    /// where the success/failure switches only ever reached the macOS banner.
    private var pushTab: some View {
        Form {
            Section {
                Toggle(isOn: $pushEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("editor.notify_push"))
                        Text(pushSettings.channels.isEmpty
                             ? L10n.tr("editor.notify_push.no_channel")
                             : L10n.tr("editor.notify_push.hint"))
                            .font(.caption)
                            .foregroundStyle(pushSettings.channels.isEmpty ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if pushEnabled && !pushSettings.channels.isEmpty {
                    ForEach(pushSettings.channels) { channel in
                        Toggle(isOn: channelBinding(channel.id)) {
                            HStack(spacing: 6) {
                                Image(systemName: channel.kind.symbolName)
                                    .foregroundStyle(.secondary)
                                Text(channel.displayName)
                                // A channel that's off or misconfigured in
                                // Settings can still be checked here — say so,
                                // rather than letting the user believe a run
                                // will reach it.
                                if !channel.isReadyToSend {
                                    Text(channel.isEnabled
                                         ? L10n.tr("editor.notify_push.channel_invalid")
                                         : L10n.tr("editor.notify_push.channel_off"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 18)
                    }

                    if selectedChannelIDs.isEmpty {
                        Text(L10n.tr("editor.notify_push.none_selected"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(L10n.tr("settings.push"))
            }

            Section {
                Toggle(L10n.tr("editor.push_success"), isOn: $pushOnSuccess)
                Toggle(L10n.tr("editor.push_failure"), isOn: $pushOnFailure)
                Toggle(isOn: $pushOnlyWhenOutput) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("editor.push_only_when_output"))
                        if pushEnabled && pushOnSuccess && pushOnlyWhenOutput {
                            Text(L10n.tr("editor.push_only_when_output.hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .disabled(!pushOnSuccess)
                Toggle(isOn: $pushOnlyWhenOutputChanged) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("editor.notify_push.on_output_change"))
                        if pushEnabled && pushOnlyWhenOutputChanged {
                            Text(L10n.tr("editor.notify_push.on_output_change.hint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .disabled(!pushEnabled)

            Section {
                Toggle(isOn: $pushTemplateEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("editor.push_template.enable"))
                        Text(L10n.tr("editor.push_template.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if pushTemplateEnabled {
                    TextEditor(text: $pushTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                }
            } header: {
                Text(L10n.tr("editor.push_template"))
            } footer: {
                if pushTemplateEnabled {
                    Text(L10n.tr("editor.notify_template.placeholders"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!pushEnabled)
        }
        .formStyle(.grouped)
        .groupedFormSizing(minHeight: 423, resizable: true)
    }

    /// `nil` on the task means "every channel". The editor materializes that
    /// into concrete checkmarks so what the user sees is what gets saved —
    /// leaving the sentinel in place would silently widen the task's reach the
    /// next time a channel is added in Settings.
    ///
    /// Every channel, not just the enabled ones: a channel's own switch is a
    /// separate, global gate applied at send time. Materializing to "enabled
    /// only" would quietly unpin a task from a channel the user had merely
    /// paused.
    private var selectedChannelIDs: [UUID] {
        pushChannelIDs ?? pushSettings.channels.map(\.id)
    }

    private func channelBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedChannelIDs.contains(id) },
            set: { isOn in
                var ids = selectedChannelIDs
                if isOn {
                    guard !ids.contains(id) else { return }
                    ids.append(id)
                } else {
                    ids.removeAll { $0 == id }
                }
                pushChannelIDs = ids
            }
        )
    }

    // MARK: - Script Validation

    /// The script itself, without preRunCommand glued on. They're separate languages
    /// once the script has a non-shell shebang, so validation keeps them apart.
    private var currentScriptBody: String {
        if scriptSource == .file {
            if scriptFilePath.isEmpty { return "" }
            return (try? String(contentsOfFile: Self.normalizePath(scriptFilePath), encoding: .utf8)) ?? ""
        }
        return scriptBody
    }

    /// Both halves together — used only to decide whether there's anything to validate.
    private var currentScript: String {
        let body = currentScriptBody
        let trimmedPre = preRunCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPre.isEmpty ? body : trimmedPre + "\n" + body
    }

    /// Validation lives entirely in `ScriptValidator` — this screen used to carry its
    /// own near-duplicate copy, which is how the shebang fix landed in one of the two
    /// and not the other.
    private func validateScript() {
        guard !currentScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isValidating = true
        validationResult = nil
        let body = currentScriptBody
        let pre = preRunCommand
        let selectedShell = shell

        Task.detached {
            let result = await ScriptValidator.validate(
                scriptBody: body, preRun: pre, uiShell: selectedShell
            )
            await MainActor.run {
                validationResult = result
                isValidating = false
            }
        }
    }

    // MARK: - Helpers

    /// Time zone the schedule pickers interpret their wall-clock values in.
    private var editorTimeZone: TimeZone {
        timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    private var editorCalendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = editorTimeZone
        return cal
    }

    /// Re-anchor an instant so its wall-clock reading in `new` matches what it
    /// read in `old` — switching the zone keeps "09:00" meaning 09:00.
    private func rebase(_ date: Date, from old: TimeZone, to new: TimeZone) -> Date {
        var fromCal = Calendar.current
        fromCal.timeZone = old
        var toCal = Calendar.current
        toCal.timeZone = new
        let comps = fromCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return toCal.date(from: comps) ?? date
    }

    /// User picked a different zone in the popover: keep every displayed
    /// wall-clock time put instead of letting the instants shift.
    private func timeZoneChanged(from oldID: String?, to newID: String?) {
        let old = oldID.flatMap(TimeZone.init(identifier:)) ?? .current
        let new = newID.flatMap(TimeZone.init(identifier:)) ?? .current
        guard old != new else { return }
        scheduledDate = rebase(scheduledDate, from: old, to: new)
        additionalTimes = additionalTimes.map { rebase($0, from: old, to: new) }
        endRepeatDate = rebase(endRepeatDate, from: old, to: new)
    }

    private func closeWindow() {
        // Whatever was staged and not saved dies here — otherwise its chord
        // stays claimed system-wide with nothing behind it.
        TaskHotkeyManager.shared.discardDraft()
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
        tempTask.timeZoneIdentifier = timeZoneID
        if hasTime {
            let cal = editorCalendar
            tempTask.additionalTimes = additionalTimes.map {
                cal.dateComponents([.hour, .minute], from: $0)
            }
        }
        return TaskScheduler.shared.computeNextRunDate(for: tempTask)
    }

    /// Cleans up a hand-entered path so the common paste shapes just work:
    /// `~` expansion, surrounding whitespace, the quotes a shell adds when you
    /// copy a path containing spaces, and the backslash escapes Finder's
    /// "Copy as Pathname" leaves behind.
    static func normalizePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip one matched pair of surrounding quotes.
        for quote in ["\"", "'"] where path.count >= 2
            && path.hasPrefix(quote) && path.hasSuffix(quote) {
            path = String(path.dropFirst().dropLast())
            break
        }
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        path = path.trimmingCharacters(in: .whitespaces)
        return (path as NSString).expandingTildeInPath
    }

    /// Whether the entered path resolves to a readable regular file.
    /// Drives the inline warning; `canSave` enforces the same rule.
    private var fileExistsAtScriptPath: Bool {
        let path = Self.normalizePath(scriptFilePath)
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
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
            UTType(filenameExtension: "sh") ?? .plainText,
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
        let trigger = editorState.openTrigger
        guard trigger != loadedTrigger else { return }
        loadedTrigger = trigger

        // Reset to defaults for new task
        name = ""
        isEnabled = true
        // Stage the shortcut this window is editing. A new task starts empty;
        // the `guard let task` block below loads the existing binding.
        TaskHotkeyManager.shared.discardDraft()
        hotkeyConflictOwner = nil
        isManualOnly = false
        scheduledDate = Date()
        additionalTimes = []
        hasDate = true
        hasTime = true
        repeatType = .daily
        endRepeatType = .never
        endRepeatDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        endRepeatCount = 10
        customIntervalValue = 1
        customIntervalUnit = .day
        useCron = false
        cronExpression = "*/5 * * * *"
        jitterSeconds = 0
        timeZoneID = nil
        shell = "/bin/zsh"
        scriptBody = "#!/bin/zsh\n"
        scriptSource = .inline
        scriptFilePath = ""
        preRunCommand = ""
        preRunEnabled = false
        workingDirectory = ""
        timeoutSeconds = 300
        shortcutName = ""
        availableShortcuts = []
        isLoadingShortcuts = false
        shortcutsLoadError = nil
        runMissedExecution = false
        runOnLaunch = false
        notifyOnSuccess = true
        notifyOnFailure = true
        notifyOnAction = false
        notifyOnlyWhenOutput = false
        notificationTemplateEnabled = false
        notificationTemplate = ""
        pushEnabled = false
        pushOnSuccess = true
        pushOnFailure = true
        pushOnlyWhenOutput = false
        pushOnlyWhenOutputChanged = false
        pushTemplateEnabled = false
        pushTemplate = ""
        pushChannelIDs = nil
        strongReminder = false
        ignoreExitCode = false
        selectedTab = .basic

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
        TaskHotkeys.draft.shortcut = TaskHotkeys.name(for: task.id).shortcut
        hotkeyConflictOwner = TaskHotkeys.draft.shortcut.flatMap {
            TaskHotkeyManager.shared.conflictOwner(for: $0, excluding: task.id)
        }
        shell = task.shell
        scriptBody = task.scriptBody
        preRunCommand = task.preRunCommand
        preRunEnabled = !task.preRunCommand.isEmpty
        workingDirectory = task.workingDirectory ?? ""
        timeoutSeconds = task.timeoutSeconds
        notifyOnSuccess = task.notifyOnSuccess
        notifyOnFailure = task.notifyOnFailure
        notifyOnAction = task.notifyOnAction
        notifyOnlyWhenOutput = task.notifyOnlyWhenOutput
        notificationTemplateEnabled = task.notificationTemplateEnabled
        notificationTemplate = task.notificationTemplate
        pushEnabled = task.pushEnabled
        pushOnSuccess = task.pushOnSuccess
        pushOnFailure = task.pushOnFailure
        // Falls back to the notification side on a task saved before the push
        // tab existed, so the tab opens showing what the task actually does.
        pushOnlyWhenOutput = task.pushOnlyWhenOutput
        pushOnlyWhenOutputChanged = task.pushOnlyWhenOutputChanged
        pushTemplateEnabled = task.pushTemplateEnabled
        pushTemplate = task.pushTemplate
        pushChannelIDs = task.pushChannelIDs
        strongReminder = task.strongReminder
        ignoreExitCode = task.ignoreExitCode
        repeatType = task.repeatType
        endRepeatType = task.endRepeatType
        endRepeatDate = task.endRepeatDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        endRepeatCount = task.endRepeatCount ?? 10
        customIntervalValue = task.customIntervalValue
        customIntervalUnit = task.customIntervalUnit
        runMissedExecution = task.runMissedExecution
        runOnLaunch = task.runOnLaunch
        isManualOnly = task.isManualOnly
        hasDate = task.hasDate
        hasTime = task.hasTime
        jitterSeconds = task.jitterSeconds
        timeZoneID = task.timeZoneIdentifier
        // Cron tasks (editor-created or crontab-imported) load back into cron
        // mode instead of the approximated repeatType.
        if task.schedule == .cron, let expr = task.cronExpression, !expr.isEmpty {
            useCron = true
            cronExpression = expr
        }

        if let date = task.scheduledDate {
            scheduledDate = date
        }

        // Project stored HH:mm components onto today so SwiftUI's DatePicker has
        // a real Date to bind to. Day part is discarded again at save time.
        // Uses the task-zone calendar: the pickers render in that zone, so the
        // projected instants must carry the same wall-clock reading there.
        let cal = editorCalendar
        let today = cal.startOfDay(for: Date())
        additionalTimes = task.additionalTimes.compactMap { tc in
            var c = cal.dateComponents([.year, .month, .day], from: today)
            c.hour = tc.hour
            c.minute = tc.minute
            return cal.date(from: c)
        }

        if let name = task.shortcutName, !name.isEmpty {
            scriptSource = .shortcut
            shortcutName = name
        } else if let filePath = task.scriptFilePath, !filePath.isEmpty {
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
        target.preRunCommand = preRunCommand
        target.workingDirectory = workingDirectory.isEmpty ? nil : workingDirectory
        target.timeoutSeconds = timeoutSeconds
        target.notifyOnSuccess = notifyOnSuccess
        target.notifyOnFailure = notifyOnFailure
        target.notifyOnAction = notifyOnAction
        target.notifyOnlyWhenOutput = notifyOnlyWhenOutput
        target.notificationTemplateEnabled = notificationTemplateEnabled
        target.notificationTemplate = notificationTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        target.pushEnabled = pushEnabled
        // Written unconditionally: from the first save on, the push side stops
        // following the notification side (issue #55).
        target.pushOnSuccess = pushOnSuccess
        target.pushOnFailure = pushOnFailure
        target.pushOnlyWhenOutput = pushOnlyWhenOutput
        target.pushOnlyWhenOutputChanged = pushOnlyWhenOutputChanged
        target.pushTemplateEnabled = pushTemplateEnabled
        target.pushTemplate = pushTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        // Persist the materialized selection (see `selectedChannelIDs`) so the
        // saved task means exactly what the checkboxes showed. With no channels
        // configured there are no checkboxes to be faithful to — pinning the
        // empty set there would mean the task stays silent forever once the
        // user does add one.
        target.pushChannelIDs = (pushEnabled && !pushSettings.channels.isEmpty)
            ? selectedChannelIDs
            : pushChannelIDs
        target.strongReminder = strongReminder
        target.ignoreExitCode = ignoreExitCode
        target.isEnabled = isEnabled
        target.updatedAt = Date()

        target.isManualOnly = isManualOnly
        target.hasDate = useCron ? false : hasDate
        target.hasTime = useCron ? false : hasTime
        // When both toggles are off, drop the anchor so the scheduler falls back
        // to "now" as base (TaskScheduler handles scheduledDate == nil). Cron
        // mode derives everything from the expression, so no anchor either.
        target.scheduledDate = (!useCron && (hasDate || hasTime)) ? scheduledDate : nil
        target.repeatType = repeatType

        // Persist additional times whenever the user has any entered, so
        // toggling repeat type back and forth doesn't silently discard the
        // values. The scheduler ignores them for non-day-aligned repeats —
        // the footer text tells the user this.
        if !useCron && hasTime && !additionalTimes.isEmpty {
            let cal = editorCalendar
            let mainHM = cal.dateComponents([.hour, .minute], from: scheduledDate)
            var seen = Set<Int>()
            if let h = mainHM.hour, let m = mainHM.minute {
                seen.insert(h * 60 + m)
            }
            var unique: [DateComponents] = []
            for date in additionalTimes {
                let hm = cal.dateComponents([.hour, .minute], from: date)
                guard let h = hm.hour, let m = hm.minute else { continue }
                let key = h * 60 + m
                if seen.insert(key).inserted {
                    unique.append(DateComponents(hour: h, minute: m))
                }
            }
            target.additionalTimes = unique
        } else {
            target.additionalTimes = []
        }
        target.endRepeatType = (useCron || repeatType != .never) ? endRepeatType : .never
        target.endRepeatDate = endRepeatType == .onDate ? endRepeatDate : nil
        target.endRepeatCount = endRepeatType == .afterCount ? endRepeatCount : nil
        target.customIntervalValue = customIntervalValue
        target.customIntervalUnit = customIntervalUnit
        target.runMissedExecution = runMissedExecution
        // Manual-only tasks have no automatic triggers — drop runOnLaunch even
        // if the user had toggled it before flipping to manual.
        target.runOnLaunch = isManualOnly ? false : runOnLaunch

        target.jitterSeconds = max(0, jitterSeconds)
        target.timeZoneIdentifier = timeZoneID

        // Cron mode rides the legacy schedule channel — TaskScheduler prefers
        // it whenever schedule == .cron (issue #38). Non-cron saves reset the
        // channel so switching away from cron actually leaves it.
        if useCron {
            target.schedule = .cron
            target.cronExpression = cronExpression.trimmingCharacters(in: .whitespaces)
        } else {
            target.schedule = .interval
            target.cronExpression = nil
        }
        target.intervalSeconds = nil

        switch scriptSource {
        case .shortcut:
            target.shortcutName = shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : shortcutName.trimmingCharacters(in: .whitespaces)
            target.scriptFilePath = nil
            target.scriptBody = ""
        case .file:
            target.shortcutName = nil
            // Persist the resolved path — a stored `~/…` would fail to run.
            target.scriptFilePath = Self.normalizePath(scriptFilePath)
            target.scriptBody = ""
        case .inline, .template:
            target.shortcutName = nil
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

        do {
            try modelContext.save()
        } catch {
            // Keep window open so the user can retry or copy out their edits.
            if task == nil {
                modelContext.delete(target)
            }
            presentErrorAlert(titleKey: "error.save_failed.title",
                              messageKey: "error.save_failed.message",
                              error: error)
            return
        }
        // Promote the staged shortcut now that the task is persisted and has a
        // stable id — for a new task this is the first moment that id exists.
        TaskHotkeys.name(for: target.id).shortcut = TaskHotkeys.draft.shortcut
        TaskHotkeyManager.shared.syncHandlers()

        TaskScheduler.shared.rebuildSchedule()
        EditorState.shared.lastSavedTask = target
        closeWindow()
    }
}
