# Yatty

Yet Another TTY: a native macOS app for running coding agents in parallel, one
git worktree each. A sidebar of repos and their worktrees; each worktree has
tabs and splits, and every one of them is a real Ghostty terminal.

## Building

```sh
make deps   # GhosttyKit + zmx into Vendor/ (needs zig 0.17 and Xcode's Metal toolchain)
make app    # build/Yatty.app
make run    # build and open the app
```

## The agent CLI

Every Yatty terminal has the `yatty` command on its `PATH` (and at
`$YATTY_CLI`). It drives the tabs of the worktree it runs in, through the app:

```sh
yatty tab new --name dev -- npm run dev   # a tab in the background, running it
yatty tab read dev --lines 30             # what it shows
yatty tab send dev --key C-c              # stop it
yatty diff                                # working changes, in a tab of its own
yatty notify "Ready for review"           # a notification for you
yatty status                              # every worktree and its agent's state
```

`yatty --help` lists the rest. Agents Yatty starts are told about it when they
start; `yatty skill install` adds a Claude Code skill that teaches it in full
(to `~/.claude/skills/yatty`, or `$CLAUDE_CONFIG_DIR`).

## Running agents in fence

Inside [fence](https://github.com/Use-Tusk/fence) the CLI talks to the app on
the sandbox's terms: what `tab new` and `diff` start runs in the sandbox too,
and `tab send` types only into tabs opened that way, never into your own shell.

1. Tell Yatty the sandbox to start things in, in `~/.config/yatty/config.json`
   (a command prefix, read by `/bin/sh`), then restart Yatty:

   ```json
   { "sandboxCommand": "fence --" }
   ```

   Without it, Yatty starts nothing for a sandboxed agent.

2. Let the sandbox reach Yatty's sandbox socket, and nothing else of Yatty's,
   in your fence config:

   ```jsonc
   {
     "network": {
       // The sandbox's socket only. Never app.sock, never the zmx/ directory:
       // zmx runs whatever it's asked to, outside the sandbox.
       "allowUnixSockets": ["~/.local/state/yatty/sandbox.sock"]
     },
     "filesystem": {
       // A sandbox that could edit Yatty's config could change sandboxCommand,
       // or the hooks Yatty gives unsandboxed agents.
       "denyWrite": ["~/.config/yatty/**"]
     }
   }
   ```

   Agents report their state under `~/.local/state/yatty/agents/`, so that
   directory must stay writable.
