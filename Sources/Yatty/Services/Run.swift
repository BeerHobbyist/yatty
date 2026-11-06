import Foundation

struct ProcessResult: Sendable {
  let status: Int32
  let stdout: String
  let stderr: String

  var ok: Bool { status == 0 }
}

/// Runs programs the way a shell would find them. An app opened from Finder
/// gets launchd's minimal PATH, so Homebrew's directories are added.
enum Run {
  static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  static func run(
    _ executable: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:]
  ) async -> ProcessResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: runSync(executable, args, cwd: cwd, env: env))
      }
    }
  }

  static func runSync(
    _ executable: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:]
  ) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = searchPath
    environment.merge(env) { _, new in new }
    process.environment = environment

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
    }

    // Read stderr alongside stdout so neither pipe fills up and stalls the child.
    let errData = DataBox()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      errData.data = err.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()

    return ProcessResult(
      status: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData.data, as: UTF8.self))
  }
}

private final class DataBox: @unchecked Sendable {
  var data = Data()
}

/// Quotes a string for /bin/sh.
func shellQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A path with symlinks resolved, as git reports worktree paths. `realpath`,
/// not Foundation's resolver: that one strips a leading /private, which git
/// keeps (/private/tmp, /private/var/folders).
func canonicalPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else {
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }
  defer { free(resolved) }
  return String(cString: resolved)
}
