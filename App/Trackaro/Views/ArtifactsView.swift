import AppKit
import PDFKit
import SwiftUI
import TrackaroCore
import TrackaroKit
import WebKit

/// Files agents saved to projects: a list on the left, the open one on the right.
struct ArtifactsPage: View {
    @Environment(AppModel.self) private var model
    let projectId: String?
    @State private var query = ""

    private var shown: [ArtifactSummary] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return model.artifacts }
        return model.artifacts.filter { $0.name.localizedCaseInsensitiveContains(wanted) || $0.summary.localizedCaseInsensitiveContains(wanted) }
    }

    var body: some View {
        @Bindable var model = model
        if model.artifacts.isEmpty {
            ContentUnavailableView {
                Label("No artifacts yet", systemImage: "doc.richtext")
            } description: {
                Text(SidebarItem.artifacts(projectId).emptyMessage)
            }
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    TextField("Filter artifacts", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    List(selection: $model.artifactSelection) {
                        if projectId == nil {
                            ForEach(grouped, id: \.project) { group in
                                Section(group.project) {
                                    ForEach(group.artifacts) { ArtifactRow(artifact: $0).tag($0.id) }
                                }
                            }
                        } else {
                            ForEach(shown) { ArtifactRow(artifact: $0).tag($0.id) }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)

                Group {
                    if let artifact = model.openArtifact {
                        ArtifactViewer(artifact: artifact).id(artifact.summary.id)
                    } else {
                        ContentUnavailableView("Select an artifact", systemImage: "doc.richtext")
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var grouped: [(project: String, artifacts: [ArtifactSummary])] {
        let byProject = Dictionary(grouping: shown) { model.snapshot?.projectsById[$0.projectId]?.name ?? "Project" }
        return byProject.keys.sorted().map { ($0, byProject[$0] ?? []) }
    }
}

extension ArtifactKind {
    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .html: "globe"
        case .text: "doc.plaintext"
        case .image: "photo"
        case .pdf: "doc.text"
        case .file: "doc"
        }
    }
}

private struct ArtifactRow: View {
    let artifact: ArtifactSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: artifact.kind.symbol).foregroundStyle(Color.accentTheme).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.name).lineLimit(1)
                Text(artifact.summary.isEmpty ? RelativeTime.string(artifact.updatedAt) : artifact.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ArtifactViewer: View {
    @Environment(AppModel.self) private var model
    let artifact: Artifact
    @State private var showingSource = false
    @State private var confirmingDelete = false

    private var summary: ArtifactSummary { artifact.summary }

    /// Above this, formatted Markdown would make the window sluggish, so it shows as text.
    private static let largestFormatted = 512 * 1024

    private var canFormat: Bool {
        summary.kind == .html || (summary.kind == .markdown && summary.byteCount <= Self.largestFormatted)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete \(summary.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteArtifact(summary) }
        } message: {
            Text("It disappears from this project. A backup made before now still has it.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name).font(.headline).lineLimit(1).textSelection(.enabled)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if canFormat {
                Picker("Show", selection: $showingSource) {
                    Text(summary.kind == .html ? "Page" : "Formatted").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let text = artifact.text {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    model.showToast("Copied \(summary.name)")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy the text")
            }
            if summary.kind != .file {
                Button {
                    model.openArtifactExternally(artifact)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open in the default app")
            }
            Button {
                model.saveArtifactToChosenFile(artifact)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save a copy")
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
        }
        .padding(12)
    }

    private var details: String {
        let author = model.snapshot?.membersById[summary.updaterId]?.name ?? "Unknown"
        let size = ByteCountFormatter.string(fromByteCount: Int64(summary.byteCount), countStyle: .file)
        let project = model.snapshot?.projectsById[summary.projectId]?.name ?? "Project"
        return "\(project) · \(author) · \(RelativeTime.string(summary.updatedAt)) · v\(summary.version) · \(size)"
    }

    @ViewBuilder private var content: some View {
        switch summary.kind {
        case .markdown:
            if let text = artifact.text, canFormat, !showingSource {
                ScrollView {
                    MarkdownView(source: text).padding(18).frame(maxWidth: 820, alignment: .leading)
                }
            } else {
                PlainTextViewer(text: artifact.text ?? "")
            }
        case .html:
            if let text = artifact.text, !showingSource {
                SafeHTMLView(html: text)
            } else {
                PlainTextViewer(text: artifact.text ?? "")
            }
        case .text:
            PlainTextViewer(text: artifact.text ?? "This file is not valid UTF-8 text. Save a copy to open it elsewhere.")
        case .image:
            if let image = NSImage(data: artifact.content) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1200).padding(14)
                }
            } else {
                unavailable("This image could not be read.")
            }
        case .pdf:
            if let document = PDFDocument(data: artifact.content) {
                PDFViewer(document: document)
            } else {
                unavailable("This PDF could not be read.")
            }
        case .file:
            unavailable("Trackaro cannot show this kind of file. Save a copy to use it.")
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label(summary.name, systemImage: summary.kind.symbol)
        } description: {
            Text(message)
        } actions: {
            Button("Save a Copy…") { model.saveArtifactToChosenFile(artifact) }
        }
    }
}

/// Monospaced, selectable and fast for long files, which a SwiftUI `Text` is not.
private struct PlainTextViewer: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.string = text
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

private struct PDFViewer: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// Shows a page an agent wrote, with its scripts off and nothing loaded from the network, so viewing one cannot run
/// code or tell anyone it was opened. A clicked web link opens in the browser instead. If the blocking rules cannot
/// be set up, the page is not shown.
private struct SafeHTMLView: NSViewRepresentable {
    let html: String

    private static let blockEverythingRemote = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]
        """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "trackaro-artifact-offline", encodedContentRuleList: Self.blockEverythingRemote
        ) { rules, _ in
            guard let rules else {
                view.loadHTMLString("<p>This page cannot be shown safely. Use Source to read it.</p>", baseURL: nil)
                return
            }
            view.configuration.userContentController.add(rules)
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true && action.request.url?.scheme != "about" else {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
