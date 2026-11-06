import Foundation
import Testing

@testable import Yatty

private func repo(_ nameWithOwner: String) -> RemoteRepo {
  RemoteRepo(
    name: String(nameWithOwner.split(separator: "/").last!), nameWithOwner: nameWithOwner,
    description: nil, isPrivate: false)
}

@Test func rankingOrdersByMatchQuality() {
  let repos = ["acme/tooling-api", "me/api", "acme/apiary", "api-org/web", "me/other"].map(repo)
  #expect(RemoteRepo.ranked(repos, query: "api").map(\.nameWithOwner) == [
    "me/api", "acme/apiary", "acme/tooling-api", "api-org/web",
  ])
  #expect(RemoteRepo.ranked(repos, query: "  API ").map(\.nameWithOwner).first == "me/api")
}

@Test func rankingKeepsOrderForEmptyQuery() {
  let repos = ["b/one", "a/two", "c/three"].map(repo)
  #expect(RemoteRepo.ranked(repos, query: "") == repos)
}

@Test func slugFromEveryRemoteForm() {
  #expect(Git.slug(fromRemote: "git@github.com:Owner/Repo.git") == "Owner/Repo")
  #expect(Git.slug(fromRemote: "https://github.com/owner/repo") == "owner/repo")
  #expect(Git.slug(fromRemote: "https://github.com/owner/repo.git/") == "owner/repo")
  #expect(Git.slug(fromRemote: "ssh://git@github.com/owner/repo.git") == "owner/repo")
  #expect(Git.slug(fromRemote: "https://gitlab.com/owner/repo") == nil)
  #expect(Git.slug(fromRemote: "/local/path/repo") == nil)
}

@Test func remoteMatchesIgnoresCase() {
  #expect(Git.remoteMatches("git@github.com:Owner/Repo.git", nameWithOwner: "owner/repo"))
  #expect(!Git.remoteMatches("git@github.com:other/repo.git", nameWithOwner: "owner/repo"))
}

@Test func branchesSkipRemoteHead() {
  let refs = "refs/heads/main\nrefs/remotes/origin/HEAD\nrefs/remotes/origin/main\nrefs/heads/feature/x\n"
  #expect(Git.parseBranches(refs, current: "main") == Branches(
    current: "main", local: ["main", "feature/x"], remote: ["origin/main"]))
}

@Test func errorMessagesForMissingAndLoggedOutGh() {
  let missing = ProcessResult(status: 127, stdout: "", stderr: "env: gh: No such file or directory")
  #expect(GitHub.errorMessage(for: missing).contains("brew install gh"))
  let loggedOut = ProcessResult(
    status: 4, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login")
  #expect(GitHub.errorMessage(for: loggedOut).contains("gh auth login"))
  let other = ProcessResult(status: 1, stdout: "", stderr: "  HTTP 502\n")
  #expect(GitHub.errorMessage(for: other) == "HTTP 502")
}

@Test func repoJSONDecodes() throws {
  let json = #"""
    [{"name":"api","full_name":"me/api","description":null,"private":true,"stargazers_count":1},
     {"name":"web","full_name":"acme/web","description":"Site","private":false}]
    """#
  let repos = try JSONDecoder().decode([RemoteRepo].self, from: Data(json.utf8))
  #expect(repos == [
    RemoteRepo(name: "api", nameWithOwner: "me/api", description: nil, isPrivate: true),
    RemoteRepo(name: "web", nameWithOwner: "acme/web", description: "Site", isPrivate: false),
  ])
}

@Test func prJSONDecodes() throws {
  let json = #"""
    [{"number":42,"title":"Login","headRefName":"feature/login","isCrossRepository":true,
      "author":{"login":"octo","name":"Octo"}}]
    """#
  let prs = try JSONDecoder().decode([OpenPullRequest].self, from: Data(json.utf8))
  #expect(prs.first?.number == 42)
  #expect(prs.first?.author.login == "octo")
  #expect(prs.first?.isCrossRepository == true)
}
