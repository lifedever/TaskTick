import SwiftUI
import WebKit

// MARK: - Markdown WebView

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 13px;
                line-height: 1.6;
                color: #e4e4ec;
                padding: 16px;
                -webkit-font-smoothing: antialiased;
            }
            @media (prefers-color-scheme: light) {
                body { color: #1a1a2e; }
                code { background: rgba(0,0,0,.06); }
                pre { background: rgba(0,0,0,.04); }
                blockquote { border-color: rgba(0,0,0,.15); color: #555; }
                table th { background: rgba(0,0,0,.04); }
                table td, table th { border-color: rgba(0,0,0,.1); }
                hr { border-color: rgba(0,0,0,.1); }
            }
            h1 { font-size: 1.5em; margin: 0.6em 0 0.4em; }
            h2 { font-size: 1.3em; margin: 0.6em 0 0.4em; }
            h3 { font-size: 1.1em; margin: 0.5em 0 0.3em; }
            p { margin: 0.4em 0; }
            ul, ol { margin: 0.4em 0; padding-left: 1.5em; }
            li { margin: 0.2em 0; }
            code {
                font-family: 'SF Mono', Menlo, monospace;
                font-size: 0.9em;
                background: rgba(255,255,255,.08);
                padding: 1px 5px;
                border-radius: 3px;
            }
            pre {
                background: rgba(255,255,255,.05);
                padding: 10px;
                border-radius: 6px;
                overflow-x: auto;
                margin: 0.5em 0;
            }
            pre code { background: none; padding: 0; }
            blockquote {
                border-left: 3px solid rgba(255,255,255,.2);
                padding-left: 12px;
                margin: 0.5em 0;
                color: #8888a0;
            }
            table { border-collapse: collapse; margin: 0.5em 0; width: 100%; }
            th, td {
                border: 1px solid rgba(255,255,255,.1);
                padding: 6px 10px;
                text-align: left;
            }
            th { background: rgba(255,255,255,.05); font-weight: 600; }
            strong { font-weight: 600; }
            hr { border: none; border-top: 1px solid rgba(255,255,255,.1); margin: 0.8em 0; }
            a { color: #6c8aff; }
        </style>
        </head>
        <body>\(markdownToHTML(markdown))</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func markdownToHTML(_ md: String) -> String {
        var html = md
        // Escape HTML entities first
        html = html.replacingOccurrences(of: "&", with: "&amp;")
        html = html.replacingOccurrences(of: "<", with: "&lt;")
        html = html.replacingOccurrences(of: ">", with: "&gt;")

        // Restore blockquotes (> at line start)
        html = html.replacingOccurrences(of: "(?m)^&gt; (.*)$", with: "<blockquote>$1</blockquote>", options: .regularExpression)

        // Code blocks (```)
        html = html.replacingOccurrences(of: "(?s)```\\w*\\n(.*?)```", with: "<pre><code>$1</code></pre>", options: .regularExpression)

        // Inline code
        html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)

        // Headings
        html = html.replacingOccurrences(of: "(?m)^### (.+)$", with: "<h3>$1</h3>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^## (.+)$", with: "<h2>$1</h2>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^# (.+)$", with: "<h1>$1</h1>", options: .regularExpression)

        // Bold & italic
        html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)

        // Links
        html = html.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)

        // Horizontal rule
        html = html.replacingOccurrences(of: "(?m)^---+$", with: "<hr>", options: .regularExpression)

        // Unordered lists
        html = html.replacingOccurrences(of: "(?m)^- (.+)$", with: "<li>$1</li>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(<li>.*</li>\n?)+", with: "<ul>$0</ul>", options: .regularExpression)

        // Tables
        let tablePattern = "(?m)(\\|.+\\|\\n)(\\|[-| :]+\\|\\n)((?:\\|.+\\|\\n?)+)"
        if let regex = try? NSRegularExpression(pattern: tablePattern) {
            let nsHtml = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
            for match in matches.reversed() {
                let fullRange = match.range
                let tableStr = nsHtml.substring(with: fullRange)
                let rows = tableStr.components(separatedBy: "\n").filter { !$0.isEmpty }
                var tableHTML = "<table>"
                for (i, row) in rows.enumerated() {
                    if i == 1 { continue } // skip separator row
                    let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let tag = i == 0 ? "th" : "td"
                    tableHTML += "<tr>" + cells.map { "<\(tag)>\($0)</\(tag)>" }.joined() + "</tr>"
                }
                tableHTML += "</table>"
                html = (html as NSString).replacingCharacters(in: fullRange, with: tableHTML)
            }
        }

        // Paragraphs - wrap remaining lines
        html = html.replacingOccurrences(of: "(?m)^(?!<[hupbolt]|</?[hupbolt])(.+)$", with: "<p>$1</p>", options: .regularExpression)

        return html
    }
}

struct UpdateDialogView: View {
    @ObservedObject var updater: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if updater.isDownloading || updater.downloadComplete {
                downloadView
            } else {
                availableView
            }
        }
    }

    // MARK: - Update Available

    private var availableView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                // App icon
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("update.available.title"))
                        .font(.headline)
                    Text(L10n.tr("update.available.message", updater.latestVersion ?? "", updater.currentVersion))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            // Release notes
            if let notes = updater.releaseNotes, !notes.isEmpty {
                MarkdownWebView(markdown: notes)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                    .padding(.horizontal, 20)
            }

            Divider()
                .padding(.top, 16)

            // Actions
            HStack {
                Button(L10n.tr("update.skip")) {
                    if let version = updater.latestVersion {
                        updater.skipVersion(version)
                    }
                    dismiss()
                }
                .pointerCursor()

                Spacer()

                Button(L10n.tr("update.remind_later")) {
                    dismiss()
                }
                .pointerCursor()

                Button(L10n.tr("update.install")) {
                    updater.downloadUpdate()
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
    }

    // MARK: - Download Progress

    private var downloadView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(updater.downloadComplete ? L10n.tr("update.ready") : L10n.tr("update.downloading"))
                        .font(.headline)

                    ProgressView(value: updater.downloadProgress)
                        .progressViewStyle(.linear)

                    if !updater.downloadComplete && updater.totalBytes > 0 {
                        Text("\(formatBytes(updater.downloadedBytes)) / \(formatBytes(updater.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            // Actions
            HStack {
                Spacer()
                if updater.downloadComplete {
                    Button(L10n.tr("update.install_restart")) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            updater.installAndRestart()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                } else {
                    Button(L10n.tr("update.cancel")) {
                        updater.cancelDownload()
                        dismiss()
                    }
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
