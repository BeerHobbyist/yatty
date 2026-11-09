import Foundation

/// Where a name is declared, found by searching the worktree (`git grep`)
/// instead of a language server, which would run the repository's own code
/// (its build files, its plugins) outside any sandbox.
enum CodeDefinitions {
  struct Hit: Equatable, Sendable {
    var path: String
    var line: Int
    var text: String
  }

  /// A name worth looking for: an identifier, nothing a search could take
  /// for an option or a pattern.
  static func isName(_ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    guard let first = scalars.first, scalars.count <= 100 else { return false }
    func word(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$") }
    return word(first) && !CharacterSet.decimalDigits.contains(first) && scalars.allSatisfy(word)
  }

  /// Declarations of `name`, best first. Written for both `git grep -E` and
  /// NSRegularExpression: no backslashes inside brackets.
  static func patterns(_ name: String) -> [String] {
    let n = name.replacingOccurrences(of: "$", with: "\\$")
    let keywords =
      "func|fun|fn|def|function|class|struct|enum|protocol|extension|actor|typealias|interface|type|trait|impl"
      + "|mixin|module|object|record|let|var|val|const|final|late|case|macro|namespace|typedef"
    return [
      // `func name`, `class Name`, `final Widget name`, `export function name`…
      "(^|[^A-Za-z0-9_$.])(\(keywords))[[:space:]]+([A-Za-z0-9_$.<>?]+[[:space:]]+)*\(n)([^A-Za-z0-9_$]|$)",
      // Go's methods: `func (r *T) name(`.
      "(^|[^A-Za-z0-9_$.])func[[:space:]]*\\([^)]*\\)[[:space:]]*\(n)[[:space:]]*[(<]",
      // Typed methods (Dart, Java, C#, TypeScript): `Future<Session> name(`.
      "^[[:space:]]*(@?[A-Za-z_][A-Za-z0-9_<>,?.]*[[:space:]]+)+\(n)[[:space:]]*(<[^>]*>)?[[:space:]]*\\(",
      // Bare methods and assigned functions: `name() {`, `name = async (`.
      "^[[:space:]]*((async|static|public|private|protected|readonly|override|get|set)[[:space:]]+)*\(n)[[:space:]]*"
        + "(\\([^;]*\\)[[:space:]]*(async[[:space:]]*)?(:[^=;]*)?(\\{|=>)|[:=][[:space:]]*(async[[:space:]]*)?(\\(|function))",
    ]
  }

  /// What `git grep` runs, in the worktree.
  static func grepArguments(_ name: String) -> [String] {
    ["grep", "-n", "-z", "-I", "-E", "--untracked", "--max-count=20"]
      + patterns(name).flatMap { ["-e", $0] } + ["--", "."]
  }

  /// Words a typed-method match starting with them is really a statement.
  private static let statements: Set<String> = [
    "return", "await", "new", "throw", "else", "yield", "if", "while", "for", "switch", "try", "do", "in", "of", "is",
    "as", "not", "and", "or", "echo", "print", "puts", "assert", "defer", "guard", "go", "typeof", "delete", "sizeof",
  ]

  /// The declarations in `git grep -n -z` output (path NUL line NUL text),
  /// best first: by kind of declaration, then those in `file`.
  static func hits(_ output: String, name: String, from file: String?, limit: Int = 50) -> [Hit] {
    let regexes = patterns(name).compactMap { try? NSRegularExpression(pattern: $0) }
    var ranked: [(kind: Int, hit: Hit)] = []
    for record in output.split(separator: "\n") {
      let fields = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count == 3, let line = Int(fields[1]) else { continue }
      let text = String(fields[2])
      let range = NSRange(text.startIndex..., in: text)
      guard let kind = regexes.firstIndex(where: { $0.firstMatch(in: text, range: range) != nil }) else { continue }
      if kind == 2, let first = text.split(whereSeparator: \.isWhitespace).first, statements.contains(String(first)) {
        continue
      }
      ranked.append((kind, Hit(path: String(fields[0]), line: line, text: text)))
    }
    return ranked.sorted { a, b in
      if a.kind != b.kind { return a.kind < b.kind }
      let aHere = a.hit.path == file, bHere = b.hit.path == file
      if aHere != bHere { return aHere }
      return (a.hit.path, a.hit.line) < (b.hit.path, b.hit.line)
    }.prefix(limit).map(\.hit)
  }
}

/// ⌘P: files by a few typed letters, the file's own name counting most.
enum QuickOpen {
  static func rank(_ query: String, _ files: [String], limit: Int = 50) -> [String] {
    guard !query.isEmpty else { return Array(files.prefix(limit)) }
    let wanted = Array(query.lowercased())
    let scored = files.compactMap { file in score(wanted, file).map { (score: $0, file: file) } }
    return scored.sorted { a, b in
      if a.score != b.score { return a.score > b.score }
      if a.file.count != b.file.count { return a.file.count < b.file.count }
      return a.file < b.file
    }.prefix(limit).map(\.file)
  }

  private static func score(_ wanted: [Character], _ file: String) -> Int? {
    let name = file.split(separator: "/").last.map(String.init) ?? file
    if !wanted.contains("/"), let inName = match(wanted, in: name) {
      return 1000 + inName + (name.lowercased().hasPrefix(String(wanted)) ? 500 : 0) - name.count
    }
    return match(wanted, in: file).map { 100 + $0 - file.count }
  }

  /// The letters in order: points for each that follows the last one, and
  /// for each at the start of a word (after / . _ - or a capital).
  private static func match(_ wanted: [Character], in text: String) -> Int? {
    let original = Array(text)
    let lower = Array(text.lowercased())
    guard lower.count == original.count else { return nil }
    var points = 0
    var index = 0
    var last = -2
    for character in wanted {
      while index < lower.count, lower[index] != character { index += 1 }
      guard index < lower.count else { return nil }
      if index == last + 1 { points += 10 }
      let previous: Character? = index > 0 ? original[index - 1] : nil
      if previous == nil || "/._- ".contains(previous!) || (original[index].isUppercase && previous!.isLowercase) {
        points += 15
      }
      last = index
      index += 1
    }
    return points
  }
}

/// A file changed since the code view's base.
struct CodeChange: Equatable, Sendable {
  var path: String
  /// git's letter: M, A, D, R…
  var status: String
}

enum CodeChanges {
  /// From `git diff --name-status -z` and `git ls-files --others -z`.
  static func parse(nameStatus: String, untracked: String) -> [CodeChange] {
    var changes: [CodeChange] = []
    var fields = nameStatus.split(separator: "\0").map(String.init)[...]
    while let status = fields.popFirst() {
      let letter = String(status.prefix(1))
      // A rename or copy names where it came from, then where it is.
      if letter == "R" || letter == "C" { _ = fields.popFirst() }
      guard let path = fields.popFirst() else { break }
      changes.append(CodeChange(path: path, status: letter))
    }
    for path in untracked.split(separator: "\0") where !changes.contains(where: { $0.path == path }) {
      changes.append(CodeChange(path: String(path), status: "A"))
    }
    return changes
  }
}

/// What the agent's terminal is sent: the comments as one paste, then Enter.
struct AgentInput: Equatable {
  var text: String
  var submit = "\r"

  /// A bracketed paste, so newlines don't submit early. Control characters
  /// go (the quoted code is the agent's), so nothing ends the paste early.
  static func paste(_ text: String) -> AgentInput {
    let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 && $0.value != 0x7f }))
    return AgentInput(text: "\u{1b}[200~" + clean + "\u{1b}[201~")
  }
}

enum CodeWatch {
  /// The changed paths inside the worktree at `root`, relative to it; none
  /// of git's own, nor any in the worktrees inside it (`excluding`, relative).
  static func relative(_ paths: [String], in root: String, excluding nested: [String] = []) -> [String] {
    var seen: [String] = []
    for path in paths where path.hasPrefix(root + "/") {
      let relative = String(path.dropFirst(root.count + 1))
      let parts = relative.split(separator: "/")
      guard !relative.isEmpty, !parts.contains(".git"), !seen.contains(relative),
        !nested.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") })
      else { continue }
      seen.append(relative)
    }
    return seen
  }
}
