import SwiftUI
import SwiftData

struct MainWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var editorState = EditorState.shared
    @State private var selectedTask: ScheduledTask?
    @Binding var showingCrontabImport: Bool

    var body: some View {
        NavigationSplitView {
            TaskListView(selectedTask: $selectedTask)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 350)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            EditorState.shared.openNew()
                            openWindow(id: "editor")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.tr("command.new_task"))
                    }
                }
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("task.select.title"), systemImage: "checklist")
                } description: {
                    Text(L10n.tr("task.select.description"))
                }
            }
        }
        .sheet(isPresented: $showingCrontabImport) {
            CrontabImportView()
        }
        .onChange(of: editorState.lastSavedTask) { _, newTask in
            if let task = newTask {
                selectedTask = task
                editorState.lastSavedTask = nil
            }
        }
    }
}
