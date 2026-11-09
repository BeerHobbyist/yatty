import SwiftUI

/// A worktree's terminals: its tab bar and the selected tab's splits.
struct TerminalsView: View {
  let worktree: Worktree
  @Environment(AppStore.self) private var store

  var body: some View {
    let layout = store.layout(for: worktree)
    VStack(spacing: 0) {
      // Every pane of every tab attaches, so hidden tabs get their titles.
      let _ = store.startTerminals(of: worktree)
      if let tab = layout.selected {
        TabBar(worktree: worktree, layout: layout)
        Divider()
        if let diff = tab.diff {
          DiffTabView(worktree: worktree, tab: tab, diffTab: diff).id(tab.id)
        } else {
          SplitNodeView(node: tab.root, path: [], tab: tab, worktree: worktree)
        }
      } else {
        ContentUnavailableView {
          Label("No Terminals", systemImage: "terminal")
        } description: {
          Text("Every tab in this worktree is closed.")
        } actions: {
          Button("New Terminal") { store.newTab(in: worktree, agent: false) }
          Button("New Agent") { store.newTab(in: worktree, agent: true) }
        }
      }
    }
  }
}

struct TabBar: View {
  let worktree: Worktree
  let layout: WorktreeLayout
  @Environment(AppStore.self) private var store

  var body: some View {
    HStack(spacing: 2) {
      // `+` follows the last tab; once the tabs overflow and scroll, it stays
      // pinned beside them.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 2) {
          tabs
          newTabMenu
        }
        .padding(.horizontal, 6)
        HStack(spacing: 2) {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) { tabs }.padding(.horizontal, 6)
          }
          newTabMenu
        }
      }
      Spacer(minLength: 8)
      // A diff tab has no terminal to split.
      if let tab = layout.selected, tab.diff == nil {
        let focused = PaneKey(worktree: worktree.id, pane: tab.focusedPane)
        Button {
          store.split(focused, axis: .horizontal, newFirst: false)
        } label: {
          Image(systemName: "rectangle.split.2x1")
        }
        .help("Split right")
        Button {
          store.split(focused, axis: .vertical, newFirst: false)
        } label: {
          Image(systemName: "rectangle.split.1x2")
        }
        .help("Split down")
      }
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 8)
    .frame(height: 30)
    .background(.bar)
  }

  private var tabs: some View {
    ForEach(layout.tabs) { tab in
      TabButton(worktree: worktree, tab: tab, isSelected: tab.id == layout.selectedTab)
    }
  }

  private var newTabMenu: some View {
    Menu {
      Button("New Shell") { store.newTab(in: worktree, agent: false) }
      Button("New Agent") { store.newTab(in: worktree, agent: true) }
      Button("New Diff…") { store.diffingWorktree = worktree }
        .disabled(worktree.isRemote)
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .padding(.leading, 4)
    .help("New tab")
  }
}

private struct TabButton: View {
  let worktree: Worktree
  let tab: TerminalTab
  let isSelected: Bool
  @Environment(AppStore.self) private var store
  @State private var hovering = false
  @State private var renaming = false
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool

  var body: some View {
    HStack(spacing: 4) {
      if renaming {
        TextField("Tab name", text: $draft)
          .textFieldStyle(.plain)
          .focused($fieldFocused)
          .frame(width: 140)
          .onAppear { fieldFocused = true }
          .onSubmit { finishRename() }
          .onExitCommand {
            renaming = false
            store.focusSelectedTerminal()
          }
          .onChange(of: fieldFocused) { _, focused in if !focused { finishRename() } }
      } else {
        if tab.diff != nil { Octicon(.fileDiff, size: 11).foregroundStyle(.secondary) }
        Text(middleTruncated(store.title(of: tab, in: worktree), to: 24))
          .lineLimit(1)
      }
      Button {
        store.closeTab(tab.id, in: worktree)
      } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
      }
      .buttonStyle(.borderless)
      .opacity(isSelected || hovering ? 1 : 0)
      .help("Close tab")
    }
    .font(.callout)
    .foregroundStyle(isSelected ? .primary : .secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    // Selects at once; a second click also starts renaming.
    .onTapGesture { store.selectTab(tab.id, in: worktree) }
    .simultaneousGesture(TapGesture(count: 2).onEnded { startRename() })
    .contextMenu {
      Button("Rename…") { startRename() }
      Button("Close Tab") { store.closeTab(tab.id, in: worktree) }
    }
  }

  private func startRename() {
    draft = tab.name ?? ""
    renaming = true
  }

  private func finishRename() {
    guard renaming else { return }
    renaming = false
    store.renameTab(tab.id, to: draft, in: worktree)
    store.focusSelectedTerminal()
  }
}

/// A split: its two children with a draggable divider; or one pane.
struct SplitNodeView: View {
  let node: SplitNode
  /// Which split this is within its tab: false = first child, true = second.
  let path: [Bool]
  let tab: TerminalTab
  let worktree: Worktree

  var body: some View {
    switch node {
    case .pane(let pane):
      PaneView(
        key: PaneKey(worktree: worktree.id, pane: pane), worktree: worktree,
        dimmed: tab.root.panes.count > 1 && tab.focusedPane != pane)
    case .split(let axis, let ratio, let first, let second):
      GeometryReader { geometry in
        let total = axis == .horizontal ? geometry.size.width : geometry.size.height
        let firstLength = max(0, total * ratio - Divider.thickness / 2)
        let secondLength = max(0, total - firstLength - Divider.thickness)
        let layout = axis == .horizontal
          ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
          SplitNodeView(node: first, path: path + [false], tab: tab, worktree: worktree)
            .frame(
              width: axis == .horizontal ? firstLength : nil,
              height: axis == .vertical ? firstLength : nil)
          SplitDivider(axis: axis, total: total, space: space, path: path, tab: tab, worktree: worktree)
          SplitNodeView(node: second, path: path + [true], tab: tab, worktree: worktree)
            .frame(
              width: axis == .horizontal ? secondLength : nil,
              height: axis == .vertical ? secondLength : nil)
        }
        .coordinateSpace(.named(space))
      }
    }
  }

  /// The split's own coordinate space, which its divider is dragged in.
  private var space: String { "split-" + path.map { $0 ? "1" : "0" }.joined() }

  enum Divider {
    static let thickness: CGFloat = 1
  }
}

private struct SplitDivider: View {
  let axis: SplitAxis
  let total: CGFloat
  let space: String
  let path: [Bool]
  let tab: TerminalTab
  let worktree: Worktree
  @Environment(AppStore.self) private var store

  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .frame(
        width: axis == .horizontal ? SplitNodeView.Divider.thickness : nil,
        height: axis == .vertical ? SplitNodeView.Divider.thickness : nil)
      .overlay {
        // A wider grab area than the line itself.
        Color.clear
          .frame(width: axis == .horizontal ? 7 : nil, height: axis == .vertical ? 7 : nil)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside {
              (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
              NSCursor.pop()
            }
          }
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
              .onChanged { value in
                guard total > 0 else { return }
                let position = axis == .horizontal ? value.location.x : value.location.y
                store.setRatio(position / total, at: path, tab: tab.id, in: worktree, save: false)
              }
              .onEnded { _ in store.saveState() })
          .onTapGesture(count: 2) { store.equalize(tab.id, in: worktree) }
      }
      .zIndex(1)
  }
}

/// One terminal, dimmed while another pane of its tab has the keyboard.
struct PaneView: View {
  let key: PaneKey
  let worktree: Worktree
  let dimmed: Bool
  @Environment(AppStore.self) private var store

  var body: some View {
    Group {
      if store.disconnectedPanes.contains(key), let terminal = store.terminals[key] {
        // What ssh said stays readable above the way back.
        TerminalHost(terminal: terminal)
          .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
              Image(systemName: "wifi.slash")
              Text("Disconnected from \(worktree.host ?? "the host"). The session is still there.")
              Spacer()
              Button("Reconnect") { store.reconnect(key) }
            }
            .padding(10)
            .background(.regularMaterial)
          }
      } else if store.disconnectedPanes.contains(key) {
        ContentUnavailableView {
          Label("Disconnected", systemImage: "wifi.slash")
        } description: {
          Text("The connection to \(worktree.host ?? "the host") went. Its session is still running there.")
        } actions: {
          Button("Reconnect") { store.reconnect(key) }
        }
      } else if Snapshot.isActive {
        // libghostty can't start under the sandbox snapshots run in.
        Color(nsColor: .textBackgroundColor)
          .overlay(alignment: .topLeading) {
            Text("terminal \(key.pane)").font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary).padding(8)
          }
      } else if let terminal = store.terminal(for: key, in: worktree) {
        TerminalHost(terminal: terminal)
      } else if store.failedPanes.contains(key) {
        ContentUnavailableView {
          Label("Couldn't Start the Terminal", systemImage: "exclamationmark.triangle")
        } description: {
          Text("zmx couldn't be reached, or libghostty didn't create a terminal.")
        } actions: {
          Button("Try Again") { store.retryPane(key) }
        }
      } else {
        // Starting: a moment while zmx is asked whether the session exists.
        Color.clear
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
      if dimmed {
        Color.black.opacity(0.18).allowsHitTesting(false)
      }
    }
  }
}

/// Shows a terminal that outlives the view: switching tabs or worktrees
/// moves the terminal views in and out, never recreating them.
struct TerminalHost: NSViewRepresentable {
  let terminal: TerminalView

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ container: NSView, context: Context) {
    guard terminal.superview !== container else { return }
    container.subviews.forEach { $0.removeFromSuperview() }
    terminal.frame = container.bounds
    terminal.autoresizingMask = [.width, .height]
    container.addSubview(terminal)
  }
}

/// `text` cut to `limit` characters by an ellipsis in the middle, so both
/// ends of a long tab title stay readable.
func middleTruncated(_ text: String, to limit: Int) -> String {
  guard text.count > limit, limit > 1 else { return text }
  let head = (limit - 1) / 2
  let tail = limit - 1 - head
  return String(text.prefix(head)) + "…" + String(text.suffix(tail))
}
