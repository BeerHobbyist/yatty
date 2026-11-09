import SwiftUI
import WebKit

/// Yatty's diff viewer: a diff in a window of its own, unified or side by
/// side, read again on demand. ⌘W closes it like any window.
struct DiffWindow: View {
  let request: DiffRequest
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  /// Past this the page would choke: a terminal viewer copes better.
  private static let largest = 20_000_000
  @State private var diff: String?
  @State private var error: String?
  @State private var loading = false

  var body: some View {
    @Bindable var store = store
    Group {
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
            description: Text("\(request.target.title) in \(request.worktreeName): nothing differs."))
        } else {
          DiffWebView(diff: diff, layout: store.diffLayout)
        }
      } else {
        ProgressView()
      }
    }
    .frame(minWidth: 640, minHeight: 420)
    .navigationTitle(request.worktreeName)
    .navigationSubtitle(request.target.title)
    .toolbar {
      ToolbarItem {
        Picker("Layout", selection: $store.diffLayout) {
          Label("Unified", systemImage: "rectangle").tag(DiffLayout.unified)
          Label("Side by Side", systemImage: "rectangle.split.2x1").tag(DiffLayout.split)
        }
        .pickerStyle(.segmented)
        .help("Unified or side by side")
      }
      ToolbarItem {
        Button {
          Task { await load() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Read the diff again")
        .disabled(loading)
      }
    }
    // ⌘W closes this window: the menu's ⌘W is the terminal's Close Pane.
    .background {
      Button("Close") { dismiss() }.keyboardShortcut("w").opacity(0).allowsHitTesting(false)
    }
    // Again whenever this diff is asked for again.
    .task(id: store.diffReads[request, default: 0]) { await load() }
  }

  private func load() async {
    loading = true
    defer { loading = false }
    do {
      diff = try await GitDiff.text(in: request.worktreePath, target: request.target)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// diff2html in a web view, from the `diff/` folder the app bundles.
struct DiffWebView: NSViewRepresentable {
  let diff: String
  let layout: DiffLayout

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let view = WKWebView()
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
    context.coordinator.show(diff, layout: layout, in: view)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    private var loaded = false
    private var wanted: (diff: String, layout: DiffLayout)?
    private var shown: (diff: String, layout: DiffLayout)?

    func show(_ diff: String, layout: DiffLayout, in view: WKWebView) {
      wanted = (diff, layout)
      render(in: view)
    }

    /// Draws what's wanted once the page is there, and only when it changed.
    private func render(in view: WKWebView) {
      guard loaded, let wanted, shown?.diff != wanted.diff || shown?.layout != wanted.layout else { return }
      shown = wanted
      view.callAsyncJavaScript(
        "return yattyRender(diff, layout)", arguments: ["diff": wanted.diff, "layout": wanted.layout.rawValue],
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
