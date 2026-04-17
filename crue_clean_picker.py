#!/usr/bin/env python3
"""TUI for `crue-clean`.

Single screen listing crue sessions; Space toggles selection, `a` toggles
all, Enter -> confirmation screen -> y/N to proceed.

Usage: crue_clean_picker.py <workspace-dir> <repos-dir> <output-file>

Writes selected session names to <output-file>, one per line, on success.
Stdout is left alone for curses (crue_clean.sh can't pipe this script's
stdout without breaking the TUI).

Exit codes:
  0 success
  1 user cancelled / confirmation declined
  2 no sessions found
"""
import curses
import locale
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

locale.setlocale(locale.LC_ALL, "")


@dataclass
class Session:
    name: str
    path: Path
    age_seconds: float
    worktree_count: int
    dirty_count: int
    tmux_alive: bool
    is_current: bool
    selected: bool = False


def humanize_age(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return f"{s}s ago"
    if s < 3600:
        return f"{s // 60}m ago"
    if s < 86400:
        return f"{s // 3600}h ago"
    if s < 604800:
        return f"{s // 86400}d ago"
    return f"{s // 604800}w ago"


def _run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def tmux_current_session():
    if not os.environ.get("TMUX"):
        return None
    r = _run(["tmux", "display-message", "-p", "#S"], timeout=2)
    return r.stdout.strip() if r and r.returncode == 0 else None


def tmux_has_session(name: str) -> bool:
    r = _run(["tmux", "has-session", "-t", name], timeout=2)
    return bool(r and r.returncode == 0)


def worktree_is_dirty(wt: Path) -> bool:
    """Uncommitted changes OR branch tip not reachable from any origin ref."""
    r = _run(["git", "-C", str(wt), "status", "--porcelain"])
    if r is None:
        return True
    if r.returncode == 0 and r.stdout.strip():
        return True

    br = _run(["git", "-C", str(wt), "branch", "--show-current"])
    if br is None or br.returncode != 0:
        return False
    branch = br.stdout.strip()
    if not branch:
        return False
    for upstream in (f"origin/{branch}", "origin/HEAD"):
        rc = _run(
            ["git", "-C", str(wt), "merge-base", "--is-ancestor", branch, upstream]
        )
        if rc is not None and rc.returncode == 0:
            return False
    return True


def discover(workspace_dir: Path) -> list[Session]:
    if not workspace_dir.is_dir():
        return []
    current = tmux_current_session()
    now = time.time()
    entries = sorted(p for p in workspace_dir.iterdir() if p.is_dir())
    if not entries:
        return []
    print(f"crue-clean: scanning {len(entries)} session(s)...", file=sys.stderr)

    sessions = []
    for entry in entries:
        # A real worktree subdir has a `.git` file/dir pointing at its owner.
        worktrees = [
            p for p in entry.iterdir()
            if p.is_dir() and not p.is_symlink() and (p / ".git").exists()
        ]
        dirty = sum(1 for wt in worktrees if worktree_is_dirty(wt))
        try:
            age = now - entry.stat().st_mtime
        except OSError:
            age = 0.0
        sessions.append(Session(
            name=entry.name,
            path=entry,
            age_seconds=age,
            worktree_count=len(worktrees),
            dirty_count=dirty,
            tmux_alive=tmux_has_session(entry.name),
            is_current=(entry.name == current),
        ))
    return sessions


def _safe_addstr(stdscr, row, col, text, attr=0):
    h, w = stdscr.getmaxyx()
    if row < 0 or row >= h or col >= w:
        return
    try:
        stdscr.addstr(row, col, text[: w - col - 1], attr)
    except Exception:
        pass


def draw_list(stdscr, sessions, cursor):
    stdscr.clear()
    h, _ = stdscr.getmaxyx()
    _safe_addstr(stdscr, 0, 0, "crue-clean - select sessions to remove", curses.A_BOLD)
    _safe_addstr(stdscr, 1, 0,
                 "Space=toggle  a=all  j/k=nav  Enter=next  Esc/q=cancel",
                 curses.A_DIM)

    max_list = max(1, h - 4)
    start = max(0, cursor - max_list + 1) if cursor >= max_list else 0
    for i, idx in enumerate(range(start, min(start + max_list, len(sessions)))):
        s = sessions[idx]
        row = 3 + i
        mark = "[x]" if s.selected else "[ ]"
        age = humanize_age(s.age_seconds)
        tmux = "alive" if s.tmux_alive else "dead "
        cur = "  <current>" if s.is_current else ""
        line = (f"{mark} {s.name:<32} {age:>8}  "
                f"{s.worktree_count:>2} wt  {s.dirty_count} dirty  "
                f"tmux:{tmux}{cur}")
        attr = curses.A_REVERSE if idx == cursor else 0
        _safe_addstr(stdscr, row, 0, line, attr)

    selected_count = sum(1 for s in sessions if s.selected)
    _safe_addstr(stdscr, h - 1, 0,
                 f"{selected_count}/{len(sessions)} selected",
                 curses.A_DIM)
    stdscr.refresh()


def draw_confirm(stdscr, sessions):
    stdscr.clear()
    _safe_addstr(stdscr, 0, 0,
                 "Confirm cleanup?  y=proceed   any other key=back",
                 curses.A_BOLD)
    _safe_addstr(stdscr, 1, 0,
                 "Dirty/unpushed worktrees are skipped. Branches kept if not merged/pushed.",
                 curses.A_DIM)

    row = 3
    for s in sessions:
        if not s.selected:
            continue
        safe = s.worktree_count - s.dirty_count
        tmux = "kill tmux" if s.tmux_alive else "tmux already dead"
        detail = (f"  {s.name}: remove {safe} clean worktrees, "
                  f"skip {s.dirty_count} dirty, {tmux}")
        _safe_addstr(stdscr, row, 0, detail)
        row += 1
    stdscr.refresh()


def run(stdscr, sessions):
    try:
        curses.set_escdelay(25)
    except AttributeError:
        pass
    curses.curs_set(0)
    cursor = 0

    while True:
        draw_list(stdscr, sessions, cursor)
        ch = stdscr.getch()
        if ch in (curses.KEY_UP, ord("k")):
            cursor = max(0, cursor - 1)
        elif ch in (curses.KEY_DOWN, ord("j")):
            cursor = min(len(sessions) - 1, cursor + 1)
        elif ch == ord(" "):
            sessions[cursor].selected = not sessions[cursor].selected
        elif ch == ord("a"):
            any_unselected = any(not s.selected for s in sessions)
            for s in sessions:
                s.selected = any_unselected
        elif ch in (curses.KEY_ENTER, 10, 13):
            if not any(s.selected for s in sessions):
                continue
            draw_confirm(stdscr, sessions)
            ch2 = stdscr.getch()
            if ch2 in (ord("y"), ord("Y")):
                return [s.name for s in sessions if s.selected]
        elif ch in (27, ord("q")):
            return None


def main():
    if len(sys.argv) != 4:
        print("usage: crue_clean_picker.py <workspace-dir> <repos-dir> <output-file>",
              file=sys.stderr)
        sys.exit(2)
    workspace_dir = Path(sys.argv[1])
    _ = Path(sys.argv[2])  # repos_dir reserved for future use
    output_path = Path(sys.argv[3])

    sessions = discover(workspace_dir)
    if not sessions:
        print("No crue sessions found.", file=sys.stderr)
        sys.exit(2)

    result = curses.wrapper(run, sessions)
    if result is None:
        sys.exit(1)
    with output_path.open("w") as f:
        for name in result:
            f.write(name + "\n")


if __name__ == "__main__":
    main()
