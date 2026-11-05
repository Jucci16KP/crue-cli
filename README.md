# crue

`crue` spins up focused, multi-repo workspaces. One invocation creates a fresh branch as a git worktree in the repos you pick from `~/source/repos`, drops you into a dedicated [herdr](https://herdr.dev) workspace (or tmux session), and hands Claude a briefing telling it which repos are in scope. More repos can join the session later with `crue add <repo>`.

## Why

When a task spans several repos, you usually have to juggle branches on each one, remember which checkouts belong to the task, and tolerate an LLM agent poking around unrelated trees. `crue` collapses that into a single branch name, one worktree per repo you need, one herdr workspace or tmux session, and one Claude session — all scoped to the work at hand.

## What a session looks like

For a new session named `ju/foo`:

```
~/source/repos/.worktrees/ju-foo/
  react/               (git worktree, branch ju/foo)
  typescript/          (git worktree, branch ju/foo)
  ...each flagged repo (every repo if none flagged)...
  .crue-session-id     (UUID used by claude --resume)
  .crue-meta.json      (branch + last-opened time)
  .claude/
    settings.local.json  (read access across ~/source, trust pre-accepted)
```

And a session `ju-foo` with four tabs (herdr) or windows (tmux), opening on Claude:

- **Claude** — `claude --session-id <uuid> --name ju-foo [briefing]`
- **Neovim** — `nvim .` in the session folder
- **Term** — shell in the session folder
- **CLI** — blank shell

Every shell in the session has `CRUE_WORKDIR` (the session folder) and `CRUE_SESSION_UUID` in its environment.

### herdr or tmux

`crue` uses **herdr** when you run it from inside a herdr pane (`HERDR_ENV=1`): the session becomes a herdr workspace labelled `ju-foo`, and herdr's sidebar shows that session's Claude state alongside your other work. Anywhere else it falls back to **tmux**, exactly as before. Force either with `CRUE_MUX=herdr` or `CRUE_MUX=tmux`. A session lives in one backend; resuming it from the other one rebuilds it there.

## Install

```bash
git clone git@github.com:Jucci16KP/crue-cli.git ~/source/repos/crue-cli
~/source/repos/crue-cli/install.sh   # WSL-only: copies notification sounds + merges Claude Code hooks
```

Add to your `~/.zshrc` / `~/.bashrc`:

```bash
alias crue="~/source/repos/crue-cli/crue.sh"
alias crue-clean="~/source/repos/crue-cli/crue_clean.sh"
```

`install.sh` is idempotent — re-running is safe and will skip anything already in place. It only touches `~/sounds/` and `~/.claude/settings.json` (merged, never replaced). Skip it if you don't want the audio cues.

### Requirements

- bash, git, python3 (stdlib only; needs curses)
- [herdr](https://herdr.dev) and/or tmux
- `nvim` (the Neovim window hardcodes it — swap in `build_session()` if you use a different editor)
- [Claude Code CLI](https://github.com/anthropics/claude-code) (`claude`) for the agent window
- `jq` (only if running `install.sh`)

## Neovim session integration (optional)

`crue.sh` exports `CRUE_SESSION_UUID` and launches nvim with `+AutoSession save <uuid>` (new) or `+AutoSession restore <uuid>` (resume). To have nvim actually persist and restore your buffers/windows between crue sessions, add [auto-session](https://github.com/rmagatti/auto-session) to your config.

lazy.nvim snippet:

```lua
{
  "rmagatti/auto-session",
  lazy = false,
  opts = {
    root_dir = vim.fn.expand "~/.local/share/nvim/crue-sessions/",
    auto_save = true,
    auto_restore = false,   -- crue drives restore explicitly
    auto_create = false,
  },
  config = function(_, opts)
    require("auto-session").setup(opts)
    -- VimLeave doesn't fire on deadly signals (SIGHUP from `tmux kill-session`),
    -- so save-on-exit is unreliable. Save incrementally on buffer changes.
    -- Gated on v:vim_did_enter so startup BufAdd for the scratch buffer can't
    -- overwrite the file before +AutoSession restore has run.
    local uuid = vim.env.CRUE_SESSION_UUID
    vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWritePost", "WinClosed" }, {
      group = vim.api.nvim_create_augroup("CrueSessionSave", { clear = true }),
      callback = function()
        if vim.v.vim_did_enter == 1 then
          pcall(require("auto-session").save_session, uuid)
        end
      end,
    })
  end,
},
```

Session files are UUID-named under `~/.local/share/nvim/crue-sessions/`. `crue-clean` removes the matching file when it prunes a session. Legacy crue sessions (created before you added this) fall back gracefully — first resume starts fresh, subsequent resumes restore.

### Hardcoded paths

`crue` assumes:

- Repos live at `~/source/repos/`
- Worktrees live at `~/source/repos/.worktrees/`
- Auto-generated branches use the `ju/` prefix

Override the first two with `CRUE_REPOS_DIR` / `CRUE_WORKTREES_DIR`, and edit the `ju/$generated` line in `crue.sh` for a different prefix.

## Usage

### Start / resume

```
$ crue
```

A curses picker opens:

- **Screen 0** — existing session folders. Pick one to resume, or `[+] new session`.
- **Screen 1** (new sessions only) — flag repos. `Tab` marks **primary** (main focus), `Space` marks **secondary** (context). Only flagged repos get worktrees, and the flags shape Claude's briefing. Flag nothing to get a worktree in every repo (the old behaviour, with no briefing).
- **Screen 2** — branch name. Leave blank for an auto-generated `ju/<adj>-<noun>` (e.g. `ju/copper-falcon`), or type one (slashes allowed, e.g. `bugfix/1234`).

`Enter` advances, `Esc`/`q` backs out. On exit, the session is focused (herdr) or attached (tmux).

If the session is gone but the worktree folder is still on disk, picking it on Screen 0 rebuilds the four tabs/windows and runs `claude --resume <session-id>` using the UUID stashed in `.crue-session-id`. (herdr keeps workspaces across detaches, and its Claude integration resumes Claude after a herdr restart, so this mostly matters after you close a workspace.)

### Add a repo to a running session

```
$ crue add <repo>...
```

Run it from anywhere inside the session folder (or any pane of the session). It creates `<session>/<repo>/` on the session's branch, reusing the branch if that repo already has it. With no arguments it lists the repos that don't have a worktree yet.

Claude's briefing tells it to run `crue.sh add <repo>` before editing a repo that isn't in the session yet, and the session's `.claude/settings.local.json` pre-approves that command. Nothing enforces this; it relies on Claude following the briefing.

### Clean up

```
$ crue-clean
```

Lists all sessions with age, worktree count, dirty count, and whether the herdr workspace / tmux session is alive. `Space` toggles, `a` toggles all, `Enter` → confirmation → `y` to proceed safely, or `F` to force.

Safe by default (`y`):

- Worktrees with uncommitted changes or branches not reachable from `origin/*` are **skipped**.
- Branches only get deleted if fully merged/pushed (`git branch -d`, never `-D`).
- The session folder is removed only if no live worktrees remain inside.
- The herdr workspace / tmux session is closed last. If you clean the session you're in, tmux switches the client to another session (or detaches) first; herdr moves focus to another workspace on its own.

Force mode (`F`) — destructive, use when you want a dirty session gone:

- Dirty / unpushed worktrees are removed via `git worktree remove --force` (uncommitted changes are discarded).
- Branches are deleted with `git branch -D`, even if they were never merged or pushed.
- Everything else (workspace folder cleanup, nvim session file, closing the session) behaves the same.

## How it works

1. **Global gitignore bootstrap** — every run ensures `git config --global core.excludesfile` is set and contains `.claude/` + `.crue-*` patterns, so `crue`/Claude scratch files never accidentally get committed to any repo.
2. **Worktree fan-out** — for each flagged repo (or every repo if none are flagged), resolves `origin/HEAD` (falling back to `main` / `master`) and runs `git worktree add -b <branch> <session-dir>/<repo> origin/<default>` in parallel (up to 8 at a time).
3. **Claude trust pre-accept** — atomically edits `~/.claude.json` to set `projects[<workdir>].hasTrustDialogAccepted = true`, so Claude doesn't block on the trust prompt.
4. **Briefing** — if any repos were flagged, writes `.crue-prompt.txt` with the primary/secondary lists, the worktree layout and how to `crue add` another repo, then passes its contents as the first message to Claude.

## Files

| File | Purpose |
|------|---------|
| `crue.sh` | Entry point: picker → worktree fan-out → session build → attach; also `crue add` |
| `crue_mux.sh` / `crue_mux.py` | herdr-or-tmux backend for the shell scripts / the pickers |
| `crue_picker.py` | Curses TUI for the three screens (resume / focus / name) |
| `crue_words.py` | Adjective + noun lists for auto-generated branch names |
| `crue_clean.sh` | Cleanup entry point: picker → worktree remove → branch delete → close session |
| `crue_clean_picker.py` | Curses TUI for session selection + confirmation |
| `install.sh` | Idempotent installer: notification sounds + Claude Code Stop/Notification hooks (WSL-only) |
| `assets/sounds/` | Bundled WAVs used by the Claude Code hooks |

## Caveats

- Built for a single-user dev loop on one machine — paths and defaults are hardcoded.
- A session with nothing flagged still creates a branch in every repo. Cleanup deletes only merged/pushed branches, so unused empty branches can linger until you `git branch -d` them manually.
- herdr workspaces are matched by label. A workspace you create yourself with the same name as a crue session counts as that session.
- Each repo needs a resolvable `origin/HEAD` (or `main` / `master`); otherwise it's skipped for that session.
