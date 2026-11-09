// Loads Yatty's viewer.html in jsdom with the bundled diff2html, draws a diff,
// and drives the comment UI the way a user would.
const { JSDOM } = require("jsdom");
const fs = require("fs");
const dir = process.argv[2];
const html = fs.readFileSync(dir + "/viewer.html", "utf8")
  .replace('<script src="diff2html-ui-slim.min.js"></script>',
    () => "<script>" + fs.readFileSync(dir + "/diff2html-ui-slim.min.js", "utf8") + "</script>");
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
let failures = 0;
const check = (ok, what) => { if (!ok) { failures++; console.log("FAIL:", what); } else console.log("ok:", what); };

for (const layout of ["line-by-line", "side-by-side"]) {
  console.log("== " + layout);
  posted.length = 0;
  const count = w.yattyRender(diff, layout, ["a.swift", "b.txt"], [
    { id: "c1", path: "a.swift", line: 2, side: "new", code: "let two = 22", text: "Why 22?" },
    { id: "c2", path: "a.swift", line: 2, side: "old", code: "let two = 2", text: "Was fine" },
  ]);
  check(count === 2, "draws two files");
  const shown = [...d.querySelectorAll("tr.yatty-comment .yatty-text")].map((n) => n.textContent);
  check(shown.includes("Why 22?") && shown.includes("Was fine"), "shows both comments: " + JSON.stringify(shown));
  if (layout === "side-by-side") {
    const halves = d.querySelectorAll(".d2h-file-wrapper")[0].querySelectorAll(".d2h-file-side-diff tbody");
    check(halves[0].children.length === halves[1].children.length, "both halves keep the same number of rows");
  }
  // Click the new line 1 ("let one = 1", unchanged) and write a comment.
  const cells = [...d.querySelectorAll(".yatty-line")];
  check(cells.length > 0, "line numbers are clickable: " + cells.length);
  const target = layout === "side-by-side"
    ? [...d.querySelectorAll(".d2h-file-wrapper")[0].querySelectorAll(".d2h-file-side-diff")][0].querySelector(".yatty-line")
    : cells[0];
  target.dispatchEvent(new w.MouseEvent("click", { bubbles: true }));
  const area = d.querySelector(".yatty-box textarea");
  check(!!area, "a click opens a comment box");
  area.value = "  Rename this  ";
  area.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true }));
  const save = posted.find((m) => m.type === "save");
  check(save && save.path === "a.swift" && save.line === 1 && save.side === "new" && save.text === "Rename this",
    "⌘↩ saves path, line, side and text: " + JSON.stringify(save));
  check(save && save.code === "let one = 1", "it quotes the line: " + JSON.stringify(save && save.code));
  check(!d.querySelector(".yatty-box textarea"), "the box closes after saving");
  // Esc cancels without posting.
  posted.length = 0;
  cells[1].dispatchEvent(new w.MouseEvent("click", { bubbles: true }));
  d.querySelector(".yatty-box textarea").dispatchEvent(new w.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  check(posted.length === 0 && !d.querySelector(".yatty-box textarea"), "esc cancels");
  // Delete on a shown comment.
  const del = [...d.querySelectorAll("tr.yatty-comment button")].find((b) => b.textContent === "Delete");
  del.dispatchEvent(new w.MouseEvent("click", { bubbles: true }));
  check(posted.some((m) => m.type === "delete" && (m.id === "c1" || m.id === "c2")), "delete posts its id");
  // The app sends the comments back: only those show, rows stay aligned.
  w.yattySetComments([{ id: "c3", path: "b.txt", line: 1, side: "new", code: "hello", text: "New file?" }]);
  const now = [...d.querySelectorAll("tr.yatty-comment .yatty-text")].map((n) => n.textContent);
  check(JSON.stringify(now) === JSON.stringify(["New file?"]), "comments are replaced: " + JSON.stringify(now));
  if (layout === "side-by-side") {
    const halves = d.querySelectorAll(".d2h-file-wrapper")[0].querySelectorAll(".d2h-file-side-diff tbody");
    check(halves[0].children.length === halves[1].children.length, "halves stay aligned after removing rows");
  }
  // Text goes in as text, never as HTML.
  w.yattySetComments([{ id: "x", path: "a.swift", line: 1, side: "new", code: "", text: "<img src=x onerror=alert(1)>" }]);
  check(!d.querySelector(".yatty-text img"), "comment text isn't HTML");
}
console.log(failures ? failures + " failure(s)" : "all passed");
process.exit(failures ? 1 : 0);
