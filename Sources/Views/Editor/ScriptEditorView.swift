import SwiftUI
import AppKit

struct ScriptEditorView: View {
    @Binding var scriptBody: String
    @State private var showExpandedEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CodeTextEditor(text: $scriptBody)
                    .frame(minHeight: 140, maxHeight: 280)

                Button {
                    showExpandedEditor = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(8)
                .pointerCursor()
                .help(L10n.tr("editor.script.expand"))
            }

            Text(L10n.tr("editor.script.placeholder"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .sheet(isPresented: $showExpandedEditor) {
            ExpandedScriptEditor(scriptBody: $scriptBody)
        }
    }
}

// MARK: - Expanded Editor

struct ExpandedScriptEditor: View {
    @Binding var scriptBody: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("editor.section.script"))
                    .font(.headline)
                Spacer()
                Button(L10n.tr("editor.script.collapse")) {
                    dismiss()
                }
                .pointerCursor()
            }
            .padding()

            Divider()

            CodeTextEditor(text: $scriptBody)
                .padding(8)
        }
        .frame(width: 680, height: 480)
    }
}

// MARK: - NSTextView Wrapper

struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = TabSupportingTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView

        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

// MARK: - Tab Supporting TextView

class TabSupportingTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        // Auto-indent: match previous line's leading whitespace
        let currentLine = getCurrentLineContent()
        let indent = currentLine.prefix(while: { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(String(indent), replacementRange: selectedRange())
        }
    }

    private func getCurrentLineContent() -> String {
        guard let textStorage = textStorage else { return "" }
        let text = textStorage.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        return text.substring(with: lineRange)
    }
}
