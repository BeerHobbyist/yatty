# Yatty

Yet Another TTY: a native macOS app for running coding agents in parallel, one
git worktree each. A sidebar of repositories and their worktrees; each worktree
has tabs and splits, and every one of them is a real
[Ghostty](https://ghostty.org) terminal, kept alive by
[zmx](https://github.com/neurosnap/zmx) when Yatty quits.

- **Worktrees in one place.** Add a repository from GitHub (cloned for you) or
  a folder; make worktrees on a new branch, an existing one, or an open pull
  request; close them when done.
- **Terminals that stay.** Tabs and splits per worktree, with Ghostty's own
  keys. Quit and reopen: every pane comes back, attached to the same session.
- **Agents at a glance.** Claude Code in a new worktree starts by itself; the
  sidebar shows which agent needs you, works, or is done, and a notification
  says so when you're elsewhere.
- **Git and pull requests.** Uncommitted changes, ahead/behind, a PR badge
  coloured by CI, and a panel with checks, reviews and comments, merging
  included.
- **Diffs your way.** Working changes, staged, against the base branch, a ref
  or a range of commits, in hunk, diffnav, delta, difftastic, lumen, nvim
  diffview or plain git.
- **Remote machines.** A directory on an SSH host runs its terminals there.
- **A CLI for agents.** `yatty tab new --name dev -- npm run dev` lets an agent
  run and watch long-lived processes in their own tabs, sandboxed with it.
- **Nothing to remember.** ⇧⌘P lists every action with its key; ⌘? lists every
  key.

## Requirements

- macOS 26 on Apple Silicon
- `git`; the [GitHub CLI](https://cli.github.com) (`gh`, logged in) for
  repositories and pull requests
- To build: Xcode (Swift 6.2, the Metal toolchain) and
  [zig](https://ziglang.org) 0.17
- Optional: [Claude Code](https://docs.anthropic.com/en/docs/claude-code), a
  diff viewer, [fence](https://github.com/Use-Tusk/fence), zmx on SSH hosts

## Building

```sh
git clone --recurse-submodules git@github.com:BeerHobbyist/yatty.git
cd yatty
make deps                 # GhosttyKit (from ThirdParty/ghostty) and zmx into Vendor/
make app                  # build/Yatty.app (make app CONFIG=release for a release build)
make run                  # build and open it
```

## Getting started

1. **⌘O** adds a repository: pick one `gh` can see (it's cloned into
   `~/yatty`) or choose a folder.
2. **⌘N** makes a worktree: a new branch, an existing one, or an open pull
   request. Its terminal opens with your agent in it.
3. **⌘T** opens a tab, **⌘D** / **⇧⌘D** split it, **⌘W** closes a pane.
   **⇧⌘J** goes to the next agent that needs you.
4. **⇧⌘P** finds anything else.

## Keys

| Key | | Key | |
|---|---|---|---|
| ⌘N | new worktree | ⌘T / ⌥⌘T | new tab / new agent tab |
| ⌘O / ⇧⌘O | add repository / SSH host | ⌘D / ⇧⌘D | split right / down |
| ⇧⌘P | command palette | ⌘W / ⌥⌘W | close pane / tab |
| ⌘? | all keys | ⌘[ ⌘] | previous / next pane |
| ⌘, | settings | ⇧⌘[ ⇧⌘] / ⌘1–9 | previous / next tab, tab n |
| ⇧⌘J | next agent that needs you | ⌥⌘D | open a diff |
| ⌥⌘P | pull request panel | ⌃⌘= | equalize splits |
| ⌘R | refresh pull requests | ⌘K | clear the screen |

Terminal keys are Ghostty's: rebinding them in Ghostty's config works in Yatty
too.

## Settings

⌘, edits `~/.config/yatty/config.json`:

- **Agent command** (`agentCommand`, default `caffeinate -is claude`): typed
  into a new worktree's first terminal and into New Agent tabs. Empty: none.
- **Notifications** (`notifications`): when an agent needs you or finishes
  while you're looking elsewhere.
- **Clone into** (`cloneDirectory`, default `~/yatty`).
- **Sandbox command** (`sandboxCommand`): see "Running agents in fence".

Agents Yatty starts report their state through Claude Code hooks it passes
them (`--settings`). Agents > Track Every Claude adds the same hooks to your
own Claude settings, so a `claude` you type yourself reports too; they do
nothing outside Yatty.

## SSH projects

Add SSH Host (⇧⌘O) adds a directory on another machine: any host `ssh` can
reach, a `~/.ssh/config` alias included. Its terminals, tabs and splits run
there, each in a zmx session on that host, so they outlive a dropped connection
and Yatty quitting. zmx must be installed on the host.

- Key logins just work. A host that asks for a password, or a key's passphrase,
  gets a field for it: it logs in once, and everything after shares that
  connection (for 10 minutes after the last terminal closes). The password is
  never stored. Yatty never logs in to such a host in the background.
- A dropped connection leaves the pane showing what ssh said, with a Reconnect
  bar; the session is still running on the host.
- Git status, pull requests, diffs and the `yatty` CLI are for this Mac's
  repositories only. A "New Agent" tab there runs plain `claude`.

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

1. Set the sandbox to start things in: Settings > Sandbox command (a command
   prefix, read by `/bin/sh`), for example `fence --`. Without it, Yatty starts
   nothing for a sandboxed agent.

2. Let the sandbox reach Yatty's sandbox socket, and nothing else of Yatty's,
   in your fence config:

   ```jsonc
   {
     "network": {
       // The sandbox's socket only. Never app.sock, never the zmx/ or ssh/
       // directories: zmx runs whatever it's asked to, outside the sandbox.
       "allowUnixSockets": ["~/.local/state/yatty/sandbox.sock"]
     },
     "filesystem": {
       // A sandbox that could edit Yatty's config could change the sandbox
       // command, or the hooks Yatty gives unsandboxed agents.
       "denyWrite": ["~/.config/yatty/**"]
     }
   }
   ```

   Agents report their state under `~/.local/state/yatty/agents/`, so that
   directory must stay writable.

## Development

```sh
make test                 # unit tests
scripts/cli-e2e.sh        # the yatty CLI against a real, isolated Yatty
scripts/zmx-e2e.sh        # what Yatty assumes of zmx
scripts/ssh-e2e.sh        # SSH projects against a throwaway sshd on 127.0.0.1
scripts/snapshot.sh SCENE # build/snapshots/SCENE.png from sample data
```

The end-to-end scripts and snapshots run Yatty with its own config, state and
zmx directories, never yours. `docs/superpowers/plans/` holds the roadmap and
each phase's plan; `CLAUDE.md` the project's rules.
