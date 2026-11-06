import Testing

@testable import Yatty

@Test func canonicalPathKeepsPrivatePrefix() {
  #expect(canonicalPath("/tmp") == "/private/tmp")
  #expect(canonicalPath("/no/such/dir/x") == "/no/such/dir/x")
}

@Test func directoryNameSanitizesBranch() {
  #expect(Git.directoryName(for: "feature/login page") == "feature-login-page")
  #expect(Git.directoryName(for: "///") == "worktree")
}

@Test func middleTruncationKeepsBothEnds() {
  #expect(middleTruncated("short", to: 24) == "short")
  #expect(middleTruncated("abcdefghijklmnopqrstuvwxyz0123", to: 11) == "abcde…z0123")
}
