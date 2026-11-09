import CoreGraphics
import Foundation

/// horizontal: side by side (Ghostty's `new_split:right`); vertical: stacked.
enum SplitAxis: String, Codable, Sendable {
  case horizontal
  case vertical
}

enum FocusDirection: Sendable {
  case left, right, up, down
}

enum GotoTab: Equatable, Sendable {
  /// 1-based; past the end means the last tab.
  case index(Int)
  case previous, next, last
}

/// A tab's panes: a leaf per terminal, a split per divider.
indirect enum SplitNode: Codable, Equatable, Sendable {
  case pane(String)
  case split(SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

  /// Depth-first, first before second: left to right, top to bottom.
  var panes: [String] {
    switch self {
    case .pane(let id): [id]
    case .split(_, _, let first, let second): first.panes + second.panes
    }
  }

  func splitting(_ pane: String, with new: String, axis: SplitAxis, newFirst: Bool) -> SplitNode {
    switch self {
    case .pane(let id) where id == pane:
      newFirst
        ? .split(axis, ratio: 0.5, first: .pane(new), second: self)
        : .split(axis, ratio: 0.5, first: self, second: .pane(new))
    case .pane:
      self
    case .split(let axis2, let ratio, let first, let second):
      .split(
        axis2, ratio: ratio,
        first: first.splitting(pane, with: new, axis: axis, newFirst: newFirst),
        second: second.splitting(pane, with: new, axis: axis, newFirst: newFirst))
    }
  }

  /// The tree without `pane`: its split collapses into the sibling; nil when
  /// nothing is left.
  func removing(_ pane: String) -> SplitNode? {
    switch self {
    case .pane(let id):
      return id == pane ? nil : self
    case .split(let axis, let ratio, let first, let second):
      switch (first.removing(pane), second.removing(pane)) {
      case (nil, nil): return nil
      case (let kept?, nil), (nil, let kept?): return kept
      case (let a?, let b?): return .split(axis, ratio: ratio, first: a, second: b)
      }
    }
  }

  /// The pane that takes over `pane`'s space when it closes: the nearest one
  /// in its sibling subtree.
  func sibling(of pane: String) -> String? {
    guard case .split(_, _, let first, let second) = self else { return nil }
    if first == .pane(pane) { return second.panes.first }
    if second == .pane(pane) { return first.panes.last }
    return first.sibling(of: pane) ?? second.sibling(of: pane)
  }

  /// `path` picks the split: false = first child, true = second.
  func settingRatio(_ ratio: Double, at path: [Bool]) -> SplitNode {
    guard case .split(let axis, let current, let first, let second) = self else { return self }
    guard let step = path.first else {
      return .split(axis, ratio: min(max(ratio, 0.1), 0.9), first: first, second: second)
    }
    let rest = Array(path.dropFirst())
    return step
      ? .split(axis, ratio: current, first: first, second: second.settingRatio(ratio, at: rest))
      : .split(axis, ratio: current, first: first.settingRatio(ratio, at: rest), second: second)
  }

  func equalized() -> SplitNode {
    guard case .split(let axis, _, let first, let second) = self else { return self }
    return .split(axis, ratio: 0.5, first: first.equalized(), second: second.equalized())
  }

  /// Every pane's frame, origin top left.
  func frames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [String: CGRect] {
    switch self {
    case .pane(let id):
      return [id: rect]
    case .split(let axis, let ratio, let first, let second):
      let (a, b): (CGRect, CGRect)
      switch axis {
      case .horizontal:
        let width = rect.width * ratio
        a = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        b = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
      case .vertical:
        let height = rect.height * ratio
        a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        b = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
      }
      return first.frames(in: a).merging(second.frames(in: b)) { old, _ in old }
    }
  }

  /// The pane beyond `pane`'s edge in `direction` that overlaps it: the
  /// closest, then the top- or left-most.
  func neighbor(of pane: String, toward direction: FocusDirection) -> String? {
    let frames = frames()
    guard let from = frames[pane] else { return nil }
    let epsilon = 1e-9
    let candidates = frames.compactMap { id, frame -> (id: String, distance: Double, start: Double)? in
      guard id != pane else { return nil }
      let overlapsRows = frame.minY < from.maxY - epsilon && frame.maxY > from.minY + epsilon
      let overlapsColumns = frame.minX < from.maxX - epsilon && frame.maxX > from.minX + epsilon
      switch direction {
      case .left where overlapsRows && frame.maxX <= from.minX + epsilon:
        return (id, from.minX - frame.maxX, frame.minY)
      case .right where overlapsRows && frame.minX >= from.maxX - epsilon:
        return (id, frame.minX - from.maxX, frame.minY)
      case .up where overlapsColumns && frame.maxY <= from.minY + epsilon:
        return (id, from.minY - frame.maxY, frame.minX)
      case .down where overlapsColumns && frame.minY >= from.maxY - epsilon:
        return (id, frame.minY - from.maxY, frame.minX)
      default:
        return nil
      }
    }
    return candidates.min { ($0.distance, $0.start) < ($1.distance, $1.start) }?.id
  }
}

struct TerminalTab: Codable, Identifiable, Equatable, Sendable {
  var id: String
  var root: SplitNode
  var focusedPane: String
  /// Set by the user; otherwise the tab is titled after its focused pane.
  var name: String?
  /// A tab showing a diff (Yatty's own viewer) instead of terminals. Its one
  /// pane is only a handle for focus and closing: it never has a session.
  var diff: DiffTab?

  /// The title when the user gave it none and no terminal names it.
  var defaultTitle: String? { diff.map { "diff: \($0.target.title)" } }
}

/// What a diff tab shows, and the comments the user left on it.
struct DiffTab: Codable, Equatable, Sendable {
  var target: DiffTarget
  var comments: [DiffComment] = []

  init(target: DiffTarget, comments: [DiffComment] = []) {
    self.target = target
    self.comments = comments
  }

  // A tab saved before comments existed still loads.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    target = try container.decode(DiffTarget.self, forKey: .target)
    comments = (try? container.decodeIfPresent([DiffComment].self, forKey: .comments)) ?? []
  }
}

/// A comment on one line of a diff: the user's own review, for their agent.
struct DiffComment: Codable, Equatable, Identifiable, Sendable {
  enum Side: String, Codable, Sendable {
    /// The line as it is now (added or unchanged).
    case new
    /// A removed line, numbered as it was.
    case old
  }

  var id: String
  var path: String
  var line: Int
  var side: Side
  /// The line's text, so the prompt can quote it and the page can find the
  /// line again once the diff has changed.
  var code: String
  var text: String
  /// Its line is no longer in the diff (the page found it nowhere).
  var outdated = false

  /// Where the page found a comment's line in the diff it drew.
  struct Anchor: Equatable, Sendable {
    var id: String
    var line: Int
    var outdated: Bool
  }
}

extension DiffComment {
  // A comment saved before it could be outdated still loads.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    path = try container.decode(String.self, forKey: .path)
    line = try container.decode(Int.self, forKey: .line)
    side = try container.decode(Side.self, forKey: .side)
    code = try container.decode(String.self, forKey: .code)
    text = try container.decode(String.self, forKey: .text)
    outdated = try container.decodeIfPresent(Bool.self, forKey: .outdated) ?? false
  }
}

extension DiffTab {
  /// Moves comments to where the page found their lines; true if any moved
  /// or went in or out of date.
  mutating func place(_ anchors: [DiffComment.Anchor]) -> Bool {
    var changed = false
    for anchor in anchors {
      guard let index = comments.firstIndex(where: { $0.id == anchor.id }) else { continue }
      if comments[index].line != anchor.line || comments[index].outdated != anchor.outdated {
        comments[index].line = anchor.line
        comments[index].outdated = anchor.outdated
        changed = true
      }
    }
    return changed
  }
}

/// A worktree's tabs, stored per worktree path in state.json.
struct WorktreeLayout: Codable, Equatable, Sendable {
  var tabs: [TerminalTab]
  var selectedTab: String?
  /// Panes a sandboxed agent opened (`yatty tab new` inside fence): their
  /// shell runs in the sandbox, so only they may be typed into from it.
  var sandboxed: Set<String> = []

  init(tabs: [TerminalTab], selectedTab: String?) {
    self.tabs = tabs
    self.selectedTab = selectedTab
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tabs = try container.decode([TerminalTab].self, forKey: .tabs)
    selectedTab = try container.decodeIfPresent(String.self, forKey: .selectedTab)
    sandboxed = try container.decodeIfPresent(Set<String>.self, forKey: .sandboxed) ?? []
  }

  /// One tab with the worktree's first pane, `0`.
  static let initial = WorktreeLayout(
    tabs: [TerminalTab(id: "t0", root: .pane("0"), focusedPane: "0")], selectedTab: "t0")

  /// Every terminal pane; a diff tab's pane isn't one.
  var allPanes: [String] { tabs.filter { $0.diff == nil }.flatMap(\.root.panes) }

  /// A new tab showing `target`'s diff, selected.
  mutating func addDiffTab(pane: String, id: String, target: DiffTarget) {
    addTab(pane: pane, id: id)
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].diff = DiffTab(target: target)
    tabs[index].name = "diff: \(target.title)"
  }

  mutating func updateDiff(_ tabID: String, _ change: (inout DiffTab) -> Void) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID }), var diff = tabs[index].diff else { return }
    change(&diff)
    tabs[index].diff = diff
  }

  /// Whether `tabID` may be closed from the CLI: not the last terminal tab,
  /// which would leave the worktree with no terminal at all.
  func canClose(_ tabID: String) -> Bool {
    guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
    return tab.diff != nil || tabs.contains { $0.id != tabID && $0.diff == nil }
  }

  /// The tab already showing `target`'s diff.
  func diffTab(for target: DiffTarget) -> TerminalTab? {
    tabs.first { $0.diff?.target == target }
  }

  var selected: TerminalTab? { tabs.first { $0.id == selectedTab } }

  func tab(containing pane: String) -> TerminalTab? {
    tabs.first { $0.root.panes.contains(pane) }
  }

  /// A new tab after the selected one (or last), selected unless told not to.
  mutating func addTab(pane: String, id: String, select: Bool = true, atEnd: Bool = false) {
    let tab = TerminalTab(id: id, root: .pane(pane), focusedPane: pane)
    if !atEnd, let index = tabs.firstIndex(where: { $0.id == selectedTab }) {
      tabs.insert(tab, at: index + 1)
    } else {
      tabs.append(tab)
    }
    if select || selectedTab == nil { selectedTab = id }
  }

  /// Splits `pane`, focusing the new one.
  mutating func split(_ pane: String, new: String, axis: SplitAxis, newFirst: Bool) {
    guard let index = tabs.firstIndex(where: { $0.root.panes.contains(pane) }), tabs[index].diff == nil else { return }
    tabs[index].root = tabs[index].root.splitting(pane, with: new, axis: axis, newFirst: newFirst)
    tabs[index].focusedPane = new
  }

  /// Removes `pane`. Its sibling takes over the focus; an emptied tab goes,
  /// and the next tab (else the previous) is selected.
  mutating func close(_ pane: String) {
    sandboxed.remove(pane)
    guard let index = tabs.firstIndex(where: { $0.root.panes.contains(pane) }) else { return }
    let sibling = tabs[index].root.sibling(of: pane)
    if let root = tabs[index].root.removing(pane) {
      tabs[index].root = root
      if tabs[index].focusedPane == pane { tabs[index].focusedPane = sibling ?? root.panes[0] }
      return
    }
    let removed = tabs.remove(at: index).id
    if selectedTab == removed {
      selectedTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }
  }

  mutating func select(_ tabID: String) {
    if tabs.contains(where: { $0.id == tabID }) { selectedTab = tabID }
  }

  /// Focuses `pane` and selects its tab.
  mutating func setFocus(_ pane: String) {
    guard let index = tabs.firstIndex(where: { $0.root.panes.contains(pane) }) else { return }
    tabs[index].focusedPane = pane
    selectedTab = tabs[index].id
  }

  /// An empty name gives the tab back its terminal's title.
  mutating func rename(_ tabID: String, to name: String) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    tabs[index].name = trimmed.isEmpty ? nil : trimmed
  }

  mutating func setRatio(_ ratio: Double, at path: [Bool], in tabID: String) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
    tabs[index].root = tabs[index].root.settingRatio(ratio, at: path)
  }

  mutating func equalize(_ tabID: String) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
    tabs[index].root = tabs[index].root.equalized()
  }

  /// The tab a "go to tab" lands on; previous and next wrap around.
  func tabID(for goto: GotoTab) -> String? {
    guard !tabs.isEmpty else { return nil }
    let current = tabs.firstIndex { $0.id == selectedTab } ?? 0
    switch goto {
    case .index(let n): return tabs[min(max(n, 1), tabs.count) - 1].id
    case .previous: return tabs[(current - 1 + tabs.count) % tabs.count].id
    case .next: return tabs[(current + 1) % tabs.count].id
    case .last: return tabs[tabs.count - 1].id
    }
  }
}

/// A pane id: 6 lowercase hex digits.
func newPaneID() -> String {
  String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
}
