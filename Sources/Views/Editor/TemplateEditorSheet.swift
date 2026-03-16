import SwiftUI
import UniformTypeIdentifiers

/// Template editor view, shown as a Window (not a sheet) to get proper TabView chrome.
struct TemplateEditorSheet: View {
    @ObservedObject private var editorState = TemplateEditorState.shared
    @ObservedObject private var store = ScriptTemplateStore.shared

    private var template: ScriptTemplate? { editorState.templateToEdit }

    @State private var selectedTab = 0
    @State private var name = ""
    @State private var category = ""
    @State private var notes = ""
    @State private var shell = "/bin/zsh"
    @State private var scriptBody = ""
    @State private var workingDirectory = ""
    @State private var isCreatingCategory = false
    @State private var newCategoryName = ""
    @State private var loaded = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            basicTab
                .tabItem { Label(L10n.tr("editor.tab.basic"), systemImage: "square.and.pencil") }
                .tag(0)

            scriptTab
                .tabItem { Label(L10n.tr("editor.tab.script"), systemImage: "terminal") }
                .tag(1)
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
        .onAppear { loadTemplate() }
        .onChange(of: editorState.templateToEdit?.id) { _, _ in
            loadTemplate()
        }
    }

    // MARK: - Basic Tab

    private var basicTab: some View {
        Form {
            Section(L10n.tr("editor.section.basic")) {
                TextField(L10n.tr("editor.name"), text: $name, prompt: Text(L10n.tr("template.save.name_placeholder")))

                HStack {
                    Picker(L10n.tr("template.category"), selection: $category) {
                        Text(L10n.tr("template.category.none")).tag("")
                        if !store.allCategories.isEmpty {
                            Divider()
                            ForEach(store.allCategories, id: \.self) { cat in
                                Text(cat).tag(cat)
                            }
                        }
                    }
                    .disabled(isCreatingCategory)

                    Button {
                        isCreatingCategory.toggle()
                        if isCreatingCategory { category = "" }
                    } label: {
                        Image(systemName: isCreatingCategory ? "xmark.circle.fill" : "plus.circle.fill")
                            .foregroundStyle(isCreatingCategory ? .secondary : Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                }

                if isCreatingCategory {
                    TextField(L10n.tr("template.category.new_placeholder"), text: $newCategoryName)
                }

            }

            Section(L10n.tr("template.notes")) {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    // MARK: - Script Tab

    private var scriptTab: some View {
        Form {
            Section {
                ScriptEditorView(scriptBody: $scriptBody)

                ScriptValidationRow(script: scriptBody, shell: shell)
            } header: {
                HStack {
                    Text(L10n.tr("task.detail.script"))
                    Spacer()
                    Button(L10n.tr("template.import_file")) {
                        importFile()
                    }
                    .font(.caption)
                    .pointerCursor()
                }
            } footer: {
                Text(L10n.tr("template.script_hint"))
            }

            Section(L10n.tr("editor.section.script")) {
                Picker(L10n.tr("editor.shell"), selection: $shell) {
                    Text("/bin/zsh").tag("/bin/zsh")
                    Text("/bin/bash").tag("/bin/bash")
                    Text("/bin/sh").tag("/bin/sh")
                }

                WorkingDirectoryField(path: $workingDirectory)
            }
        }
        .formStyle(.grouped)
        .onChange(of: shell) { _, newShell in
            let newShebang = "#!\(newShell)"
            if scriptBody.hasPrefix("#!") {
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

    // MARK: - Helpers

    private func loadTemplate() {
        guard !loaded else { return }
        loaded = true

        // Reset defaults
        name = ""
        category = ""
        notes = ""
        shell = "/bin/zsh"
        scriptBody = ""
        workingDirectory = ""
        selectedTab = 0
        isCreatingCategory = false
        newCategoryName = ""

        guard let t = template else { return }
        name = t.name
        category = t.category
        notes = t.notes
        shell = t.shell
        scriptBody = t.scriptBody
        workingDirectory = t.workingDirectory
    }

    private func save() {
        let cat = isCreatingCategory ? newCategoryName.trimmingCharacters(in: .whitespaces) : category
        let result = ScriptTemplate(
            id: template?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            category: cat,
            notes: notes,
            scriptBody: scriptBody,
            shell: shell,
            workingDirectory: workingDirectory,
            isBuiltIn: false,
            createdAt: template?.createdAt ?? Date()
        )

        if template != nil {
            store.update(result, name: result.name, category: result.category, notes: result.notes, scriptBody: result.scriptBody, shell: result.shell, workingDirectory: result.workingDirectory)
        } else {
            store.save(result)
        }

        editorState.lastSavedTemplate = result
        closeWindow()
    }

    private func closeWindow() {
        loaded = false
        editorState.close()
        let titleNew = L10n.tr("template.add")
        let titleEdit = L10n.tr("template.edit.title")
        for window in NSApp.windows where window.identifier?.rawValue == "template-editor" || window.title == titleNew || window.title == titleEdit {
            window.close()
            return
        }
        NSApp.keyWindow?.close()
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .shellScript, .pythonScript, .plainText, .sourceCode,
            UTType(filenameExtension: "sh")!,
            UTType(filenameExtension: "zsh") ?? .plainText,
        ]
        panel.message = L10n.tr("editor.script.choose_file")

        if panel.runModal() == .OK, let url = panel.url {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                scriptBody = content
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = url.deletingPathExtension().lastPathComponent
                }
            }
        }
    }
}
