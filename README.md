# crue

`crue` spins up focused, multi-repo workspaces. One invocation creates a fresh branch as a git worktree across every repo in `~/source/repos`, drops you into a dedicated tmux session, and (optionally) hands Claude a briefing telling it which repos are in scope.

## Why

When a task spans several repos, you usually have to juggle branches on each one, remember which checkouts belong to the task, and tolerate an LLM agent poking around unrelated trees. `crue` collapses that into a single branch name, one worktree per repo, one tmux session, and one Claude session — all scoped to the work at hand.

## What a session looks like

For a new session named `ju/foo`:

```
~/source/repos/.worktrees/ju-foo/
  react/               (git worktree, branch ju/foo)
  typescript/          (git worktree, branch ju/foo)
  ...every repo...
  .crue-session-id     (UUID used by claude --resume)
  .claude/
    settings.local.json  (read access across ~/source, trust pre-accepted)
```

And a tmux session `ju-foo` with four windows:

- **Neovim** — `nvim .` in the session folder
- **Term** — shell in the session folder
- **Claude** — `claude --session-id <uuid> --name ju-foo [briefing]`
- **CLI** — blank shell

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

- bash, git, tmux, python3 (stdlib only; needs curses)
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

Edit `REPOS_DIR` in `crue.sh` / `crue_clean.sh` and the `ju/$generated` line in `crue.sh` if your layout differs.

## Usage

### Start / resume

```
$ crue
```

A curses picker opens:

- **Screen 0** — existing session folders. Pick one to resume, or `[+] new session`.
- **Screen 1** (new sessions only) — flag repos. `Tab` marks **primary** (main focus), `Space` marks **secondary** (context). Unflagged repos still get worktrees; the flags only shape Claude's briefing.
- **Screen 2** — branch name. Leave blank for an auto-generated `ju/<adj>-<noun>` (e.g. `ju/copper-falcon`), or type one (slashes allowed, e.g. `bugfix/1234`).

`Enter` advances, `Esc`/`q` backs out. On exit, you're attached to the tmux session.

If the tmux session died but the worktree folder is still on disk, picking it on Screen 0 rebuilds the four tmux windows and runs `claude --resume <session-id>` using the UUID stashed in `.crue-session-id`.

### Clean up

```
$ crue-clean
```

Lists all sessions with age, worktree count, dirty count, and tmux alive/dead. `Space` toggles, `a` toggles all, `Enter` → confirmation → `y` to proceed.

Safe by default:

- Worktrees with uncommitted changes or branches not reachable from `origin/*` are **skipped**.
- Branches only get deleted if fully merged/pushed (`git branch -d`, never `-D`).
- The session folder is removed only if no live worktrees remain inside.
- The tmux session is killed last. If you clean the session you're currently attached to, the client is switched to another session (or detached) first.

## How it works

1. **Global gitignore bootstrap** — every run ensures `git config --global core.excludesfile` is set and contains `.claude/` + `.crue-*` patterns, so `crue`/Claude scratch files never accidentally get committed to any repo.
2. **Worktree fan-out** — for each repo, resolves `origin/HEAD` (falling back to `main` / `master`) and runs `git worktree add -b <branch> <session-dir>/<repo> origin/<default>` in parallel (up to 8 at a time).
3. **Claude trust pre-accept** — atomically edits `~/.claude.json` to set `projects[<workdir>].hasTrustDialogAccepted = true`, so Claude doesn't block on the trust prompt.
4. **Briefing** — if any repos were flagged, writes `.crue-prompt.txt` with the primary/secondary lists and the worktree layout, then passes its contents as the first message to Claude.

## Files

| File | Purpose |
|------|---------|
| `crue.sh` | Entry point: picker → worktree fan-out → tmux build → attach |
| `crue_picker.py` | Curses TUI for the three screens (resume / focus / name) |
| `crue_words.py` | Adjective + noun lists for auto-generated branch names |
| `crue_clean.sh` | Cleanup entry point: picker → worktree remove → branch delete → tmux kill |
| `crue_clean_picker.py` | Curses TUI for session selection + confirmation |
| `install.sh` | Idempotent installer: notification sounds + Claude Code Stop/Notification hooks (WSL-only) |
| `assets/sounds/` | Bundled WAVs used by the Claude Code hooks |

## Caveats

- Built for a single-user dev loop on one machine — paths and defaults are hardcoded.
- Every session creates a branch in every repo, even ones you don't touch. Cleanup deletes only merged/pushed branches, so unused empty branches linger until you `git branch -d` them manually.
- Each repo needs a resolvable `origin/HEAD` (or `main` / `master`); otherwise it's skipped for that session.
