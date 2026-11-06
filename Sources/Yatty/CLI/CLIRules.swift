import Foundation
import YattyProtocol

/// The rules behind the `yatty` CLI's requests, apart from the app so tests
/// can hold them to their word.
enum CLIRules {
  /// What a request on the sandbox's socket may not do, as the message it
  /// fails with; nil when it may go ahead. `targetSandboxed`: the pane it
  /// types into was started in the sandbox.
  static func refusal(
    _ request: CLIRequest, sandboxed: Bool, sandboxCommand: String?, targetSandboxed: Bool
  ) -> String? {
    guard sandboxed else { return nil }
    switch request.op {
    case .tabNew, .diff:
      if sandboxPrefix(sandboxCommand) == nil {
        return "Yatty starts nothing for a sandboxed agent until `sandboxCommand` in "
          + "~/.config/yatty/config.json names the sandbox to start it in (e.g. \"fence --\")"
      }
      return nil
    case .tabSend:
      if !targetSandboxed {
        return "from a sandbox, Yatty types only into tabs opened from one (yatty tab new): "
          + "typed here, it would run outside the sandbox"
      }
      return nil
    case .tabList, .tabRead, .tabSelect, .tabRename, .tabClose, .notify, .status:
      return nil
    }
  }

  static func sandboxPrefix(_ command: String?) -> String? {
    guard let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
  }

  /// The argv that runs `program` in the sandbox: `prefix` (read by /bin/sh)
  /// in front of it, started at the worktree, which is what the sandbox's
  /// "." then means. Only inside it does it move to `cwd`, so an agent's
  /// `--cwd` never widens the sandbox.
  static func sandboxArgv(prefix: String, program: [String], cwd: String? = nil) -> [String] {
    let inside = cwd.map { ["/bin/sh", "-c", #"cd -- "$1" && shift && exec "$@""#, "sh", $0] + program } ?? program
    return ["/bin/sh", "-c", #"exec \#(prefix) "$@""#, "sh"] + inside
  }

  /// The tab `ref` names: its number (1 = first), else its title.
  static func tabIndex(_ ref: String, titles: [String]) -> Int? {
    if let n = Int(ref), n >= 1, n <= titles.count, ref.allSatisfy(\.isNumber) { return n - 1 }
    return titles.firstIndex(of: ref)
  }

  /// Why a new tab can't take `name`: a tab already has it. A second "dev"
  /// tab would be a second dev server.
  static func nameClash(_ name: String?, titles: [String]) -> String? {
    guard let name, !name.isEmpty, let clash = titles.firstIndex(of: name) else { return nil }
    return "a tab named \"\(name)\" is already open (\(clash + 1)); use it, or close it first"
  }

  /// Why `name` can't name a tab: blank, or a number, which TAB would read
  /// as a position.
  static func badName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "a tab name can't be blank" }
    if trimmed.allSatisfy(\.isNumber) { return "a tab name can't be a number: numbers name tabs by position" }
    return nil
  }

  static func noTab(_ ref: String, titles: [String]) -> String {
    "no tab \"\(ref)\"; tabs: " + titles.enumerated().map { "\($0.offset + 1):\($0.element)" }.joined(separator: ", ")
  }

  /// What `tab new -- COMMAND...` types: one word is a command line of its
  /// own (pipes and all, as typed); more are quoted word by word.
  static func commandLine(_ words: [String]) -> String? {
    switch words.count {
    case 0: nil
    case 1: words[0]
    default: words.map(portableQuote).joined(separator: " ")
    }
  }

  /// A word quoted to mean itself in sh, bash, zsh and fish alike: it's typed
  /// into the user's login shell, whichever that is. Inside single quotes
  /// fish reads `\\` and `\'` as escapes and sh doesn't, so backslashes and
  /// quotes go outside them, escaped, where both read them the same.
  static func portableQuote(_ word: String) -> String {
    if word.isEmpty { return "''" }
    var out = ""
    var quoted = false
    for character in word {
      if character == "'" || character == "\\" {
        if quoted { out += "'" }
        quoted = false
        out += "\\" + String(character)
      } else {
        if !quoted { out += "'" }
        quoted = true
        out.append(character)
      }
    }
    return quoted ? out + "'" : out
  }

  /// The last `count` lines of a terminal's history, without the blank
  /// screen below its prompt.
  static func lastLines(_ history: String, count: Int) -> String {
    // "\r\n" is one Character to Swift, so it's split on as such.
    var lines = history.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
    return lines.suffix(max(count, 0)).joined(separator: "\n")
  }

  /// A key named the way tmux names it, as the bytes a terminal sends.
  static func keyBytes(_ name: String) -> String? {
    let named: [String: String] = [
      "enter": "\r", "return": "\r", "tab": "\t", "btab": "\u{1b}[Z", "escape": "\u{1b}", "esc": "\u{1b}",
      "space": " ", "bspace": "\u{7f}", "backspace": "\u{7f}",
      "up": "\u{1b}[A", "down": "\u{1b}[B", "right": "\u{1b}[C", "left": "\u{1b}[D",
      "home": "\u{1b}[H", "end": "\u{1b}[F", "pageup": "\u{1b}[5~", "ppage": "\u{1b}[5~",
      "pagedown": "\u{1b}[6~", "npage": "\u{1b}[6~", "delete": "\u{1b}[3~", "dc": "\u{1b}[3~",
      "insert": "\u{1b}[2~", "ic": "\u{1b}[2~",
    ]
    if let bytes = named[name.lowercased()] { return bytes }
    if name.count == 1 { return name }
    let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
    guard parts.count == 2, let key = parts[1].first, parts[1].count == 1 || named[parts[1].lowercased()] != nil
    else { return nil }
    switch parts[0] {
    case "C", "c":
      guard parts[1].count == 1 else { return nil }
      let upper = key.uppercased()
      guard let scalar = upper.unicodeScalars.first, upper.unicodeScalars.count == 1,
        (0x40...0x5F).contains(scalar.value) || key == "?"
      else { return nil }
      return key == "?" ? "\u{7f}" : String(UnicodeScalar(UInt8(scalar.value & 0x1F)))
    case "M", "m":
      return keyBytes(parts[1]).map { "\u{1b}" + $0 }
    default:
      return nil
    }
  }

  /// What `tab send` types: the text, Enter unless told not to, then the keys.
  static func input(_ request: CLIRequest) -> Result<String, CLIError> {
    var input = request.text.joined(separator: " ")
    if !input.isEmpty && request.enter { input += "\r" }
    for key in request.keys {
      guard let bytes = keyBytes(key) else {
        return .failure(CLIError("unknown key \"\(key)\" (try C-c, Enter, Escape, Tab, Up, M-x…)"))
      }
      input += bytes
    }
    return .success(input)
  }

  /// A REF from a request, where git would take a leading "-" as an option.
  static func diffTarget(_ word: String, base: String) -> Result<DiffTarget, CLIError> {
    switch word {
    case "working": return .success(.working)
    case "staged": return .success(.staged)
    case "base":
      return base == "HEAD" ? .failure(CLIError("no base branch: the repository has no origin remote")) : .success(.base(base))
    default:
      if word.hasPrefix("-") || word.isEmpty { return .failure(CLIError("\"\(word)\" isn't a ref")) }
      return .success(.ref(word))
    }
  }
}

struct CLIError: Error, Equatable {
  let message: String
  init(_ message: String) { self.message = message }
}
