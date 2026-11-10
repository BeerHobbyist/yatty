import CoreGraphics
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

/// A web page's picture goes where the page is in the window's: in the
/// picture's units, from the bottom left, whichever way the view counts.
@Test func webPicturesLandWhereThePageIs() {
  let bounds = CGSize(width: 1000, height: 600)
  let page = CGRect(x: 10, y: 20, width: 300, height: 400)
  #expect(Snapshot.drawingRect(of: page, in: bounds, flipped: false, scale: 2) == CGRect(x: 20, y: 40, width: 600, height: 800))
  #expect(Snapshot.drawingRect(of: page, in: bounds, flipped: true, scale: 2) == CGRect(x: 20, y: 360, width: 600, height: 800))
}
