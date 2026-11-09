---
name: yatty
description: Control the Yatty terminal you are running in — run long-lived processes (dev servers, watchers, builds, test runs) in their own tabs and read their output, show the user a diff, and ask for their attention. Use when $YATTY_CLI is set and a command would block or keep running, when you need to check on a process you started, or when the user should look at something.
---

# yatty

You're running inside **Yatty**: a terminal app where each git worktree has its own **tabs**. The user sees them in Yatty's tab bar. The `yatty` command controls the tabs of the worktree you're in.

Check you're inside Yatty before using it:

```sh
[ -n "$YATTY_CLI" ] && echo inside yatty
```

If `yatty` isn't on your PATH, use `"$YATTY_CLI"` instead: same commands.

## When to use it

- **A command that doesn't finish by itself**: a dev server, `--watch` mode, a long build or test run you want to check on later. Run it in its own tab instead of in your own shell, where it would block you (or be killed when your command times out).
- **Checking on it**: read the tab's output instead of guessing.
- **Showing the user something**: open a diff for them, or ask for their attention when you're blocked or done with something they need to see.

Don't use it for quick commands that finish in seconds; run those directly.

## Commands

```sh
yatty tab list                          # number, name, active: see what's already running
yatty tab new --name dev -- npm run dev # opens in the background; prints its number
yatty tab read dev --lines 40           # its last 40 lines (default 50)
yatty tab send dev --key C-c            # stop it (keys: C-c, Enter, Escape, Up, Tab, M-x…)
yatty tab send dev "rs"                 # type a line into it (Enter follows unless --no-enter)
yatty tab close dev
yatty diff                              # working changes, shown to the user in a Yatty diff tab or their terminal viewer's tab (also: staged, base, a ref, or a range like SHA^..SHA)
yatty notify "Migration ready: review the SQL in tab db"
yatty status                            # every worktree and its agent's state
```

`TAB` is a tab's number (1 = first) or name. Add `--json` to `tab list`, `tab new` and `status` for machine-readable output. `tab new -- COMMAND` types COMMAND into the tab's shell, so the tab stays open after it exits; a single quoted word is typed as is (`-- "npm run dev 2>&1 | tee dev.log"`). `--worktree PATH` acts on another worktree Yatty knows.

## Working with a dev server

1. `yatty tab list` first: if a `dev` tab is already running, use it rather than starting another (`tab new` refuses a name already in use).
2. `yatty tab new --name dev -- npm run dev`
3. Give it a moment, then `yatty tab read dev --lines 30` and look for the "ready" line or errors. Poll with short sleeps instead of one long wait.
4. After changing code, read again to see reloads or new errors.
5. When you're done with it, `yatty tab send dev --key C-c` and `yatty tab close dev`, unless the user wants it left running.

## In a sandbox

Inside fence (`$FENCE_SANDBOX` is set), `yatty` asks the app on the sandbox's terms: what `tab new` and `diff` start runs in the sandbox too (a diff opens in a terminal viewer's tab then, not in a Yatty diff tab), and `tab send` types only into tabs opened that way, not into the user's tabs or other agents'. It needs the app open, and fence must allow Yatty's sandbox socket. If it can't reach Yatty, or refuses, tell the user; don't look for a way around it.

## Etiquette

- **Don't take over the user's screen.** `tab new` opens in the background; only pass `--select` (or run `tab select`) when the user asked to see the tab.
- **Name your tabs** (`--name dev`, `--name tests`) so you and the user can tell them apart, and **close the ones you opened** when you no longer need them.
- **Leave tabs you didn't open alone**: they're the user's.
- **Notify sparingly**: when you're blocked on the user or finished something they're waiting for, not for progress updates. Yatty already tells the user when you stop or need a permission.
