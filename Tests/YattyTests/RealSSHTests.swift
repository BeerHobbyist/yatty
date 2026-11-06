import Foundation
import Testing

@testable import Yatty

/// Against a real sshd on 127.0.0.1, run by scripts/ssh-e2e.sh, which sets
/// `YATTY_SSH_E2E` to its directory (an `ssh` wrapper with its own config;
/// hosts `e2e`, a plain key, and `e2e-pp`, a key with a passphrase). The
/// script fails unless every one of these ran.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YATTY_SSH_E2E"] != nil))
struct RealSSHTests {
  let dir = ProcessInfo.processInfo.environment["YATTY_SSH_E2E"] ?? ""

  var setup: SSHSetup {
    SSHSetup(executable: dir + "/ssh", controlDirectory: dir + "/ctl")
  }

  /// sshd's log lines for logins it accepted.
  func logins() -> Int {
    ((try? String(contentsOfFile: dir + "/sshd.log", encoding: .utf8)) ?? "")
      .split(separator: "\n").filter { $0.contains("Accepted publickey") }.count
  }

  @Test func probeFindsTheDirectoryAndZmx() async throws {
    // The "remote" user is this one, whose home is the real one.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let found = try await SSH.probe(host: "e2e", path: dir + "/home/we ird 'dir'", setup: setup).get()
    #expect(found.path == dir + "/home/we ird 'dir'")
    #expect(found.home == home)
    #expect(found.zmx == dir + "/bin/zmx")
    #expect(try await SSH.probe(host: "e2e", path: "~", setup: setup).get().path == home)
    #expect(await SSH.probe(host: "e2e", path: "~/nope", setup: setup)
      == .failure(.failed("~/nope doesn't exist on e2e, or isn't a directory.")))
  }

  @Test func passphraseLogsInOnceThroughAskpass() async throws {
    guard case .failure(.needsPassword) = await SSH.probe(host: "e2e-pp", path: "~", setup: setup) else {
      Issue.record("a key with a passphrase should ask for it")
      return
    }
    guard case .failure(.needsPassword) = await SSH.probe(host: "e2e-pp", path: "~", password: "wrong", setup: setup) else {
      Issue.record("a wrong passphrase should ask again")
      return
    }
    let host = SSHHost(host: "e2e-pp", home: "", zmx: "", needsPassword: true)
    #expect(await SSH.run(on: host, "true", setup: setup) == nil)

    _ = try await SSH.probe(host: "e2e-pp", path: "~", password: "pass phrase", setup: setup).get()
    #expect(await SSH.isConnected(host: "e2e-pp", setup: setup))
    let before = logins()
    // Over the shared connection: no new login.
    #expect(await SSH.run(on: host, "true", setup: setup)?.ok == true)
    #expect(logins() == before)
  }
}
