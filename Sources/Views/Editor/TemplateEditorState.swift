import Foundation

/// Shared state for the template editor window.
@MainActor
final class TemplateEditorState: ObservableObject {
    static let shared = TemplateEditorState()

    @Published var templateToEdit: ScriptTemplate?
    @Published var isPresented = false
    @Published var lastSavedTemplate: ScriptTemplate?

    private init() {}

    func openNew() {
        templateToEdit = nil
        isPresented = true
    }

    func openEdit(_ template: ScriptTemplate) {
        templateToEdit = template
        isPresented = true
    }

    func close() {
        isPresented = false
        templateToEdit = nil
    }
}
