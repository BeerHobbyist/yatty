import SwiftUI
import Testing

@testable import Yatty

@Test func matchingFollowsAgentree() {
  #expect(CommandMatch.score("new", "New Worktree…") == 100)
  #expect(CommandMatch.score("work", "New Worktree…") == 80)
  #expect(CommandMatch.score("tree", "New Worktree…") == 60)
  #expect(CommandMatch.score("nwt", "New Worktree…") == 20)
  #expect(CommandMatch.score("xyz", "New Worktree…") == 0)
  #expect(CommandMatch.score("  ", "anything") == 1)
  #expect(CommandMatch.score("NEW", "new tab") == 100)
  // `_` continues a word, as agentree's \W has it.
  #expect(CommandMatch.score("tree", "git_tree") == 60)
  #expect(CommandMatch.score("tree", "git-tree") == 80)
}

@Test func filterRanksTitleOverGroup() {
  let commands = [
    Command(id: "a", title: "Merge Pull Request…", group: "Pull Request", run: {}),
    Command(id: "b", title: "Split Right", group: "Terminal", run: {}),
    Command(id: "c", title: "New Tab", group: "Terminal", run: {}),
    Command(id: "d", title: "Show Pull Request", group: "Pull Request", run: {}),
  ]
  #expect(CommandMatch.filter(commands, query: "").map(\.id) == ["a", "d", "b", "c"])
  // "pull" starts a word in two titles (80 × 2) and is the group's start (100).
  #expect(CommandMatch.filter(commands, query: "pull").map(\.id) == ["a", "d"])
  #expect(CommandMatch.filter(commands, query: "term").map(\.id) == ["b", "c"])
  #expect(CommandMatch.filter(commands, query: "split").map(\.id) == ["b"])
  #expect(CommandMatch.filter(commands, query: "zzz").isEmpty)
}

@Test func shortcutsLabelLikeMenus() {
  #expect(KeyboardShortcut("k").label == "⌘K")
  #expect(KeyboardShortcut("d", modifiers: [.command, .shift]).label == "⇧⌘D")
  #expect(KeyboardShortcut("=", modifiers: [.command, .control]).label == "⌃⌘=")
  #expect(KeyboardShortcut("t", modifiers: [.command, .option]).label == "⌥⌘T")
}

@Test func savingSettingsKeepsWhatItDoesntKnow() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("yatty-config-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: url) }
  try Data(#"{"agentCommand":"claude","futureKey":{"a":[1,2]},"sandboxCommand":"fence --"}"#.utf8).write(to: url)

  var settings = try JSONDecoder().decode(YattyConfig.self, from: Data(contentsOf: url))
  settings.agentCommand = ""
  settings.cloneDirectory = "  "
  settings.sandboxCommand = " "
  settings.notifications = false
  try ConfigFiles.saveConfig(settings, to: url)

  let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  #expect((saved["futureKey"] as? [String: Any])?["a"] as? [Int] == [1, 2])
  #expect(saved["agentCommand"] as? String == "")
  #expect(saved["cloneDirectory"] == nil)
  #expect(saved["sandboxCommand"] == nil)
  #expect(saved["notifications"] as? Bool == false)
  let reloaded = try JSONDecoder().decode(YattyConfig.self, from: Data(contentsOf: url))
  #expect(reloaded.cloneDirectory == YattyConfig().cloneDirectory)
  #expect(reloaded.sandboxCommand == nil)
}

/// The menus and the palette ask these same rules.
@Test func commandsApplyWhereTheMenusDo() {
  let main = Worktree(path: "/r", branch: "main", head: nil, isMain: true)
  let feature = Worktree(path: "/r/.worktrees/f", branch: "f", head: nil, isMain: false)
  let remote = Worktree(path: "/srv/app", branch: nil, head: nil, isMain: false, host: "box")

  let none = CommandContext(selected: nil, hasRepos: true, openPullRequest: false)
  #expect(none.canNewWorktree && !none.canCloseWorktree && !none.hasTerminals && !none.canDiff && !none.canMerge)

  let onMain = CommandContext(selected: main, hasRepos: true, openPullRequest: false)
  #expect(onMain.canNewWorktree && !onMain.canCloseWorktree && onMain.canDiff && onMain.canShowPullRequest)
  #expect(!onMain.canMerge)

  let onFeature = CommandContext(selected: feature, hasRepos: true, openPullRequest: true)
  #expect(onFeature.canCloseWorktree && onFeature.canMerge)

  let onRemote = CommandContext(selected: remote, hasRepos: true, openPullRequest: true)
  #expect(!onRemote.canNewWorktree && onRemote.canCloseWorktree && onRemote.hasTerminals)
  #expect(!onRemote.canDiff && !onRemote.canShowPullRequest && !onRemote.canMerge)

  #expect(!CommandContext(selected: nil, hasRepos: false, openPullRequest: false).canNewWorktree)
}

/// What applies live is what the file says: a cleared clone folder is the
/// default one (never "/"), a blank sandbox command is none.
@Test func settingsApplyAsSaved() throws {
  var settings = YattyConfig()
  settings.cloneDirectory = "  "
  settings.sandboxCommand = " fence -- "
  let normalized = settings.normalized
  #expect(normalized.cloneDirectory == YattyConfig().cloneDirectory)
  #expect(normalized.cloneRoot.path != "/")
  #expect(normalized.sandboxCommand == "fence --")
  settings.sandboxCommand = "   "
  #expect(settings.normalized.sandboxCommand == nil)

  // One value of the wrong type doesn't reset the others.
  let decoded = try JSONDecoder().decode(
    YattyConfig.self, from: Data(#"{"agentCommand":"claude","notifications":"yes","cloneDirectory":"~/src"}"#.utf8))
  #expect(decoded.agentCommand == "claude" && decoded.cloneDirectory == "~/src" && decoded.notifications)
}

@Test func unreadableConfigIsKeptAside() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yatty-cfg-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("config.json")
  try Data("{ not json".utf8).write(to: url)
  try ConfigFiles.saveConfig(YattyConfig(), to: url)
  #expect(try String(contentsOf: dir.appendingPathComponent("config.unreadable.json"), encoding: .utf8) == "{ not json")
  #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["agentCommand"] != nil)
}
