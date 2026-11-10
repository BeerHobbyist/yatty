import AppKit
import SwiftUI

/// The keys the menus give their commands: one table, so the palette and the
/// help window show exactly what the menus do.
enum Shortcuts {
  static let newWorktree = KeyboardShortcut("n")
  static let addRepository = KeyboardShortcut("o")
  static let addHost = KeyboardShortcut("o", modifiers: [.command, .shift])
  static let showPullRequest = KeyboardShortcut("p", modifiers: [.command, .option])
  static let refresh = KeyboardShortcut("r")
  static let palette = KeyboardShortcut("p", modifiers: [.command, .shift])
  static let help = KeyboardShortcut("?")
  static let settings = KeyboardShortcut(",")
  static let nextAgent = KeyboardShortcut("j", modifiers: [.command, .shift])
  static let newTab = KeyboardShortcut("t")
  static let newAgentTab = KeyboardShortcut("t", modifiers: [.command, .option])
  static let openDiff = KeyboardShortcut("d", modifiers: [.command, .option])
  static let showCode = KeyboardShortcut("e")
  static let goToFile = KeyboardShortcut("p")
  static let nextChangedFile = KeyboardShortcut("]", modifiers: [.command, .option])
  static let previousChangedFile = KeyboardShortcut("[", modifiers: [.command, .option])
  static let splitRight = KeyboardShortcut("d")
  static let splitDown = KeyboardShortcut("d", modifiers: [.command, .shift])
  static let equalize = KeyboardShortcut("=", modifiers: [.command, .control])
  static let nextPane = KeyboardShortcut("]")
  static let previousPane = KeyboardShortcut("[")
  static let nextTab = KeyboardShortcut("]", modifiers: [.command, .shift])
  static let previousTab = KeyboardShortcut("[", modifiers: [.command, .shift])
  static let closePane = KeyboardShortcut("w")
  static let closeTab = KeyboardShortcut("w", modifiers: [.command, .option])
  /// Not ⌘F: Ghostty searches the terminal with it.
  static let filterWorktrees = KeyboardShortcut("f", modifiers: [.command, .option])
}

/// When a command applies. The menus and the palette ask the same rules, so
/// the palette never offers what a menu would refuse.
struct CommandContext {
  var selected: Worktree?
  var hasRepos: Bool
  /// The selected worktree's pull request is open (not merged).
  var openPullRequest: Bool
  /// The selected worktree has a pull request, open or merged.
  var hasPullRequest = false
  /// The selected worktree's front tab shows a diff: nothing to split there.
  var showingDiffTab = false
  /// Its pull request has failed checks from GitHub Actions runs.
  var hasFailedRuns = false
  /// The front tab shows its code beside the terminals.
  var showingCode = false

  /// A worktree here, with git: diffs and pull requests apply.
  var isLocal: Bool { selected.map { !$0.isRemote } ?? false }
  /// A remote directory isn't a repository's: no repo to offer.
  var canNewWorktree: Bool { hasRepos && selected?.isRemote != true }
  var canCloseWorktree: Bool { selected.map { !$0.isMain } ?? false }
  var hasTerminals: Bool { selected != nil }
  /// Splits and moving between panes: a terminal tab in front.
  var canSplit: Bool { hasTerminals && !showingDiffTab }
  var canDiff: Bool { isLocal }
  /// Code beside a terminal tab: its files are here.
  var canShowCode: Bool { isLocal && !showingDiffTab }
  var canGoToFile: Bool { canShowCode && showingCode }
  /// ⌘W closes the code before any terminal (see `CloseTarget`).
  var closeTitle: String { canShowCode && showingCode ? "Close Code" : "Close Pane" }
  var canShowPullRequest: Bool { isLocal }
  var canMerge: Bool { isLocal && openPullRequest }
  var canReviewComments: Bool { isLocal && hasPullRequest }
  var canRerunChecks: Bool { isLocal && hasFailedRuns }
}

extension AppStore {
  var commandContext: CommandContext {
    let badge = selectedWorktree.flatMap { pullRequests.badge(for: $0) }
    return CommandContext(
      selected: selectedWorktree, hasRepos: !repos.isEmpty, openPullRequest: badge.map { !$0.merged } ?? false,
      hasPullRequest: badge != nil,
      showingDiffTab: selectedWorktree.flatMap { layout(for: $0).selected?.diff } != nil,
      hasFailedRuns: selectedWorktree.flatMap { pullRequests.details[$0.id] }.map { !PullRequests.failedRuns($0).isEmpty }
        ?? false,
      showingCode: selectedWorktree.flatMap { layout(for: $0).selected?.code?.shown } == true)
  }

  /// Every command that applies now, in the palette's order.
  var commands: [Command] {
    let context = commandContext
    var list: [Command] = []
    func add(
      _ id: String, _ title: String, _ group: String, _ shortcut: KeyboardShortcut? = nil, detail: String? = nil,
      when applies: Bool = true, _ run: @escaping @MainActor () -> Void
    ) {
      if applies { list.append(Command(id: id, title: title, group: group, shortcut: shortcut, detail: detail, run: run)) }
    }
    let selected = context.selected
    let name = selected.map { label(for: $0) }

    add("worktree.new", "New Worktree…", "Worktree", Shortcuts.newWorktree, when: context.canNewWorktree) {
      self.newWorktreeForSelection()
    }
    if let selected {
      add(
        "worktree.close", selected.isRemote ? "Remove Directory…" : "Close Worktree…", "Worktree",
        detail: name, when: context.canCloseWorktree
      ) { self.requestClose(selected) }
    }
    if let selected {
      add("worktree.rename", "Rename…", "Worktree", detail: name) { self.renamingWorktree = selected }
      add("worktree.finder", "Open in Finder", "Worktree", detail: name, when: !selected.isRemote) {
        self.openInFinder(selected)
      }
      add("worktree.copyPath", "Copy Path", "Worktree", detail: name) { self.copyPath(selected) }
    }

    // Everything acts on what the palette showed: the worktree selected when
    // it opened, and the pane focused then.
    if let selected {
      let focused = layout(for: selected).selected.map { PaneKey(worktree: selected.id, pane: $0.focusedPane) }
      func onPane(_ command: TerminalCommand) -> @MainActor () -> Void {
        {
          if let focused { self.handle(command, from: focused) } else if case .newTab = command {
            self.newTab(in: selected, agent: false)
          }
        }
      }
      add("tab.new", "New Tab", "Terminal", Shortcuts.newTab, onPane(.newTab))
      add("tab.agent", "New Agent Tab", "Terminal", Shortcuts.newAgentTab) { self.newTab(in: selected, agent: true) }
      add("diff.open", "Open Diff…", "Terminal", Shortcuts.openDiff, when: context.canDiff) {
        self.diffingWorktree = selected
      }
      add("code.toggle", context.showingCode ? "Hide Code" : "Show Code", "Terminal", Shortcuts.showCode,
        detail: "The file the agent is changing, beside its terminal", when: context.canShowCode) {
        self.toggleCode(in: selected)
      }
      add("code.goto", "Go to File…", "Terminal", Shortcuts.goToFile, when: context.canGoToFile) {
        self.codeQuickOpen = self.layout(for: selected).selectedTab
      }
      add("code.next", "Next Changed File", "Terminal", Shortcuts.nextChangedFile, when: context.canGoToFile) {
        self.stepCodeFile(forward: true, in: selected)
      }
      add("code.previous", "Previous Changed File", "Terminal", Shortcuts.previousChangedFile,
        when: context.canGoToFile) {
        self.stepCodeFile(forward: false, in: selected)
      }
      add("split.right", "Split Right", "Terminal", Shortcuts.splitRight, when: context.canSplit,
        onPane(.split(.horizontal, newFirst: false)))
      add("split.down", "Split Down", "Terminal", Shortcuts.splitDown, when: context.canSplit,
        onPane(.split(.vertical, newFirst: false)))
      add("split.equalize", "Equalize Splits", "Terminal", Shortcuts.equalize, when: context.canSplit, onPane(.equalize))
      add("pane.next", "Next Pane", "Terminal", Shortcuts.nextPane, when: context.canSplit, onPane(.gotoSplit(.next)))
      add("pane.previous", "Previous Pane", "Terminal", Shortcuts.previousPane, when: context.canSplit,
        onPane(.gotoSplit(.previous)))
      add("tab.next", "Next Tab", "Terminal", Shortcuts.nextTab, onPane(.gotoTab(.next)))
      add("tab.previous", "Previous Tab", "Terminal", Shortcuts.previousTab, onPane(.gotoTab(.previous)))
      add("pane.close", context.closeTitle, "Terminal", Shortcuts.closePane) { self.performOnFocusedPane(.close) }
      add("tab.close", "Close Tab", "Terminal", Shortcuts.closeTab, onPane(.closeTab))
      // No key shown: ⌘1–9 are Ghostty's (and may be rebound there), not a menu's.
      for (index, tab) in layout(for: selected).tabs.enumerated() {
        add("tab.go.\(tab.id)", "Go to Tab \(index + 1)", "Terminal", detail: title(of: tab, in: selected)) {
          self.selectTab(tab.id, in: selected)
        }
      }
    }

    add("pr.show", "Show Pull Request", "Pull Request", Shortcuts.showPullRequest, when: context.canShowPullRequest) {
      self.showingPullRequest.toggle()
    }
    add("pr.refresh", "Refresh Pull Requests", "Pull Request", Shortcuts.refresh) { self.refreshPullRequests() }
    add("pr.merge", "Merge Pull Request…", "Pull Request", when: context.canMerge) {
      if let selected { self.mergeRequest = MergeRequest(worktree: selected, method: nil) }
    }
    add("pr.reviewComments", "Review Comments…", "Pull Request", when: context.canReviewComments) {
      self.reviewingComments = selected
    }
    if let selected {
      for tab in PullRequestTab.allCases {
        add("pr.tab.\(tab.rawValue)", "Show \(tab.title)", "Pull Request", when: context.canReviewComments) {
          self.showPullRequestTab(tab, for: selected)
        }
      }
      add("pr.open", "Open Pull Request on GitHub", "Pull Request", when: context.canReviewComments) {
        self.openPullRequest(selected)
      }
      add("pr.rerun", "Re-run Failed Checks", "Pull Request", when: context.canRerunChecks) {
        self.rerunFailedChecks(in: selected)
      }
    }

    add("agent.next", "Go to Next Agent", "Agents", Shortcuts.nextAgent) { self.jumpToNextAgent() }
    add(
      "agent.track", trackingEveryClaude ? "Stop Tracking Every Claude" : "Track Every Claude…", "Agents"
    ) {
      if self.trackingEveryClaude { self.setTracking(false) } else { self.confirmingTracking = true }
    }

    add("project.filter", "Filter Worktrees", "Projects", Shortcuts.filterWorktrees) { self.focusingFilter = true }
    add("project.repo", "Add Repository…", "Projects", Shortcuts.addRepository) { self.addingRepository = true }
    add("project.host", "Add SSH Host…", "Projects", Shortcuts.addHost) { self.addingHost = AddHostRequest() }
    if let selected, let project = projectID(of: selected.id) {
      add("project.up", "Move Project Up", "Projects") { self.shiftProject(project, by: -1) }
      add("project.down", "Move Project Down", "Projects") { self.shiftProject(project, by: 1) }
    }
    if let selected, let repo = repo(of: selected) {
      add("project.removeRepo", "Remove Repository…", "Projects", detail: repo.name) { self.pendingRemoval = repo }
    }
    if let selected, let host = host(of: selected) {
      add("project.removeHost", "Remove Host…", "Projects", detail: host.host) { self.pendingHostRemoval = host }
    }

    for repo in repos {
      for worktree in worktrees[repo.id] ?? [] where worktree.id != selection {
        add("go.\(worktree.id)", "Go to \(label(for: worktree))", "Go To", detail: repo.name) {
          self.selection = worktree.id
          self.focusSelectedTerminal()
        }
      }
    }
    for host in hosts {
      for worktree in host.worktrees where worktree.id != selection {
        add("go.\(worktree.id)", "Go to \(label(for: worktree))", "Go To", detail: host.host) {
          self.selection = worktree.id
          self.focusSelectedTerminal()
        }
      }
    }

    add("app.settings", "Settings…", "App", Shortcuts.settings) { self.openingSettings = true }
    add("app.help", "Keyboard Shortcuts", "App", Shortcuts.help) { self.showingHelp = true }
    return list
  }

  func openInFinder(_ worktree: Worktree) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
  }

  /// The path on the clipboard; `host:~/path` for a remote directory.
  func copyPath(_ worktree: Worktree) {
    let path = host(of: worktree).map { "\($0.host):" + SSH.displayPath(worktree.path, home: $0.home) } ?? worktree.path
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }

  /// The palette closed: run what was picked (sheets it opens need it gone
  /// first), or give the terminal its keyboard back.
  func paletteClosed() {
    if let command = pickedCommand {
      pickedCommand = nil
      command.run()
    } else {
      focusSelectedTerminal()
    }
  }
}
