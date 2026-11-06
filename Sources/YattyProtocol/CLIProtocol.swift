import Foundation

/// One request from the `yatty` CLI to the app: a JSON line over a Unix socket.
public struct CLIRequest: Codable, Equatable, Sendable {
  public enum Op: String, Codable, Sendable {
    case tabList = "tab.list"
    case tabNew = "tab.new"
    case tabRead = "tab.read"
    case tabSend = "tab.send"
    case tabSelect = "tab.select"
    case tabRename = "tab.rename"
    case tabClose = "tab.close"
    case diff
    case notify
    case status
  }

  public var op: Op
  /// The worktree it's about: `$YATTY_WORKTREE`, or `--worktree`.
  public var worktree: String?
  /// The zmx session of the pane asking (`$YATTY_PANE`), if any.
  public var pane: String?
  /// A tab's name or 1-based index.
  public var tab: String?
  public var name: String?
  public var select = false
  /// `tab new -- COMMAND...`
  public var command: [String] = []
  /// `tab new --cwd`: where its shell starts, inside the worktree.
  public var cwd: String?
  public var lines: Int?
  public var text: [String] = []
  /// `tab send`: Enter after the text, unless `--no-enter`.
  public var enter = true
  /// `--key C-c` and the like.
  public var keys: [String] = []
  /// `diff`'s target: working, staged, base, or a ref.
  public var target: String?
  public var json = false
  /// `notify --title`.
  public var title: String?

  public init(op: Op) { self.op = op }
}

public struct CLIResponse: Codable, Equatable, Sendable {
  public var ok: Bool
  public var output: String
  public var error: String?

  public init(ok: Bool, output: String = "", error: String? = nil) {
    self.ok = ok
    self.output = output
    self.error = error
  }

  public static func failure(_ message: String) -> CLIResponse { CLIResponse(ok: false, error: message) }
}

public enum CLIPaths {
  /// `~/.local/state/yatty`, or `$YATTY_STATE_DIR` (tests).
  /// The app hands its own to every terminal, so a test instance's CLI finds it.
  public static func directory(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let dir = env["YATTY_STATE_DIR"], dir.hasPrefix("/") { return URL(fileURLWithPath: dir) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/yatty")
  }

  /// Everything; never allowed in fence.
  public static func appSocket(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    directory(env).appendingPathComponent("app.sock").path
  }

  /// The sandbox's terms; the only socket a fenced agent may reach.
  public static func sandboxSocket(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    directory(env).appendingPathComponent("sandbox.sock").path
  }
}

public enum CLIUsage {
  public static let text = """
    usage: yatty <command>

      tab list [--json]                       this worktree's tabs
      tab new [--name N] [--select] [--cwd DIR] [--json] [-- COMMAND...]
                                              open a shell tab (in the background unless
                                              --select) and type COMMAND into it; prints
                                              its number
      tab read TAB [--lines N]                what TAB shows (its last N lines; 50)
      tab send TAB TEXT... [--no-enter] [--key KEY]...
                                              type TEXT into TAB, then Enter; KEY presses
                                              a key (C-c, Enter, Escape, Up, Tab…)
      tab select TAB                          show TAB
      tab rename TAB NAME
      tab close TAB
      diff [working|staged|base|REF]          open a diff in a tab of its own
      notify MESSAGE... [--title T]           a notification for the user
      status [--json]                         every worktree and its agent's state
      skill install|uninstall|show            the Claude Code skill that teaches agents this

    TAB is a tab's number (1 = first) or name. --worktree PATH acts on another
    worktree's tabs. Inside fence ($FENCE_SANDBOX) what it starts runs in the
    sandbox (`sandboxCommand` in Yatty's config.json), and tab send types only
    into tabs opened that way.

    examples:
      yatty tab new --name dev -- npm run dev
      yatty tab read dev --lines 30
      yatty tab send dev --key C-c
    """
}

public enum CLIArgumentError: Error, Equatable, CustomStringConvertible {
  case usage(String)
  public var description: String {
    switch self {
    case .usage(let message): message
    }
  }
}

/// `yatty` arguments as a request. `skill …` and `--help` are the CLI's own.
public enum CLIArguments {
  public static func parse(_ args: [String], env: [String: String]) throws -> CLIRequest {
    var words = args
    var worktree = env["YATTY_WORKTREE"].flatMap { $0.isEmpty ? nil : $0 }
    // After `--` it's the command's own.
    let end = words.firstIndex(of: "--") ?? words.endIndex
    if let index = words[..<end].firstIndex(of: "--worktree") {
      guard index + 1 < end else { throw CLIArgumentError.usage("--worktree needs a path") }
      worktree = words[index + 1]
      words.removeSubrange(index...(index + 1))
    }
    guard let first = words.first else { throw CLIArgumentError.usage(CLIUsage.text) }
    var request: CLIRequest
    switch first {
    case "tab":
      guard words.count >= 2 else { throw CLIArgumentError.usage("tab needs a subcommand: list, new, read, send, select, rename, close") }
      request = try parseTab(words[1], Array(words.dropFirst(2)))
    case "diff":
      guard words.count <= 2 else { throw CLIArgumentError.usage("diff takes one of working, staged, base or a REF") }
      request = CLIRequest(op: .diff)
      request.target = words.dropFirst().first ?? "working"
    case "notify":
      request = CLIRequest(op: .notify)
      var rest = words.dropFirst()
      if let index = rest.firstIndex(of: "--title") {
        guard index + 1 < rest.endIndex else { throw CLIArgumentError.usage("--title needs a title") }
        request.title = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
      }
      request.text = Array(rest)
      guard !request.text.joined().trimmingCharacters(in: .whitespaces).isEmpty else {
        throw CLIArgumentError.usage("notify needs a MESSAGE")
      }
    case "status":
      request = CLIRequest(op: .status)
      request.json = words.contains("--json")
    default:
      throw CLIArgumentError.usage("unknown command: \(first)\n\n" + CLIUsage.text)
    }
    request.worktree = worktree
    request.pane = env["YATTY_PANE"].flatMap { $0.isEmpty ? nil : $0 }
    guard request.worktree != nil else {
      throw CLIArgumentError.usage("not in a Yatty terminal: pass --worktree PATH")
    }
    return request
  }

  private static func parseTab(_ sub: String, _ rest: [String]) throws -> CLIRequest {
    switch sub {
    case "list":
      var request = CLIRequest(op: .tabList)
      request.json = rest.contains("--json")
      return request
    case "new":
      var request = CLIRequest(op: .tabNew)
      var words = rest[...]
      while let word = words.first {
        words = words.dropFirst()
        switch word {
        case "--": request.command = Array(words); return request
        case "--select": request.select = true
        case "--json": request.json = true
        case "--name", "--cwd":
          guard let value = words.first, !value.isEmpty else { throw CLIArgumentError.usage("\(word) needs a value") }
          if word == "--name" { request.name = value } else { request.cwd = value }
          words = words.dropFirst()
        default:
          throw CLIArgumentError.usage("tab new: unexpected \(word) (put the command after --)")
        }
      }
      return request
    case "read":
      var request = CLIRequest(op: .tabRead)
      var words = rest[...]
      while let word = words.first {
        words = words.dropFirst()
        if word == "--lines" {
          guard let n = words.first.flatMap({ Int($0) }), n > 0 else {
            throw CLIArgumentError.usage("--lines needs a positive number")
          }
          request.lines = n
          words = words.dropFirst()
        } else if request.tab == nil {
          request.tab = word
        } else {
          throw CLIArgumentError.usage("tab read: unexpected \(word)")
        }
      }
      guard request.tab != nil else { throw CLIArgumentError.usage("tab read needs a TAB") }
      return request
    case "send":
      var request = CLIRequest(op: .tabSend)
      var words = rest[...]
      guard let tab = words.first else { throw CLIArgumentError.usage("tab send needs a TAB") }
      request.tab = tab
      words = words.dropFirst()
      while let word = words.first {
        words = words.dropFirst()
        if word == "--key" {
          guard let key = words.first else { throw CLIArgumentError.usage("--key needs a key") }
          request.keys.append(key)
          words = words.dropFirst()
        } else if word == "--no-enter" {
          request.enter = false
        } else if word == "--" {
          request.text += words
          words = []
        } else {
          request.text.append(word)
        }
      }
      guard !request.text.isEmpty || !request.keys.isEmpty else {
        throw CLIArgumentError.usage("tab send needs TEXT or --key KEY")
      }
      return request
    case "select", "close":
      guard let tab = rest.first else { throw CLIArgumentError.usage("tab \(sub) needs a TAB") }
      guard rest.count == 1 else { throw CLIArgumentError.usage("tab \(sub) takes one TAB") }
      var request = CLIRequest(op: sub == "select" ? .tabSelect : .tabClose)
      request.tab = tab
      return request
    case "rename":
      let name = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
      guard rest.count >= 2, !name.isEmpty else { throw CLIArgumentError.usage("tab rename needs a TAB and a NAME") }
      var request = CLIRequest(op: .tabRename)
      request.tab = rest[0]
      request.name = name
      return request
    default:
      throw CLIArgumentError.usage("unknown tab subcommand: \(sub)")
    }
  }
}
