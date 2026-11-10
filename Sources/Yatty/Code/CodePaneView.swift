import SwiftUI
import WebKit

/// The code beside a tab's terminals, as in Cursor: the file the agent is
/// changing, its changes marked in place, comments for the agent, and ways
/// to look around (⌘-click a name, ⌘P, the path bar).
struct CodePaneView: View {
  let worktree: Worktree
  let tab: TerminalTab
  let code: CodeView
  @Environment(AppStore.self) private var store
  @State private var loaded: CodeShown?
  @State private var error: String?
  @State private var loads = 0
  /// Where to scroll once the next read is drawn.
  @State private var scroll = CodeScroll.change
  /// A file that changed while the view wasn't following.
  @State private var changedElsewhere: String?
  @State private var changes: [CodeChange] = []
  @State private var baseName: String?
  @State private var showingFiles = false
  @State private var sending = false
  @State private var copied = false
  /// Shown again with the page as it was left: stay where the reader was,
  /// unless the file changed meanwhile.
  @State private var keepPlace = true

  var body: some View {
    VStack(spacing: 0) {
      bar
      Divider()
      if let changedElsewhere, !code.following {
        banner(changedElsewhere)
        Divider()
      }
      content
      Divider()
      footer
    }
    .overlay(alignment: .top) {
      if store.codeQuickOpen == tab.id {
        CodeQuickOpen(worktree: worktree, changes: changes) { file in
          store.codeQuickOpen = nil
          open(file, line: nil)
        } onCancel: {
          store.codeQuickOpen = nil
        }
        .padding(.top, 40)
      }
    }
    .onAppear { store.watchCode(in: worktree) }
    .onChange(of: store.codeStep) { _, request in
      guard let request, request.tab == tab.id else { return }
      step(forward: request.forward)
    }
    .task(id: LoadKey(file: code.file, base: code.base, loads: loads)) { await load() }
    .task(id: code.base) { await readChanges() }
    // Initial too: a view shown again catches up on what changed meanwhile.
    .onChange(of: store.codeChanges[worktree.id], initial: true) { _, event in
      guard let event, event.serial > store.codeSeen[tab.id, default: 0] else { return }
      let firstLook = store.codeSeen[tab.id] == nil
      store.codeSeen[tab.id] = event.serial
      Task { await readChanges() }
      // Shown for the first time: an old change isn't news.
      if firstLook, !code.following { return }
      if code.following, event.path != code.file {
        scroll = .change
        store.openCode(event.path, tab: tab.id, in: worktree, following: true)
      } else if let file = code.file, event.paths.contains(file) {
        scroll = code.following ? .change : .none
        keepPlace = !code.following
        loads += 1
      } else if !code.following {
        changedElsewhere = event.path
      }
    }
  }

  // MARK: Parts

  private var bar: some View {
    HStack(spacing: 8) {
      Button {
        showingFiles.toggle()
      } label: {
        HStack(spacing: 4) {
          Text(code.file.map(Self.breadcrumb) ?? "No file").lineLimit(1).truncationMode(.head)
          if let status = code.file.flatMap({ file in changes.first { $0.path == file }?.status }) {
            Text(status).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Self.tint(status))
          }
          Image(systemName: "chevron.down").font(.caption2)
        }
      }
      .buttonStyle(.borderless)
      .help("Changed files, and every file")
      .popover(isPresented: $showingFiles, arrowEdge: .bottom) {
        CodeFilesPopover(worktree: worktree, changes: changes, current: code.file) { file in
          showingFiles = false
          open(file, line: nil)
        }
      }
      let files = CodeChanges.steppable(changes)
      if !files.isEmpty {
        HStack(spacing: 2) {
          Button {
            step(forward: false)
          } label: {
            Image(systemName: "chevron.left")
          }
          .help("Previous changed file (⌥⌘[)")
          Text(CodeChanges.position(of: code.file, in: changes).map { "\($0)/\(files.count)" } ?? "\(files.count) changed")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
          Button {
            step(forward: true)
          } label: {
            Image(systemName: "chevron.right")
          }
          .help("Next changed file (⌥⌘])")
        }
      }
      Spacer(minLength: 8)
      Picker("Changes against", selection: Binding(get: { code.base }, set: { store.setCodeBase($0, tab: tab.id, in: worktree) })) {
        Text("Last Commit").tag(CodeView.Base.head)
        Text(baseName.map { "vs \($0)" } ?? "Branch").tag(CodeView.Base.branch)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .disabled(baseName == nil)
      .help("What the changes are marked against")
      Button {
        if code.following {
          store.setCodeFollowing(false, tab: tab.id, in: worktree)
        } else {
          follow()
        }
      } label: {
        Label(code.following ? "Following" : "Follow", systemImage: code.following ? "dot.radiowaves.left.and.right" : "scope")
      }
      .help(code.following ? "Opening each file as it changes; scroll or click to stop" : "Open each file as it changes")
      Button {
        store.codeQuickOpen = tab.id
      } label: {
        Image(systemName: "magnifyingglass")
      }
      .help("Go to File (⌘P)")
      Button {
        scroll = .none
        loads += 1
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("Read the file again")
      Button {
        store.toggleCode(in: worktree)
      } label: {
        Image(systemName: "sidebar.left")
      }
      .help("Hide Code (⌘E or ⌘W)")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 10)
    .frame(height: 30)
  }

  private func banner(_ file: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "pencil.line").foregroundStyle(.tint)
      Text("\(URL(fileURLWithPath: file).lastPathComponent) changed").lineLimit(1)
      Button("Follow") { follow() }.buttonStyle(.link)
      Spacer()
      Button {
        changedElsewhere = nil
      } label: {
        Image(systemName: "xmark").font(.caption)
      }
      .buttonStyle(.borderless)
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.accentColor.opacity(0.1))
  }

  @ViewBuilder private var content: some View {
    if code.file == nil {
      noFile
    } else if let error {
      ContentUnavailableView("Can't Show This File", systemImage: "doc.questionmark", description: Text(error))
    } else if let file = loaded ?? store.codePages[tab.id]?.bridge.current.flatMap({ $0.path == code.file ? $0 : nil }) {
      // Coming back to the tab: what its kept page already shows, until read again.
      CodeWebView(page: store.codePage(for: tab.id), file: file, comments: comments(of: file.path)) { message in
        handle(message)
      }
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Before any file: what changed, and how to pick one.
  private var noFile: some View {
    VStack(spacing: 12) {
      ContentUnavailableView(
        "Code Follows the Agent", systemImage: "chevron.left.forwardslash.chevron.right",
        description: Text("The next file that changes opens here. Or pick one: ⌘P, or the path bar."))
      if !changes.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Changed").font(.caption).foregroundStyle(.secondary)
          ForEach(changes.prefix(12), id: \.path) { change in
            Button {
              open(change.path, line: nil)
            } label: {
              HStack {
                Text(change.status).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Self.tint(change.status))
                Text(change.path).lineLimit(1).truncationMode(.middle)
              }
            }
            .buttonStyle(.link)
            .disabled(change.status == "D")
          }
        }
        .frame(maxWidth: 420, alignment: .leading)
      }
      Spacer()
    }
    .padding()
  }

  private var footer: some View {
    HStack(spacing: 8) {
      let count = code.comments.count
      if count == 0 {
        Text("Click a line number to comment").font(.caption).foregroundStyle(.secondary)
      } else {
        Menu("\(count) comment\(count == 1 ? "" : "s")") {
          ForEach(code.comments) { comment in
            Button("\(URL(fileURLWithPath: comment.path).lastPathComponent):\(comment.line)  \(comment.text.prefix(60))"
              + (comment.sent ? "  ✓" : ""))
            {
              open(comment.path, line: comment.side == .new ? comment.line : nil)
            }
          }
          Divider()
          Button("Delete All Comments", role: .destructive) { store.clearCodeComments(tab: tab.id, in: worktree) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
      }
      Spacer()
      Button(copied ? "Copied" : "Copy Prompt") { copyPrompt() }
        .disabled(count == 0 || copied)
        .help("Your comments as a prompt, on the clipboard")
      let agent = store.agentPane(of: tab, in: worktree)
      Button("Send to Agent") {
        sending = true
        Task {
          _ = await store.sendCodeComments(tab: tab.id, in: worktree)
          sending = false
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(sending || agent == nil || !code.comments.contains { !$0.sent })
      .help(
        agent != nil
          ? "Paste the comments not sent yet into the agent beside the code, and submit them"
          : store.agentAsking(in: tab, of: worktree)
            ? "The agent is asking you something: answer it first, so Enter doesn't."
            : "No agent is running in this tab's terminals. Copy Prompt puts the comments on the clipboard.")
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .frame(height: 32)
  }

  // MARK: Actions

  private func comments(of path: String) -> [DiffComment] { code.comments.filter { $0.path == path } }

  private func open(_ file: String, line: Int?) {
    scroll = line.map(CodeScroll.line) ?? .change
    changedElsewhere = nil
    if file == code.file {
      store.setCodeFollowing(false, tab: tab.id, in: worktree)
      loads += 1
    } else {
      store.openCode(file, tab: tab.id, in: worktree)
    }
  }

  /// Opens the next (or previous) changed file at its first change; a beep
  /// when there's no other.
  private func step(forward: Bool) {
    guard let next = CodeChanges.neighbor(of: code.file, in: changes, forward: forward) else {
      NSSound.beep()
      return
    }
    open(next, line: nil)
  }

  private func follow() {
    let latest = store.codeChanges[worktree.id]?.path ?? changedElsewhere
    changedElsewhere = nil
    scroll = .change
    if let latest, latest != code.file {
      store.openCode(latest, tab: tab.id, in: worktree, following: true)
    } else {
      store.setCodeFollowing(true, tab: tab.id, in: worktree)
      loads += 1
    }
  }

  private func handle(_ message: CodeMessage) {
    switch message {
    case .save(let comment): store.saveCodeComment(comment, tab: tab.id, in: worktree)
    case .delete(let id): store.deleteCodeComment(id, tab: tab.id, in: worktree)
    case .place(let anchors): store.placeCodeComments(anchors, tab: tab.id, in: worktree)
    case .interact: if code.following { store.setCodeFollowing(false, tab: tab.id, in: worktree) }
    case .open(let path, let line): open(path, line: line)
    case .definition(let name):
      Task {
        let hits = (try? await CodeSource.definitions(of: name, in: worktree.path, from: code.file)) ?? []
        if hits.count == 1, let hit = hits.first {
          open(hit.path, line: hit.line)
        } else {
          store.codePage(for: tab.id).bridge.definitions(name, hits, in: store.codePage(for: tab.id).view)
        }
      }
    }
  }

  private func copyPrompt() {
    Task {
      guard let prompt = await store.codePrompt(tab: tab.id, in: worktree, unsentOnly: false) else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(prompt, forType: .string)
      copied = true
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }

  private func load() async {
    guard let file = code.file else {
      loaded = nil
      return
    }
    guard let rev = await revision() else { return }
    do {
      let read = try await CodeSource.load(file, in: worktree.path, against: rev)
      // A newer read took over, or the tab moved on, while this was read.
      guard !Task.isCancelled,
        store.layout(for: worktree).tabs.first(where: { $0.id == tab.id })?.code?.file == file
      else { return }
      let bridge = store.codePage(for: tab.id).bridge
      // The page already shows this file (the tab was left and come back to):
      // stay where the reader was.
      if keepPlace, loaded == nil, bridge.current?.path == file, scroll == .change { scroll = .none }
      keepPlace = false
      loaded = CodeShown(
        path: file, text: read.text, diff: read.diff, untracked: read.untracked, language: Self.language(of: file),
        serial: (bridge.current?.serial ?? 0) + 1, scroll: scroll)
      scroll = .none
      error = nil
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  private func readChanges() async {
    if baseName == nil, let repo = store.repo(of: worktree) {
      let base = await Git.defaultBase(root: repo.path)
      baseName = base == "HEAD" ? nil : base
    }
    guard let rev = await revision() else { return }
    changes = (try? await CodeSource.changes(in: worktree.path, against: rev)) ?? []
  }

  private func revision() async -> String? {
    if code.base == .head { return "HEAD" }
    guard let repo = store.repo(of: worktree) else { return "HEAD" }
    return await CodeSource.revision(.branch, in: worktree.path, repository: repo.path) ?? "HEAD"
  }

  // MARK: Helpers

  static func breadcrumb(_ path: String) -> String { path.split(separator: "/").joined(separator: " › ") }

  static func tint(_ status: String) -> Color {
    switch status {
    case "A": .green
    case "D": .red
    default: .orange
    }
  }

  /// highlight.js's name for the file's language: its extension, which it
  /// knows as an alias for most.
  static func language(of path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    if name == "makefile" || name == "dockerfile" { return name }
    let ext = URL(fileURLWithPath: name).pathExtension
    return ext.isEmpty ? name : ext
  }

  private struct LoadKey: Equatable {
    var file: String?
    var base: CodeView.Base
    var loads: Int
  }
}

/// Where a drawn file should scroll.
enum CodeScroll: Equatable {
  case none
  /// To what just changed, or a newly opened file's first change.
  case change
  case line(Int)
}

/// A file as the code page draws it.
struct CodeShown: Equatable {
  var path: String
  var text: String
  var diff: String
  var untracked: Bool
  var language: String
  /// Counts reads: a new one is drawn again, with its scroll.
  var serial: Int
  var scroll: CodeScroll
}

/// What the code page asks of the app.
enum CodeMessage {
  case save(DiffComment)
  case delete(String)
  case place([DiffComment.Anchor])
  /// The user scrolled or clicked: stop following.
  case interact
  case definition(String)
  case open(path: String, line: Int)
}

/// A tab's code page, kept while the tab exists (`AppStore.codePages`).
@MainActor
final class CodePage {
  let view: WKWebView
  let bridge = CodeBridge()

  init() {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(CodeMessageRelay(bridge), name: "yatty")
    view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = bridge
    if let page = DiffAssets.page("code.html") {
      view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    } else {
      view.loadHTMLString(
        "<p style=\"font: 13px -apple-system; padding: 20px\">The code view's files are missing from Yatty.app.</p>",
        baseURL: nil)
    }
  }

  func close() {
    view.configuration.userContentController.removeScriptMessageHandler(forName: "yatty")
    view.removeFromSuperview()
  }
}

struct CodeWebView: NSViewRepresentable {
  let page: CodePage
  let file: CodeShown
  let comments: [DiffComment]
  let onMessage: (CodeMessage) -> Void

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ container: NSView, context: Context) {
    if page.view.superview !== container {
      page.view.removeFromSuperview()
      page.view.frame = container.bounds
      page.view.autoresizingMask = [.width, .height]
      container.addSubview(page.view)
    }
    page.bridge.onMessage = onMessage
    page.bridge.show(file, comments: comments, in: page.view)
  }
}

/// The page's side: draws what's wanted, relays what it says.
@MainActor
final class CodeBridge: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  var onMessage: (CodeMessage) -> Void = { _ in }
  private var loaded = false
  private var wanted: (file: CodeShown, comments: [DiffComment])?
  private var shown: CodeShown?
  /// What the page draws, or will once it has loaded.
  var current: CodeShown? { wanted?.file }
  private var shownComments: [DiffComment]?

  func show(_ file: CodeShown, comments: [DiffComment], in view: WKWebView) {
    wanted = (file, comments)
    render(in: view)
  }

  /// A new read is drawn whole; comments alone are put in place.
  private func render(in view: WKWebView) {
    guard loaded, let wanted else { return }
    if shown == wanted.file {
      guard shownComments != wanted.comments else { return }
      shownComments = wanted.comments
      view.callAsyncJavaScript(
        "yattySetComments(comments)", arguments: ["comments": wanted.comments.map(\.page)], in: nil, in: .page)
      return
    }
    shown = wanted.file
    shownComments = wanted.comments
    let scroll: Any =
      switch wanted.file.scroll {
      case .none: NSNull()
      case .change: "change"
      case .line(let line): ["line": line]
      }
    let file: [String: Any] = [
      "path": wanted.file.path, "text": wanted.file.text, "diff": wanted.file.diff, "untracked": wanted.file.untracked,
      "language": wanted.file.language, "comments": wanted.comments.map(\.page), "scroll": scroll,
    ]
    view.callAsyncJavaScript("return yattyShow(file)", arguments: ["file": file], in: nil, in: .page) { result in
      if case .failure(let error) = result { Snapshot.note("code not drawn: \(error)") }
    }
  }

  /// Declarations of `name` the app found, for the page to offer.
  func definitions(_ name: String, _ hits: [CodeDefinitions.Hit], in view: WKWebView) {
    let list = hits.map { ["path": $0.path, "line": $0.line, "text": $0.text] as [String: Any] }
    view.callAsyncJavaScript("yattyDefinitions(name, hits)", arguments: ["name": name, "hits": list], in: nil, in: .page)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loaded = true
    render(in: webView)
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    switch type {
    case "save": if let comment = DiffComment(saved: body) { onMessage(.save(comment)) }
    case "delete": if let id = body["id"] as? String { onMessage(.delete(id)) }
    case "place":
      let anchors = DiffComment.Anchor.list(body)
      if !anchors.isEmpty { onMessage(.place(anchors)) }
    case "interact": onMessage(.interact)
    case "definition": if let name = body["name"] as? String { onMessage(.definition(name)) }
    case "open":
      if let path = body["path"] as? String, let line = (body["line"] as? NSNumber)?.intValue {
        onMessage(.open(path: path, line: line))
      }
    default: break
    }
  }

  /// The page's process died: load it again and redraw.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    loaded = false
    shown = nil
    shownComments = nil
    webView.reload()
  }

  /// Links open in the browser, never in here.
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

/// Hands the page's messages on without the content controller keeping the
/// bridge (and its web view) alive.
@MainActor
private final class CodeMessageRelay: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(controller, didReceive: message)
  }
}

/// The path bar's list: the changed files, then every file as a tree.
struct CodeFilesPopover: View {
  let worktree: Worktree
  let changes: [CodeChange]
  let current: String?
  let onOpen: (String) -> Void
  @State private var tree: [CodeFileNode] = []

  var body: some View {
    List {
      if !changes.isEmpty {
        Section("Changed") {
          ForEach(changes, id: \.path) { change in
            Button {
              onOpen(change.path)
            } label: {
              HStack {
                Text(change.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(change.status).font(.caption.monospaced().weight(.semibold)).foregroundStyle(CodePaneView.tint(change.status))
              }
            }
            .buttonStyle(.plain)
            .disabled(change.status == "D")
            .fontWeight(change.path == current ? .semibold : .regular)
          }
        }
      }
      Section("All Files") {
        OutlineGroup(tree, children: \.children) { node in
          if let path = node.path {
            Button(node.name) { onOpen(path) }
              .buttonStyle(.plain)
              .fontWeight(path == current ? .semibold : .regular)
          } else {
            Label(node.name, systemImage: "folder").foregroundStyle(.secondary)
          }
        }
      }
    }
    .frame(width: 380, height: 460)
    .task { tree = CodeFileNode.tree((try? await CodeSource.files(in: worktree.path)) ?? []) }
  }
}

/// A file or folder in the path bar's tree.
struct CodeFileNode: Identifiable, Hashable {
  var id: String
  var name: String
  /// nil for a folder.
  var path: String?
  var children: [CodeFileNode]?

  /// Folders first, then files, each by name.
  static func tree(_ files: [String]) -> [CodeFileNode] {
    final class Folder {
      var folders: [String: Folder] = [:]
      var files: [String] = []
    }
    let root = Folder()
    for file in files {
      var folder = root
      let parts = file.split(separator: "/").map(String.init)
      for part in parts.dropLast() {
        if let next = folder.folders[part] {
          folder = next
        } else {
          let next = Folder()
          folder.folders[part] = next
          folder = next
        }
      }
      folder.files.append(file)
    }
    func nodes(_ folder: Folder, prefix: String) -> [CodeFileNode] {
      let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
        CodeFileNode(id: prefix + name + "/", name: name, path: nil, children: nodes(folder.folders[name]!, prefix: prefix + name + "/"))
      }
      let files = folder.files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
        CodeFileNode(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path, children: nil)
      }
      return folders + files
    }
    return nodes(root, prefix: "")
  }
}

/// ⌘P: a file by a few letters of its name.
struct CodeQuickOpen: View {
  let worktree: Worktree
  let changes: [CodeChange]
  let onOpen: (String) -> Void
  let onCancel: () -> Void
  @State private var query = ""
  @State private var files: [String] = []
  @State private var selection = 0
  @FocusState private var focused: Bool

  var body: some View {
    let matches = QuickOpen.rank(query, query.isEmpty ? recentFirst : files, limit: 30)
    VStack(alignment: .leading, spacing: 0) {
      TextField("Go to file…", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(10)
        .focused($focused)
        .onSubmit { if matches.indices.contains(selection) { onOpen(matches[selection]) } }
        .onKeyPress(.downArrow) {
          selection = min(selection + 1, max(matches.count - 1, 0))
          return .handled
        }
        .onKeyPress(.upArrow) {
          selection = max(selection - 1, 0)
          return .handled
        }
        .onKeyPress(.escape) {
          onCancel()
          return .handled
        }
        .onChange(of: query) { selection = 0 }
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(matches.enumerated()), id: \.element) { index, file in
            HStack(spacing: 6) {
              Text(URL(fileURLWithPath: file).lastPathComponent).fontWeight(.medium)
              Text(file).font(.caption).foregroundStyle(index == selection ? Color.white.opacity(0.8) : .secondary)
                .lineLimit(1).truncationMode(.middle)
              Spacer()
              if let status = changes.first(where: { $0.path == file })?.status {
                Text(status).font(.caption.monospaced().weight(.semibold))
                  .foregroundStyle(index == selection ? .white : CodePaneView.tint(status))
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(index == selection ? .white : .primary)
            .background(index == selection ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { onOpen(file) }
          }
        }
        .padding(4)
      }
      .frame(maxHeight: 320)
    }
    .frame(width: 460)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    .shadow(radius: 18, y: 6)
    .onAppear { focused = true }
    .task { files = (try? await CodeSource.files(in: worktree.path)) ?? [] }
  }

  /// With nothing typed: the changed files first.
  private var recentFirst: [String] {
    let changed = changes.filter { $0.status != "D" }.map(\.path)
    return changed + files.filter { !changed.contains($0) }
  }
}
