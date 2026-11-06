import Testing

@testable import Yatty

@Test func porcelainCountsLines() {
  #expect(Git.parsePorcelainCount(" M a.swift\n?? new.txt\nR  old -> new\n") == 3)
  #expect(Git.parsePorcelainCount("") == 0)
}

@Test func numstatSkipsBinaryFiles() {
  let numstat = "10\t2\tSources/a.swift\n-\t-\tlogo.png\n3\t0\tREADME.md\n"
  let totals = Git.parseNumstat(numstat)
  #expect(totals.added == 13)
  #expect(totals.removed == 2)
}

@Test func aheadBehindParses() {
  let counts = Git.parseAheadBehind("4\t1\n")
  #expect(counts.behind == 4)
  #expect(counts.ahead == 1)
  #expect(Git.parseAheadBehind("garbage").ahead == 0)
}
