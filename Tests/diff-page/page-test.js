// Loads Yatty's viewer.html in jsdom with the bundled diff2html, draws diffs,
// and drives the comment UI the way a user would.
const { JSDOM } = require("jsdom");
const fs = require("fs");
const dir = process.argv[2];
const html = fs.readFileSync(dir + "/viewer.html", "utf8")
  .replace(/<script src="([^"]+)"><\/script>/g,
    (_, file) => "<script>" + fs.readFileSync(dir + "/" + file, "utf8") + "</script>");
const posted = [];
const dom = new JSDOM(html, {
  runScripts: "dangerously",
  beforeParse(window) {
    window.webkit = { messageHandlers: { yatty: { postMessage: (m) => posted.push(m) } } };
    window.ResizeObserver = class { observe() {} };
    window.scrollTo = () => {};
  },
});
const w = dom.window, d = w.document;
let failures = 0;
const check = (ok, what) => { if (!ok) { failures++; console.log("FAIL:", what); } else console.log("ok:", what); };
const click = (node) => node.dispatchEvent(new w.MouseEvent("click", { bubbles: true }));
const button = (root, title) => [...root.querySelectorAll("button")].find((b) => b.textContent === title);
const wrappers = () => [...d.querySelectorAll(".d2h-file-wrapper")];
const shownTexts = () => [...d.querySelectorAll("tr.yatty-comment .yatty-text")].map((n) => n.textContent);
// The line a shown comment sits under: its row's new number, else its old one.
const lineUnder = (commentRow) => {
  let row = commentRow.previousElementSibling;
  while (row.classList.contains("yatty-row")) row = row.previousElementSibling;
  const cell = row.querySelector(".d2h-code-linenumber, .d2h-code-side-linenumber");
  return (cell.querySelector(".line-num2")?.textContent || cell.textContent).trim();
};
// Writes `text` in the box a click on `cell` opens, and saves it with ⌘↩.
const comment = (cell, text) => {
  posted.length = 0;
  click(cell);
  const area = d.querySelector(".yatty-box textarea");
  area.value = text;
  area.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true }));
  return posted.find((m) => m.type === "save");
};

const diff = `diff --git a/a.swift b/a.swift
--- a/a.swift
+++ b/a.swift
@@ -1,3 +1,3 @@
 let one = 1
-let two = 2
+let two = 22
 let three = 3
diff --git a/b.txt b/b.txt
--- /dev/null
+++ b/b.txt
@@ -0,0 +1 @@
+hello
`;

for (const layout of ["line-by-line", "side-by-side"]) {
  console.log("== " + layout);
  posted.length = 0;
  const count = w.yattyRender(diff, layout, [
    { id: "c1", path: "a.swift", line: 2, side: "new", code: "let two = 22", text: "Why 22?", outdated: false },
    { id: "c2", path: "a.swift", line: 2, side: "old", code: "let two = 2", text: "Was fine", outdated: false },
  ]);
  check(count === 2, "draws two files");
  check(shownTexts().includes("Why 22?") && shownTexts().includes("Was fine"), "shows both comments: " + JSON.stringify(shownTexts()));
  check(!posted.some((m) => m.type === "place"), "comments where they were aren't moved");
  if (layout === "side-by-side") {
    const halves = wrappers()[0].querySelectorAll(".d2h-file-side-diff tbody");
    check(halves[0].children.length === halves[1].children.length, "both halves keep the same number of rows");
    const placeholders = [...d.querySelectorAll(".d2h-emptyplaceholder")].filter((n) => n.matches(".d2h-code-side-linenumber"));
    check(placeholders.length > 0 && placeholders.every((n) => !n.classList.contains("yatty-line")),
      "an empty placeholder's number cell takes no comment");
  }
  // Click the new line 1 ("let one = 1", unchanged) and write a comment.
  const cells = [...d.querySelectorAll(".yatty-line")];
  check(cells.length > 0, "line numbers are clickable: " + cells.length);
  const target = layout === "side-by-side"
    ? wrappers()[0].querySelectorAll(".d2h-file-side-diff")[0].querySelector(".yatty-line")
    : cells[0];
  const save = comment(target, "  Rename this  ");
  check(save && save.path === "a.swift" && save.line === 1 && save.side === "new" && save.text === "Rename this",
    "⌘↩ saves path, line, side and text: " + JSON.stringify(save));
  check(save && save.code === "let one = 1", "it quotes the line: " + JSON.stringify(save && save.code));
  check(!d.querySelector(".yatty-box textarea"), "the box closes after saving");
  // Esc cancels without posting.
  posted.length = 0;
  click(cells[1]);
  d.querySelector(".yatty-box textarea").dispatchEvent(new w.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  check(posted.length === 0 && !d.querySelector(".yatty-box textarea"), "esc cancels");

  // Edit hides the comment while its box is open; any way out shows it again.
  const row = () => [...d.querySelectorAll("tr.yatty-comment")].find((r) => r.textContent.includes("Why 22?"));
  const hidden = () => row().style.display === "none" || (row().yattySpacer && row().yattySpacer.style.display === "none");
  click(button(row(), "Edit"));
  check(hidden(), "Edit hides the comment (and its spacer)");
  click(cells[0]);
  check(!hidden(), "opening another box shows it again");
  click(button(row(), "Edit"));
  posted.length = 0;
  button(d.querySelector(".yatty-box textarea").parentElement, "Save").click();
  check(!hidden() && posted.some((m) => m.type === "save" && m.id === "c1"), "saving it unchanged shows it again");

  // Delete on a shown comment.
  posted.length = 0;
  click(button(row(), "Delete"));
  check(posted.some((m) => m.type === "delete" && m.id === "c1"), "delete posts its id");
  // The app sends the comments back: only those show, rows stay aligned.
  w.yattySetComments([{ id: "c3", path: "b.txt", line: 1, side: "new", code: "hello", text: "New file?", outdated: false }]);
  check(JSON.stringify(shownTexts()) === JSON.stringify(["New file?"]), "comments are replaced: " + JSON.stringify(shownTexts()));
  if (layout === "side-by-side") {
    const halves = wrappers()[0].querySelectorAll(".d2h-file-side-diff tbody");
    check(halves[0].children.length === halves[1].children.length, "halves stay aligned after removing rows");
  }
  // Text goes in as text, never as HTML.
  w.yattySetComments([{ id: "x", path: "a.swift", line: 1, side: "new", code: "let one = 1", text: "<img src=x onerror=alert(1)>", outdated: false }]);
  check(!d.querySelector(".yatty-text img"), "comment text isn't HTML");
}

console.log("== paths");
// Each file's path is the one diff2html draws it under: CRLF lines, a removed
// "-- comment" line, a merge conflict, a name with a space, a quoted name.
const tricky = [
  "diff --git a/crlf.txt b/crlf.txt", "--- a/crlf.txt", "+++ b/crlf.txt", "@@ -1,2 +1,2 @@", "-one\r", "+uno\r", " two\r",
  "diff --git a/s.sql b/s.sql", "deleted file mode 100644", "--- a/s.sql", "+++ /dev/null", "@@ -1,2 +0,0 @@",
  "--- users table", "-select 1;",
  "diff --cc c.txt", "index 1,2..3", "--- a/c.txt", "+++ b/c.txt", "@@@ -1,1 -1,1 +1,1 @@@", "- a", " -b", "++c",
  "diff --git a/new file.txt b/new file.txt", "--- a/new file.txt\t", "+++ b/new file.txt\t", "@@ -1 +1 @@", "-a", "+b",
  'diff --git "a/q\\"uote.txt" "b/q\\"uote.txt"', '--- "a/q\\"uote.txt"', '+++ "b/q\\"uote.txt"', "@@ -1 +1 @@", "-x", "+y",
  "diff --git a/z.txt b/z.txt", "--- a/z.txt", "+++ b/z.txt", "@@ -1 +1 @@", "-a", "+b", "",
].join("\n");
check(w.yattyRender(tricky, "line-by-line", []) === 6, "draws six files");
const paths = wrappers().map((wrapper) => comment(wrapper.querySelector(".yatty-line"), "here")?.path);
check(JSON.stringify(paths) === JSON.stringify(["crlf.txt", "s.sql", "c.txt", "new file.txt", 'q"uote.txt', "z.txt"]),
  "comments get the path each file is drawn under: " + JSON.stringify(paths));

console.log("== the diff changes");
const before = `diff --git a/a.swift b/a.swift
--- a/a.swift
+++ b/a.swift
@@ -1,3 +1,3 @@
 let one = 1
-let two = 2
+let two = 22
 let three = 3
`;
const after = `diff --git a/a.swift b/a.swift
--- a/a.swift
+++ b/a.swift
@@ -1,3 +1,5 @@
+import Foundation
+
 let one = 1
-let two = 2
+let two = 22
 let three = 3
`;
const kept = [
  { id: "m", path: "a.swift", line: 2, side: "new", code: "let two = 22", text: "Moves", outdated: false },
  { id: "o", path: "a.swift", line: 1, side: "new", code: "let zero = 0", text: "Its line is gone", outdated: false },
  { id: "g", path: "gone.swift", line: 4, side: "old", code: "bye()", text: "Its file is gone", outdated: false },
];
for (const layout of ["line-by-line", "side-by-side"]) {
  posted.length = 0;
  w.yattyRender(before, layout, kept.slice(0, 1));
  check(!posted.some((m) => m.type === "place"), layout + ": a comment where it was isn't moved");
  posted.length = 0;
  w.yattyRender(after, layout, kept);
  const placed = posted.find((m) => m.type === "place");
  const anchors = Object.fromEntries((placed?.anchors ?? []).map((a) => [a.id, a]));
  check(anchors.m && anchors.m.line === 4 && !anchors.m.outdated, layout + ": a comment follows its line: " + JSON.stringify(anchors.m));
  const row = [...d.querySelectorAll("tr.yatty-comment")].find((r) => r.textContent.includes("Moves"));
  check(row && lineUnder(row) === "4", layout + ": and shows under it: " + (row && lineUnder(row)));
  check(anchors.o?.outdated && anchors.o.line === 1 && anchors.g?.outdated, layout + ": comments whose lines are gone are outdated");
  check(!shownTexts().includes("Its line is gone") && !shownTexts().includes("Its file is gone"),
    layout + ": an outdated comment sits under no line");
  const listed = [...d.querySelectorAll("#outdated .yatty-text")].map((n) => n.textContent);
  check(listed.includes("Its line is gone") && listed.includes("Its file is gone"), layout + ": outdated comments are listed: " + JSON.stringify(listed));
  check(d.querySelector("#outdated").textContent.includes("gone.swift:4"), layout + ": with where they were");
  posted.length = 0;
  w.yattySetComments([kept[0], { ...kept[1], outdated: true }, { ...kept[2], outdated: true }].map((c) => c.id === "m" ? { ...c, line: 4 } : c));
  check(!posted.some((m) => m.type === "place"), layout + ": once the app has them, nothing is posted again");
  click(button(d.querySelector("#outdated"), "Delete"));
  check(posted.some((m) => m.type === "delete" && m.id === "o"), layout + ": an outdated comment can be deleted");
}
w.yattySetComments([]);
check(d.querySelector("#outdated").children.length === 0, "no outdated comments, no list");

console.log("== a big new file");
// Under diff2html's 5000-change limit. Side by side, its left half is empty
// rows: 1500 lines once took over a minute here.
const big = ["diff --git a/big.txt b/big.txt", "new file mode 100644", "--- /dev/null", "+++ b/big.txt", "@@ -0,0 +1,4500 @@"];
for (let i = 1; i <= 4500; i++) big.push("+line " + i);
const start = Date.now();
w.yattyRender(big.join("\n") + "\n", "side-by-side", []);
const marking = Date.now() - start;
check(d.querySelectorAll(".yatty-line").length === 4500, "every line takes a comment: " + d.querySelectorAll(".yatty-line").length);
check(marking < 20000, "drawn in " + marking + " ms");

console.log(failures ? failures + " failure(s)" : "all passed");
process.exit(failures ? 1 : 0);
