import Testing

@testable import Yatty

@Test func directoryNameSanitizesBranch() {
  #expect(Git.directoryName(for: "feature/login page") == "feature-login-page")
  #expect(Git.directoryName(for: "///") == "worktree")
}
