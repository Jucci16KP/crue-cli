#!/usr/bin/env python3
"""Three-screen TUI for `crue`.

Screen 0: pick an existing crue workspace or start a new one.
Screen 1: flag repos as primary/secondary (briefing metadata only).
Screen 2: enter a worktree name (empty -> bash will auto-generate).

Usage: crue_picker.py <repos-dir> <workspace-dir> <output-file>

Writes JSON lines to <output-file> on success (exit 0). First line is always
the mode header:
  {"mode": "resume", "dir_name": "..."}             # resume an existing session
  {"mode": "new"}                                   # new session, followed by:
  {"primary": [...], "secondary": [...]}
  {"name": "..."}

Stdout is left alone so curses can own the terminal (crue.sh can't redirect
this script's stdout without breaking the TUI).

Exit codes:
  0 success, 1 user cancelled, 2 bad args / no repos found.
"""
import curses
import json
import locale
import subprocess
import sys
from pathlib import Path

locale.setlocale(locale.LC_ALL, "")

NONE, SECONDARY, PRIMARY = 0, 1, 2
MARKER_STR = {NONE: "[ ]", SECONDARY: "[s]", PRIMARY: "[P]"}


def find_repos(repos_dir: Path) -> list[str]:
    return sorted(
        entry.name
        for entry in repos_dir.iterdir()
        if entry.is_dir() and (entry / ".git").exists()
    )


def find_workspaces(workspace_dir: Path) -> list[str]:
    if not workspace_dir.is_dir():
        return []
    return sorted(
        entry.name
        for entry in workspace_dir.iterdir()
        if entry.is_dir()
    )


def running_tmux_sessions() -> set[str]:
    try:
        out = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}"],
            capture_output=True, text=True, timeout=2,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return set()
    if out.returncode != 0:
        return set()
    return {line.strip() for line in out.stdout.splitlines() if line.strip()}


def _safe_addstr(stdscr, row, col, text, attr=0):
    h, w = stdscr.getmaxyx()
    if row < 0 or row >= h or col >= w:
        return
    try:
        stdscr.addstr(row, col, text[: w - col - 1], attr)
    except Exception:
        pass


# --- Screen 0: pick existing workspace or "new" -----------------------------
def draw_screen0(stdscr, workspaces, running, cursor):
    stdscr.clear()
    h, _ = stdscr.getmaxyx()
    _safe_addstr(stdscr, 0, 0, "crue", curses.A_BOLD)
    _safe_addstr(
        stdscr, 1, 0,
        "j/k=nav  Enter=select  Esc/q=quit",
        curses.A_DIM,
    )
    # "+ new session" is always index 0; workspaces follow.
    items = [("new", None)] + [("workspace", w) for w in workspaces]
    max_list = max(1, h - 4)
    start = max(0, cursor - max_list + 1) if cursor >= max_list else 0
    for i, idx in enumerate(range(start, min(start + max_list, len(items)))):
        row = 3 + i
        kind, payload = items[idx]
        if kind == "new":
            line = "[+] new session"
        else:
            dot = "●" if payload in running else "○"
            line = f" {dot}  {payload}"
        attr = curses.A_REVERSE if idx == cursor else curses.A_NORMAL
        _safe_addstr(stdscr, row, 0, line, attr)
    stdscr.refresh()


def screen0(stdscr, workspaces, running):
    items = [("new", None)] + [("workspace", w) for w in workspaces]
    cursor = 0
    while True:
        draw_screen0(stdscr, workspaces, running, cursor)
        ch = stdscr.getch()
        if ch in (curses.KEY_UP, ord("k")):
            cursor = max(0, cursor - 1)
        elif ch in (curses.KEY_DOWN, ord("j")):
            cursor = min(len(items) - 1, cursor + 1)
        elif ch in (curses.KEY_ENTER, 10, 13):
            return items[cursor]
        elif ch in (27, ord("q")):
            return None


# --- Screen 1: flag primary/secondary repos ---------------------------------
def draw_screen1(stdscr, repos, marks, cursor):
    stdscr.clear()
    h, _ = stdscr.getmaxyx()
    _safe_addstr(stdscr, 0, 0, "crue - select focus", curses.A_BOLD)
    _safe_addstr(
        stdscr, 1, 0,
        "Tab=primary  Space=secondary  j/k=nav  Enter=next  Esc/q=back",
        curses.A_DIM,
    )
    _safe_addstr(
        stdscr, 2, 0,
        "(every repo gets a worktree; flags only tell Claude what to focus on)",
        curses.A_DIM,
    )

    max_list = max(1, h - 5)
    start = max(0, cursor - max_list + 1) if cursor >= max_list else 0
    for i, idx in enumerate(range(start, min(start + max_list, len(repos)))):
        row = 4 + i
        line = f"{MARKER_STR[marks[idx]]} {repos[idx]}"
        attr = curses.A_REVERSE if idx == cursor else curses.A_NORMAL
        _safe_addstr(stdscr, row, 0, line, attr)

    p = sum(1 for m in marks if m == PRIMARY)
    s = sum(1 for m in marks if m == SECONDARY)
    _safe_addstr(
        stdscr, h - 1, 0,
        f"primary={p}  secondary={s}  total={len(repos)}",
        curses.A_DIM,
    )
    stdscr.refresh()


def screen1(stdscr, repos, marks):
    cursor = 0
    while True:
        draw_screen1(stdscr, repos, marks, cursor)
        ch = stdscr.getch()
        if ch in (curses.KEY_UP, ord("k")):
            cursor = max(0, cursor - 1)
        elif ch in (curses.KEY_DOWN, ord("j")):
            cursor = min(len(repos) - 1, cursor + 1)
        elif ch == ord(" "):
            marks[cursor] = NONE if marks[cursor] == SECONDARY else SECONDARY
        elif ch == ord("\t"):
            marks[cursor] = NONE if marks[cursor] == PRIMARY else PRIMARY
        elif ch in (curses.KEY_ENTER, 10, 13):
            return True
        elif ch in (27, ord("q")):
            return False


# --- Screen 2: branch name --------------------------------------------------
def draw_screen2(stdscr, text):
    stdscr.clear()
    _safe_addstr(stdscr, 0, 0, "crue - branch name", curses.A_BOLD)
    _safe_addstr(
        stdscr, 1, 0,
        "Enter=confirm  Esc=back    (empty -> auto ju/<adj>-<noun>)",
        curses.A_DIM,
    )
    _safe_addstr(
        stdscr, 2, 0,
        "Slashes allowed, e.g. bugfix/1234",
        curses.A_DIM,
    )
    if text:
        _safe_addstr(stdscr, 4, 0, text)
    else:
        _safe_addstr(stdscr, 4, 0,
                     "<empty - will auto-generate ju/adj-noun>",
                     curses.A_DIM)
    try:
        stdscr.move(4, len(text))
    except curses.error:
        pass
    stdscr.refresh()


def screen2(stdscr):
    text = ""
    curses.curs_set(1)
    try:
        while True:
            draw_screen2(stdscr, text)
            ch = stdscr.getch()
            if ch in (curses.KEY_ENTER, 10, 13):
                return text
            if ch == 27:
                return None
            if ch in (curses.KEY_BACKSPACE, 127, 8):
                text = text[:-1]
            elif 32 <= ch < 127:
                c = chr(ch)
                if c not in (" ", "\\", ":", "?", "*", "[", "]"):
                    text += c
    finally:
        curses.curs_set(0)


def run(stdscr, repos, workspaces, running):
    try:
        curses.set_escdelay(25)
    except AttributeError:
        pass
    curses.curs_set(0)
    marks = [NONE] * len(repos)
    while True:
        choice = screen0(stdscr, workspaces, running)
        if choice is None:
            return None
        kind, payload = choice
        if kind == "workspace":
            return ("resume", payload)
        # kind == "new" -> fall through to repo picker + name prompt
        if not screen1(stdscr, repos, marks):
            continue  # back to screen0
        name = screen2(stdscr)
        if name is None:
            continue  # back to screen0 via screen1 exit path
        primary = [r for r, m in zip(repos, marks) if m == PRIMARY]
        secondary = [r for r, m in zip(repos, marks) if m == SECONDARY]
        return ("new", (primary, secondary, name))


def main():
    if len(sys.argv) != 4:
        print(
            "usage: crue_picker.py <repos-dir> <workspace-dir> <output-file>",
            file=sys.stderr,
        )
        sys.exit(2)
    repos_dir = Path(sys.argv[1])
    workspace_dir = Path(sys.argv[2])
    output_path = Path(sys.argv[3])
    if not repos_dir.is_dir():
        print(f"not a directory: {repos_dir}", file=sys.stderr)
        sys.exit(2)
    repos = find_repos(repos_dir)
    if not repos:
        print(f"no git repos found in {repos_dir}", file=sys.stderr)
        sys.exit(2)
    workspaces = find_workspaces(workspace_dir)
    running = running_tmux_sessions()
    result = curses.wrapper(run, repos, workspaces, running)
    if result is None:
        sys.exit(1)
    mode, payload = result
    with output_path.open("w") as f:
        if mode == "resume":
            f.write(json.dumps({"mode": "resume", "dir_name": payload}) + "\n")
        else:
            primary, secondary, name = payload
            f.write(json.dumps({"mode": "new"}) + "\n")
            f.write(json.dumps({"primary": primary, "secondary": secondary}) + "\n")
            f.write(json.dumps({"name": name}) + "\n")


if __name__ == "__main__":
    main()
