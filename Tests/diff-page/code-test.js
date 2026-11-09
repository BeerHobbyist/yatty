// Loads Yatty's code.html (the code beside the agent) in jsdom with the
// bundled highlight.js and diff2html, shows files, and drives it as a user would.
const { JSDOM } = require("jsdom");
const fs = require("fs");
const dir = process.argv[2];
const html = fs.readFileSync(dir + "/code.html", "utf8")
  .replace(/<script src="([^"]+)"><\/script>/g,
    (_, file) => "<script>" + fs.readFileSync(dir + "/" + file, "utf8") + "</script>");
const posted = [];
const scrolled = [];
const dom = new JSDOM(html, {
  runScripts: "dangerously",
  beforeParse(window) {
    window.webkit = { messageHandlers: { yatty: { postMessage: (m) => posted.push(m) } } };
    window.ResizeObserver = class { observe() {} };
    window.scrollTo = () => {};
    window.HTMLElement.prototype.scrollIntoView = function () { scrolled.push(this); };
  },
});
const w = dom.window, d = w.document;
let failures = 0;
const check = (ok, what) => { if (!ok) { failures++; console.log("FAIL:", what); } else console.log("ok:", what); };
const click = (node, init = {}) => node.dispatchEvent(new w.MouseEvent("click", { bubbles: true, ...init }));
const button = (root, title) => [...root.querySelectorAll("button")].find((b) => b.textContent === title);
const row = (line) => d.querySelector(`.ln[data-line="${line}"]`);
const rows9 = () => [...d.querySelectorAll(".ln[data-line]")];
const ghosts = () => [...d.querySelectorAll(".ln.del")];
const shownTexts = () => [...d.querySelectorAll(".yatty-comment .yatty-text")].map((n) => n.textContent);
const lineUnder = (comment) => {
  let node = comment.previousElementSibling;
  while (!node.classList.contains("ln")) node = node.previousElementSibling;
  return node.dataset.line || "old " + node.dataset.old;
};

const text = [
  "import Foundation", "", "struct Session {", "  let token: String", "  /* the time",
  "     it ends */", "  let expires: Date", "  func isValid() -> Bool { expires > now }", "}", "",
].join("\n");
// -U0: line 4 changed, 7 added, and a line removed after 9.
const diff = `diff --git a/S.swift b/S.swift
--- a/S.swift
+++ b/S.swift
@@ -4 +4 @@
-  let token: Int
+  let token: String
@@ -6,0 +7 @@
+  let expires: Date
@@ -9 +8,0 @@
-  var gone = 1
`;
const file = (over = {}) => ({ path: "S.swift", text, diff, untracked: false, language: "swift", comments: [], scroll: null, ...over });

console.log("== drawing");
check(w.yattyShow(file()) === 9, "shows every line");
check(row(4).classList.contains("add") && row(7).classList.contains("add") && !row(3).classList.contains("add"),
  "added and changed lines are marked");
check(ghosts().length === 2, "removed lines show where they were: " + ghosts().length);
check(ghosts()[0].nextElementSibling === row(4) && ghosts()[0].textContent.includes("let token: Int"),
  "a changed line's old text sits above it");
check(ghosts()[1].previousElementSibling === row(8), "a removed line sits after the line before it");
check(row(3).querySelector(".hljs-keyword")?.textContent === "struct", "it's highlighted");
check(row(6).querySelector(".hljs-comment") && row(5).querySelector(".hljs-comment"), "a comment over two lines stays a comment on both");
w.yattyShow(file({ path: "N.txt", text: "a\r\nb\r\n", diff: "", untracked: true, language: "txt" }));
check(d.querySelectorAll(".ln").length === 2 && d.querySelectorAll(".ln.add").length === 2, "a new file is all added");
check(!row(1).textContent.includes("\r"), "CRLF lines lose the CR");
w.yattyShow(file({ path: "x.html", text: '<img src=x onerror="alert(1)">\n', diff: "", language: "nope" }));
check(!d.querySelector("#code img"), "code is text, never HTML");

console.log("== comments");
posted.length = 0;
w.yattyShow(file({ comments: [{ id: "c1", path: "S.swift", line: 7, side: "new", code: "let expires: Date", text: "Why Date?", outdated: false, sent: false }] }));
check(shownTexts().includes("Why Date?") && lineUnder(d.querySelector(".yatty-comment")) === "7", "a comment shows under its line");
check(!posted.some((m) => m.type === "place"), "and isn't moved");
posted.length = 0;
click(row(3).querySelector(".n"));
const area = d.querySelector(".yatty-box textarea");
area.value = "Name it";
area.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true }));
const save = posted.find((m) => m.type === "save");
check(save && save.path === "S.swift" && save.line === 3 && save.side === "new" && save.code === "struct Session {" && save.text === "Name it",
  "a line number takes a comment: " + JSON.stringify(save));
posted.length = 0;
click(ghosts()[0].querySelector(".n"));
d.querySelector(".yatty-box textarea").value = "Why not Int?";
button(d, "Comment").click();
const old = posted.find((m) => m.type === "save");
check(old && old.side === "old" && old.line === 4 && old.code === "let token: Int", "so does a removed line: " + JSON.stringify(old));
// The file changes: two lines come in at the top.
posted.length = 0;
w.yattyShow(file({ text: "// one\n// two\n" + text, diff: "", scroll: null,
  comments: [{ id: "c1", path: "S.swift", line: 7, side: "new", code: "let expires: Date", text: "Why Date?", outdated: false, sent: false },
    { id: "c2", path: "S.swift", line: 4, side: "old", code: "let token: Int", text: "Why not Int?", outdated: false, sent: false }] }));
const place = posted.find((m) => m.type === "place");
const anchors = Object.fromEntries((place?.anchors ?? []).map((a) => [a.id, a]));
check(anchors.c1?.line === 9 && !anchors.c1.outdated, "a comment follows its line: " + JSON.stringify(anchors.c1));
check(anchors.c2?.outdated, "one whose removed line is gone is outdated");
check(d.querySelector("#outdated").textContent.includes("Why not Int?"), "and listed above the code");
click(button(d.querySelector("#outdated"), "Delete"));
check(posted.some((m) => m.type === "delete" && m.id === "c2"), "where it can be deleted");
// Edit hides it while the box is open; closing shows it again.
const commentRow = () => d.querySelector(".yatty-comment");
click(button(commentRow(), "Edit"));
check(commentRow().style.display === "none", "Edit hides the comment");
d.querySelector(".yatty-box textarea").dispatchEvent(new w.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
check(commentRow().style.display === "", "Esc shows it again");
// A comment being written survives the file changing under it.
click(rows9()[0].querySelector(".n"));
d.querySelector(".yatty-box textarea").value = "half-typed";
w.yattyShow(file({ text: "// zero\n// one\n// two\n" + text, diff: "", scroll: null }));
const draft = d.querySelector(".yatty-box textarea");
check(draft && draft.value === "half-typed", "a comment being written survives a reload");
check(draft && lineUnder(draft.closest(".yatty-row")) === "2", "under its line, moved: " + (draft && lineUnder(draft.closest(".yatty-row"))));
d.querySelector(".yatty-box textarea").dispatchEvent(new w.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
// Its line gone altogether: the nearest one keeps it.
click(rows9().at(-1).querySelector(".n"));
d.querySelector(".yatty-box textarea").value = "still here";
w.yattyShow(file({ text: "a\nb\n", diff: "", scroll: null }));
const kept = d.querySelector(".yatty-box textarea");
check(kept && kept.value === "still here" && lineUnder(kept.closest(".yatty-row")) === "2", "a draft whose line went stays, at the nearest line");
kept && kept.dispatchEvent(new w.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
w.yattyShow(file({ text: "// one\n// two\n" + text, diff: "", scroll: null }));
w.yattySetComments([{ id: "s", path: "S.swift", line: 1, side: "new", code: "// one", text: "<b>hi</b>", outdated: false, sent: true }]);
check(!d.querySelector(".yatty-text b") && d.querySelector(".yatty-comment").textContent.includes("sent"), "comment text is text; a sent one says so");

console.log("== following");
w.yattyShow(file({ scroll: null }));
scrolled.length = 0;
const changed = text.replace("let expires: Date", "let expires: Date?");
w.yattyShow(file({ text: changed, scroll: "change" }));
check(scrolled.length && scrolled.at(-1).dataset.line === "7", "the line that just changed is brought into view: " + scrolled.at(-1)?.dataset.line);
check(row(7).classList.contains("flash"), "and flashes");
scrolled.length = 0;
w.yattyShow(file({ path: "Other.swift", scroll: "change" }));
check(scrolled.at(-1)?.classList.contains("del") || scrolled.at(-1)?.dataset.line === "4", "another file opens at its first change");
scrolled.length = 0;
w.yattyShow(file({ scroll: { line: 8 } }));
check(scrolled.at(-1)?.dataset.line === "8", "or at the line asked for");
posted.length = 0;
d.querySelector("#code").dispatchEvent(new w.WheelEvent("wheel", { bubbles: true }));
check(posted.some((m) => m.type === "interact"), "scrolling by hand is told to the app");

console.log("== definitions");
posted.length = 0;
const target = row(7).querySelector(".t");
const node = [...target.childNodes].flatMap((n) => n.nodeType === 3 ? [n] : [...n.childNodes]).find((n) => n.textContent.includes("expires"));
d.caretRangeFromPoint = () => { const r = d.createRange(); r.setStart(node, node.textContent.indexOf("expires") + 2); return r; };
click(target, { metaKey: true });
check(posted.some((m) => m.type === "definition" && m.name === "expires"), "⌘-click asks where the name under it is declared: " + JSON.stringify(posted.at(-1)));
w.yattyDefinitions("expires", [{ path: "a.swift", line: 3, text: "let expires" }, { path: "b.swift", line: 9, text: "var expires" }]);
const items = [...d.querySelectorAll("#picker .item")];
check(items.length === 2, "several declarations: a list to pick from");
posted.length = 0;
click(items[1]);
check(posted.some((m) => m.type === "open" && m.path === "b.swift" && m.line === 9), "picking one opens it");
w.yattyDefinitions("nothing", []);
check(d.querySelector("#toast").textContent.includes("nothing"), "none: says so");

console.log("== a big file");
const big = Array.from({ length: 20000 }, (_, i) => `let value${i} = ${i} // line ${i}`).join("\n") + "\n";
const start = Date.now();
w.yattyShow(file({ path: "Big.swift", text: big, diff: "", untracked: true }));
const took = Date.now() - start;
check(d.querySelectorAll(".ln").length === 20000, "20000 lines");
check(took < 20000, "drawn in " + took + " ms");

console.log(failures ? failures + " failure(s)" : "all passed");
process.exit(failures ? 1 : 0);
