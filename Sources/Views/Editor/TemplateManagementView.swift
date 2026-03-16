import SwiftUI

struct TemplateManagementView: View {
    @ObservedObject private var store = ScriptTemplateStore.shared
    @ObservedObject private var templateEditorState = TemplateEditorState.shared
    @Environment(\.openWindow) private var openWindow
    @State private var renamingTemplate: ScriptTemplate?
    @State private var renameText = ""
    @State private var templateToDelete: ScriptTemplate?
    @State private var selectedTemplate: ScriptTemplate?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            templateEditorState.openNew()
                            openWindow(id: "template-editor")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.tr("template.add"))
                    }
                }
        } detail: {
            if let template = selectedTemplate {
                templateDetail(template)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("template.manage.empty"), systemImage: "doc.text")
                } description: {
                    Text(L10n.tr("template.manage.select_hint"))
                }
            }
        }
        .sheet(item: $renamingTemplate) { template in
            renameSheet(template)
        }
        .onChange(of: templateEditorState.lastSavedTemplate) { _, newTemplate in
            if let t = newTemplate {
                selectedTemplate = t
                templateEditorState.lastSavedTemplate = nil
            }
        }
        .alert(L10n.tr("template.manage.delete_confirm"), isPresented: Binding(
            get: { templateToDelete != nil },
            set: { if !$0 { templateToDelete = nil } }
        )) {
            Button(L10n.tr("editor.cancel"), role: .cancel) {
                templateToDelete = nil
            }
            Button(L10n.tr("delete.confirm"), role: .destructive) {
                if let template = templateToDelete {
                    if selectedTemplate?.id == template.id {
                        selectedTemplate = nil
                    }
                    store.delete(template)
                }
                templateToDelete = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedTemplate) {
            ForEach(store.groupedTemplates, id: \.category) { group in
                Section(group.category.isEmpty ? L10n.tr("template.category.none") : group.category) {
                    ForEach(group.templates) { template in
                        templateRow(template, isBuiltIn: false)
                            .tag(template)
                    }
                }
            }

        }
        .listStyle(.sidebar)
    }

    private func templateRow(_ template: ScriptTemplate, isBuiltIn: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(template.name)
                .lineLimit(1)
        }
        .contextMenu {
            Button(L10n.tr("task.detail.edit")) {
                templateEditorState.openEdit(template)
                openWindow(id: "template-editor")
            }
            Button(L10n.tr("template.manage.rename")) {
                renameText = template.name
                renamingTemplate = template
            }
            Divider()
            Button(L10n.tr("template.manage.delete"), role: .destructive) {
                templateToDelete = template
            }
        }
    }

    // MARK: - Detail

    private func templateDetail(_ template: ScriptTemplate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection(template)
                Divider()
                    .padding(.horizontal)

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        scriptCard(template)
                        if !template.notes.isEmpty {
                            notesCard(template)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    infoCard(template)
                        .frame(width: 240, alignment: .top)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func headerSection(_ template: ScriptTemplate) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.teal.gradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "terminal")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.system(size: 10))
                            Text(template.shell)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                        if !template.category.isEmpty {
                            Text(template.category)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                                .foregroundStyle(Color.accentColor)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button(L10n.tr("template.create_task")) {
                                EditorState.shared.openNewFromTemplate(template)
                                openWindow(id: "editor")
                            }
                            .buttonStyle(.borderedProminent)
                            .pointerCursor()

                            Button(L10n.tr("task.detail.edit")) {
                                templateEditorState.openEdit(template)
                                openWindow(id: "template-editor")
                            }
                            .pointerCursor()

                            Button(L10n.tr("template.manage.rename")) {
                                renameText = template.name
                                renamingTemplate = template
                            }
                            .pointerCursor()

                            Button(role: .destructive) {
                                templateToDelete = template
                            } label: {
                                Label(L10n.tr("template.manage.delete"), systemImage: "trash")
                            }
                            .pointerCursor()
                        }
                        .controlSize(.regular)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func scriptCard(_ template: ScriptTemplate) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("task.detail.script"), systemImage: "terminal")
                    .font(.headline)

                Text(template.scriptBody)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.black.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 0.5)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notesCard(_ template: ScriptTemplate) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("template.notes"), systemImage: "note.text")
                    .font(.headline)

                Text(template.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoCard(_ template: ScriptTemplate) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("template.info"), systemImage: "info.circle")
                    .font(.headline)

                VStack(spacing: 8) {
                    if !template.category.isEmpty {
                        detailRow(L10n.tr("template.category"), value: template.category)
                    }
                    detailRow(L10n.tr("task.detail.shell"), value: template.shell)
                    if !template.workingDirectory.isEmpty {
                        detailRow(L10n.tr("task.detail.working_dir"), value: template.workingDirectory)
                    }
                    detailRow(L10n.tr("template.created_at"), value: template.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if template.updatedAt != template.createdAt {
                        detailRow(L10n.tr("template.updated_at"), value: template.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }

    // MARK: - Rename Sheet

    private func renameSheet(_ template: ScriptTemplate) -> some View {
        VStack(spacing: 16) {
            Text(L10n.tr("template.manage.rename"))
                .font(.headline)
            TextField(L10n.tr("template.save.name_placeholder"), text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(L10n.tr("editor.cancel")) {
                    renamingTemplate = nil
                }
                .keyboardShortcut(.cancelAction)
                .pointerCursor()
                Button(L10n.tr("editor.save")) {
                    store.rename(template, to: renameText)
                    renamingTemplate = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor()
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
