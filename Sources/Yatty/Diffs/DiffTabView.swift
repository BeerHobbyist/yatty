import SwiftUI
import WebKit

/// Yatty's diff viewer, in a tab of the worktree: unified or side by side,
/// read again on demand (or when the same diff is asked for again). ⌘W
/// closes it like any tab.
struct DiffTabView: View {
  let worktree: Worktree
  let tab: TerminalTab
  let diffTab: DiffTab
  @Environment(AppStore.self) private var store
  @State private var diff: String?
  /// Each file's path in `diff`'s order.
  @State private var files: [String] = []
  @State private var error: String?
  @State private var loading = false
  @State private var copied = false
  @State private var confirmingClear = false
  /// Past this the page would choke: a terminal viewer copes better.
  private static let largest = 20_000_000

  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Octicon(.fileDiff, size: 12).foregroundStyle(.secondary)
        Text(diffTab.target.title).font(.callout.weight(.medium))
        Spacer()
        comments
        Picker("Layout", selection: $store.diffLayout) {
          Text("Unified").tag(DiffLayout.unified)
          Text("Side by Side").tag(DiffLayout.split)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Button {
          Task { await load() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Read the diff again")
        .disabled(loading)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      Divider()
      content
    }
    // Again whenever this diff is asked for again.
    .task(id: store.diffReads[tab.id, default: 0]) { await load() }
  }

  @ViewBuilder private var content: some View {
    if let error {
      ContentUnavailableView(
        "Couldn't Read the Diff", systemImage: "exclamationmark.triangle", description: Text(error))
    } else if let diff {
      if diff.utf8.count > Self.largest {
        ContentUnavailableView(
          "Too Large to Show", systemImage: "doc.text.magnifyingglass",
          description: Text(
            "\(diff.utf8.count / 1_000_000) MB of changes. Open Diff… (⌥⌘D) can show it in a terminal viewer."))
      } else if diff.isEmpty {
        ContentUnavailableView(
          "No Changes", systemImage: "checkmark.circle",
          description: Text("\(diffTab.target.title) in \(store.label(for: worktree)): nothing differs."))
      } else {
        DiffWebView(diff: diff, layout: store.diffLayout, files: files, comments: diffTab.comments) { message in
          switch message {
          case .save(let comment): store.saveDiffComment(comment, tab: tab.id, in: worktree)
          case .delete(let id): store.deleteDiffComment(id, tab: tab.id, in: worktree)
          }
        }
      }
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// The comments left on this diff, and the way to hand them to the agent.
  @ViewBuilder private var comments: some View {
    let count = diffTab.comments.count
    if count == 0 {
      Text("Click a line number to comment").font(.caption).foregroundStyle(.secondary)
    } else {
      Text("\(count) comment\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
      Button(copied ? "Copied" : "Copy Prompt") { copyPrompt() }
        .help("Your comments as a prompt for your agent: your own review, not GitHub's")
        .disabled(copied)
      Button("Clear") { confirmingClear = true }
        .buttonStyle(.borderless)
        .confirmationDialog("Delete the \(count) comment\(count == 1 ? "" : "s") on this diff?", isPresented: $confirmingClear) {
          Button("Delete Comments", role: .destructive) { store.clearDiffComments(tab: tab.id, in: worktree) }
        }
    }
  }

  private func copyPrompt() {
    let prompt = LocalReviewPrompt.make(target: diffTab.target, branch: worktree.branch, comments: diffTab.comments)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    do {
      let text = try await GitDiff.text(in: worktree.path, target: diffTab.target)
      files = UnifiedDiff.files(text)
      diff = text
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// diff2html in a web view, from the `diff/` folder the app bundles.
struct DiffWebView: NSViewRepresentable {
  /// What the page asks of the app.
  enum Message {
    case save(DiffComment)
    case delete(String)
  }

  let diff: String
  let layout: DiffLayout
  /// Each file's path in the diff's order, for the page's comments.
  let files: [String]
  let comments: [DiffComment]
  let onMessage: (Message) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(MessageRelay(context.coordinator), name: "yatty")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    if let page = DiffAssets.viewer {
      view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    } else {
      view.loadHTMLString(
        "<p style=\"font: 13px -apple-system; padding: 20px\">The diff viewer's files are missing from Yatty.app.</p>",
        baseURL: nil)
    }
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.onMessage = onMessage
    context.coordinator.show(diff, layout: layout, files: files, comments: comments, in: view)
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.configuration.userContentController.removeScriptMessageHandler(forName: "yatty")
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var onMessage: (Message) -> Void = { _ in }
    private var loaded = false
    private var wanted: (diff: String, layout: DiffLayout, files: [String], comments: [DiffComment])?
    private var shown: (diff: String, layout: DiffLayout)?
    private var shownComments: [DiffComment]?

    func show(_ diff: String, layout: DiffLayout, files: [String], comments: [DiffComment], in view: WKWebView) {
      wanted = (diff, layout, files, comments)
      render(in: view)
    }

    /// Draws what's wanted once the page is there, and only when it changed;
    /// comments alone are put in place without drawing the diff again.
    private func render(in view: WKWebView) {
      guard loaded, let wanted else { return }
      if shown?.diff == wanted.diff, shown?.layout == wanted.layout {
        guard shownComments != wanted.comments else { return }
        shownComments = wanted.comments
        view.callAsyncJavaScript(
          "yattySetComments(comments)", arguments: ["comments": wanted.comments.map(Self.page)], in: nil, in: .page)
        return
      }
      shown = (wanted.diff, wanted.layout)
      shownComments = wanted.comments
      view.callAsyncJavaScript(
        "return yattyRender(diff, layout, files, comments)",
        arguments: [
          "diff": wanted.diff, "layout": wanted.layout.rawValue, "files": wanted.files,
          "comments": wanted.comments.map(Self.page),
        ],
        in: nil, in: .page
      ) { result in
        MainActor.assumeIsolated {
          switch result {
          case .success(let files): Snapshot.note("diff drawn: \(files) file(s)")
          case .failure(let error): Snapshot.note("diff not drawn: \(error)")
          }
          if Snapshot.isActive { Snapshot.saveWebView(view) }
        }
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded = true
      render(in: webView)
    }

    /// A comment as the page has it.
    private static func page(_ comment: DiffComment) -> [String: Any] {
      [
        "id": comment.id, "path": comment.path, "line": comment.line, "side": comment.side.rawValue,
        "code": comment.code, "text": comment.text,
      ]
    }

    /// The page saved or deleted a comment.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
      switch type {
      case "save":
        guard let path = body["path"] as? String, let line = (body["line"] as? NSNumber)?.intValue,
          let side = (body["side"] as? String).flatMap(DiffComment.Side.init(rawValue:)),
          let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        let id = (body["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        onMessage(.save(DiffComment(id: id, path: path, line: line, side: side, code: body["code"] as? String ?? "", text: text)))
      case "delete":
        if let id = body["id"] as? String { onMessage(.delete(id)) }
      default:
        break
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      Snapshot.note("diff page failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      Snapshot.note("diff page failed to load: \(error)")
    }

    /// The page's process died (memory, a crash): load it again and redraw.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      Snapshot.note("diff page's process ended")
      loaded = false
      shown = nil
      shownComments = nil
      webView.reload()
    }

    /// Links (none expected in a diff) open in the browser, never in here.
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url, !url.isFileURL, url.scheme != "about" else {
        decisionHandler(.allow)
        return
      }
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
    }
  }
}

/// Hands the page's messages to the coordinator without the content
/// controller keeping it (and its web view) alive.
@MainActor
private final class MessageRelay: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(controller, didReceive: message)
  }
}

enum DiffAssets {
  /// `Contents/Resources/diff/viewer.html` in the app, else the repository's
  /// copy (a run from the build folder has no bundle).
  static var viewer: URL? {
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("diff/viewer.html"),
      FileManager.default.fileExists(atPath: bundled.path)
    {
      return bundled
    }
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/diff/viewer.html")
    return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
  }
}
