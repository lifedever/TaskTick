import SwiftUI

/// A text field with a folder-chooser button for selecting a working directory.
struct WorkingDirectoryField: View {
    @Binding var path: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(L10n.tr("editor.working_dir"), text: $path, prompt: Text(L10n.tr("editor.working_dir.placeholder")))

            Button {
                chooseDirectory()
            } label: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .pointerCursor()
            .help(L10n.tr("editor.working_dir.choose"))
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = L10n.tr("editor.working_dir.choose")

        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path(percentEncoded: false)
        }
    }
}
