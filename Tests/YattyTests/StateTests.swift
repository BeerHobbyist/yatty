import Foundation
import Testing

@testable import Yatty

@Test func phase1StateDecodes() throws {
  let json = #"{"repos":[{"name":"r","path":"/x"}],"selectedWorktree":"/x"}"#
  let state = try JSONDecoder().decode(StoredState.self, from: Data(json.utf8))
  #expect(state.repos == [Repo(path: "/x", name: "r")])
  #expect(state.selectedWorktree == "/x")
  #expect(state.layouts.isEmpty)
}

@Test func sessionNames() {
  let base = Zmx.sessionName(for: "/repo/.worktrees/login")
  #expect(base.hasPrefix("yatty-"))
  #expect(base.count == "yatty-".count + 10)
  #expect(Zmx.sessionName(for: "/repo/.worktrees/login", pane: "0") == base)
  #expect(Zmx.sessionName(for: "/repo/.worktrees/login", pane: "ab12cd") == base + "-ab12cd")
}

@Test func knownSessionsIncludeUnopenedLayouts() {
  let opened = Worktree(path: "/r", branch: "main", head: nil, isMain: true)
  let unopened = Worktree(path: "/r/.worktrees/x", branch: "x", head: nil, isMain: false)
  var layout = WorktreeLayout.initial
  layout.addTab(pane: "ab12cd", id: "t1")
  let known = Zmx.knownSessions(worktrees: [opened, unopened], layouts: [unopened.path: layout])
  #expect(known == [
    Zmx.sessionName(for: "/r"),
    Zmx.sessionName(for: unopened.path),
    Zmx.sessionName(for: unopened.path, pane: "ab12cd"),
  ])
}

@Test func agentInputOnlyForFirstPaneOfNewSession() {
  #expect(AppStore.agentInput("claude", pane: "0", sessionIsNew: true, agentTab: false) == "claude\n")
  #expect(AppStore.agentInput("claude", pane: "0", sessionIsNew: false, agentTab: false) == nil)
  #expect(AppStore.agentInput("claude", pane: "ab12cd", sessionIsNew: true, agentTab: false) == nil)
  #expect(AppStore.agentInput("claude", pane: "ab12cd", sessionIsNew: true, agentTab: true) == "claude\n")
  #expect(AppStore.agentInput("  ", pane: "0", sessionIsNew: true, agentTab: false) == nil)
}
