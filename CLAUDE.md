# Yatty

Yet Another TTY: a native macOS app for running coding agents in parallel, one
git worktree each. A sidebar of repos and their worktrees; each worktree has
tabs and splits, and every one of them is a real Ghostty terminal.

## How it's built

- **Swift**, SwiftUI for the app shell, AppKit for terminal views.
- **GhosttyKit** (libghostty) renders terminals. Built from the pinned
  `ThirdParty/ghostty` submodule by `scripts/build-ghostty.sh` into `Vendor/`.
- **zmx** keeps each terminal's process alive across app restarts. One zmx
  session per terminal, on Yatty's own socket directory (`ZMX_DIR`). No tmux.
- **git** and **gh** are run as processes, as agentree does.
- State lives in `~/.config/yatty/`: `state.json` (repos, selection; written
  by the app) and `config.json` (`agentCommand`, typed into a new session;
  written by the user). Worktrees are read from git, never stored.

## Commands

```sh
make deps   # GhosttyKit + zmx into Vendor/ (needs zig 0.17 and Xcode's Metal toolchain)
make build  # swift build
make app    # build/Yatty.app
make run    # build and open the app
```

## Rules

- **When a behaviour is undecided, do what agentree does** (`~/agentree/agentree-tui`,
  its README and `docs/DEVLOG.md`): agentree is the model for how things work
  for the user, not for how they're built.
- **Keep the internals small and boring.** A terminal must behave exactly like
  a Ghostty window. Rebuilding agentree's workarounds (cursor, copy mode,
  clipboard relays) means something is layered wrong.
- **Fenced agents must never reach zmx's sockets**: zmx runs commands outside
  the sandbox, as tmux did. Anything an agent asks for goes through the app.
