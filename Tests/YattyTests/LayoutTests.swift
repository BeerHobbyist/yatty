import Foundation
import Testing

@testable import Yatty

@Test func splitThenRemoveCollapses() {
  let tree = SplitNode.pane("a").splitting("a", with: "b", axis: .horizontal, newFirst: false)
  #expect(tree == .split(.horizontal, ratio: 0.5, first: .pane("a"), second: .pane("b")))
  #expect(tree.removing("a") == .pane("b"))
  #expect(SplitNode.pane("a").splitting("a", with: "b", axis: .vertical, newFirst: true).panes == ["b", "a"])
}

@Test func removingLastPaneIsNil() {
  #expect(SplitNode.pane("a").removing("a") == nil)
  #expect(SplitNode.pane("a").removing("x") == .pane("a"))
}

@Test func ratioClampsAndFollowsPath() {
  let tree = SplitNode.split(
    .horizontal, ratio: 0.5, first: .pane("a"),
    second: .split(.vertical, ratio: 0.5, first: .pane("b"), second: .pane("c")))
  let resized = tree.settingRatio(0.99, at: [true])
  #expect(resized == .split(
    .horizontal, ratio: 0.5, first: .pane("a"),
    second: .split(.vertical, ratio: 0.9, first: .pane("b"), second: .pane("c"))))
  #expect(tree.settingRatio(0.01, at: []) == .split(
    .horizontal, ratio: 0.1, first: .pane("a"),
    second: .split(.vertical, ratio: 0.5, first: .pane("b"), second: .pane("c"))))
  #expect(resized.equalized() == tree)
}

@Test func neighborInUnevenSplit() {
  let tree = SplitNode.split(
    .horizontal, ratio: 0.3, first: .pane("a"),
    second: .split(.vertical, ratio: 0.5, first: .pane("b"), second: .pane("c")))
  #expect(tree.neighbor(of: "c", toward: .left) == "a")
  #expect(tree.neighbor(of: "a", toward: .right) == "b")
  #expect(tree.neighbor(of: "b", toward: .down) == "c")
  #expect(tree.neighbor(of: "c", toward: .up) == "b")
  #expect(tree.neighbor(of: "a", toward: .left) == nil)
}

@Test func closeFocusedPaneFocusesSibling() {
  var layout = WorktreeLayout.initial
  layout.split("0", new: "b", axis: .horizontal, newFirst: false)
  layout.split("b", new: "c", axis: .vertical, newFirst: false)
  #expect(layout.selected?.focusedPane == "c")
  layout.close("c")
  #expect(layout.selected?.focusedPane == "b")
  layout.setFocus("0")
  layout.close("b")
  #expect(layout.selected?.root == .pane("0"))
  #expect(layout.selected?.focusedPane == "0")
}

@Test func closingLastPaneOfTabSelectsNeighbour() {
  var layout = WorktreeLayout.initial
  layout.addTab(pane: "p1", id: "t1")
  layout.addTab(pane: "p2", id: "t2")
  #expect(layout.tabs.map(\.id) == ["t0", "t1", "t2"])
  layout.select("t1")
  layout.close("p1")
  #expect(layout.tabs.map(\.id) == ["t0", "t2"])
  #expect(layout.selectedTab == "t2")
  layout.close("p2")
  #expect(layout.selectedTab == "t0")
  layout.close("0")
  #expect(layout.tabs.isEmpty)
  #expect(layout.selectedTab == nil)
}

@Test func gotoTabResolves() {
  var layout = WorktreeLayout.initial
  layout.addTab(pane: "p1", id: "t1")
  layout.addTab(pane: "p2", id: "t2")
  layout.select("t0")
  #expect(layout.tabID(for: .index(2)) == "t1")
  #expect(layout.tabID(for: .index(9)) == "t2")
  #expect(layout.tabID(for: .previous) == "t2")
  #expect(layout.tabID(for: .next) == "t1")
  #expect(layout.tabID(for: .last) == "t2")
}

@Test func layoutRoundTrips() throws {
  var layout = WorktreeLayout.initial
  layout.split("0", new: "ab12cd", axis: .vertical, newFirst: false)
  layout.addTab(pane: "ef34ab", id: "t1")
  layout.rename("t1", to: "dev server")
  let data = try JSONEncoder().encode(layout)
  let decoded = try JSONDecoder().decode(WorktreeLayout.self, from: data)
  #expect(decoded == layout)
}

@Test func newPaneIDsAreShortHex() {
  let id = newPaneID()
  #expect(id.count == 6)
  let isHex = id.allSatisfy { $0.isHexDigit }
  #expect(isHex)
}
