import Foundation

/// Shared state for the task editor window.
@MainActor
final class EditorState: ObservableObject {
    static let shared = EditorState()

    @Published var taskToEdit: ScheduledTask?
    @Published var isPresented = false
    @Published var lastSavedTask: ScheduledTask?
    @Published var pendingTemplate: ScriptTemplate?

    private init() {}

    func openNew() {
        taskToEdit = nil
        pendingTemplate = nil
        isPresented = true
    }

    func openNewFromTemplate(_ template: ScriptTemplate) {
        taskToEdit = nil
        pendingTemplate = template
        isPresented = true
    }

    func openEdit(_ task: ScheduledTask) {
        taskToEdit = task
        pendingTemplate = nil
        isPresented = true
    }

    func close() {
        isPresented = false
        taskToEdit = nil
        pendingTemplate = nil
    }
}
