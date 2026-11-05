"""Multiplexer backend helpers for the crue pickers (mirror of crue_mux.sh).

herdr is used inside a herdr pane (HERDR_ENV=1), tmux everywhere else;
CRUE_MUX=herdr|tmux forces one.
"""
import json
import os
import shutil
import subprocess


def backend() -> str:
    forced = os.environ.get("CRUE_MUX", "")
    if forced in ("herdr", "tmux"):
        return forced
    if os.environ.get("HERDR_ENV") == "1" and shutil.which("herdr"):
        return "herdr"
    return "tmux"


def _run(cmd, timeout=3):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    return r if r.returncode == 0 else None


def _herdr_workspaces() -> list[dict]:
    r = _run(["herdr", "workspace", "list"])
    if r is None:
        return []
    try:
        return json.loads(r.stdout)["result"]["workspaces"]
    except (ValueError, KeyError, TypeError):
        return []


def list_sessions() -> set[str]:
    """Names of live crue-capable sessions (tmux sessions / herdr workspaces)."""
    if backend() == "herdr":
        return {w["label"] for w in _herdr_workspaces() if w.get("label")}
    r = _run(["tmux", "list-sessions", "-F", "#{session_name}"])
    if r is None:
        return set()
    return {line.strip() for line in r.stdout.splitlines() if line.strip()}


def current_session():
    """Name of the session this process runs in, or None."""
    if backend() == "herdr":
        ws_id = os.environ.get("HERDR_WORKSPACE_ID")
        if not ws_id:
            return None
        for w in _herdr_workspaces():
            if w.get("workspace_id") == ws_id:
                return w.get("label")
        return None
    if not os.environ.get("TMUX"):
        return None
    r = _run(["tmux", "display-message", "-p", "#S"])
    return r.stdout.strip() if r else None
