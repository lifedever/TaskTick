import SwiftUI

/// Helper to open the template editor window pre-filled with script content from the task editor.
enum SaveTemplateView {
    @MainActor
    static func open(scriptBody: String, shell: String, workingDirectory: String, openWindow: OpenWindowAction) {
        let template = ScriptTemplate(
            name: "",
            scriptBody: scriptBody,
            shell: shell,
            workingDirectory: workingDirectory
        )
        TemplateEditorState.shared.templateToEdit = template
        TemplateEditorState.shared.isPresented = true
        openWindow(id: "template-editor")
    }
}
