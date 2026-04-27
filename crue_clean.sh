#!/usr/bin/env bash
# crue-clean — remove one or more crue sessions.
set -euo pipefail

# If we end up killing the tmux session hosting this pane, tmux will SIGHUP
# every process in that session. Keep going.
trap '' HUP

SCRIPTS_DIR="/home/jucci-linux/source/repos/crue-cli"
REPOS_DIR="/home/jucci-linux/source/repos"
WORKTREES_DIR="$REPOS_DIR/.worktrees"

# --- 1. Run the picker ------------------------------------------------------
picker_out=$(mktemp)
trap 'rm -f "$picker_out"' EXIT

set +e
python3 "$SCRIPTS_DIR/crue_clean_picker.py" "$WORKTREES_DIR" "$REPOS_DIR" "$picker_out"
rc=$?
set -e

if [[ $rc -eq 2 ]]; then
  exit 0
fi
if [[ $rc -ne 0 ]]; then
  echo "crue-clean: cancelled" >&2
  exit 1
fi

mapfile -t lines < "$picker_out"
if [[ ${#lines[@]} -lt 2 ]]; then
  echo "crue-clean: nothing selected" >&2
  exit 1
fi
mode="${lines[0]}"
selected=("${lines[@]:1}")
if [[ ${#selected[@]} -eq 0 ]]; then
  echo "crue-clean: nothing selected" >&2
  exit 1
fi
force=0
if [[ "$mode" == "force" ]]; then
  force=1
  echo "crue-clean: FORCE mode — dirty worktrees and unmerged branches will be removed"
fi

# --- 2. If cleaning the current session, move it to the end of the list -----
current_session=""
if [[ -n "${TMUX:-}" ]]; then
  current_session=$(tmux display-message -p '#S' 2>/dev/null || true)
fi

if [[ -n "$current_session" ]]; then
  head_sessions=()
  tail_sessions=()
  for s in "${selected[@]}"; do
    if [[ "$s" == "$current_session" ]]; then
      tail_sessions+=("$s")
    else
      head_sessions+=("$s")
    fi
  done
  selected=("${head_sessions[@]}" "${tail_sessions[@]}")
fi

# --- 3. If the current session is in the list, move the client elsewhere ----
for s in "${selected[@]}"; do
  if [[ "$s" == "$current_session" ]]; then
    other=$(tmux list-sessions -F '#S' 2>/dev/null | grep -vx "$current_session" | head -n1 || true)
    if [[ -n "$other" ]]; then
      echo "crue-clean: switching client to '$other' before cleaning '$current_session'"
      tmux switch-client -t "$other" || true
    else
      echo "crue-clean: no other tmux session; detaching client before cleaning '$current_session'"
      tmux detach-client || true
    fi
    break
  fi
done

# --- 4. Clean each session in sequence --------------------------------------
for s in "${selected[@]}"; do
  echo "=== $s ==="
  workspace="$WORKTREES_DIR/$s"

  if [[ ! -d "$workspace" ]]; then
    echo "  (no workspace dir — session already partially cleaned?)"
    tmux kill-session -t "$s" 2>/dev/null && echo "  killed tmux session" || true
    continue
  fi

  # Capture the nvim session UUID before we start deleting things.
  nvim_session_uuid=""
  if [[ -f "$workspace/.crue-session-id" ]]; then
    nvim_session_uuid=$(<"$workspace/.crue-session-id")
  fi

  # Iterate real worktree subdirs (each has a .git file pointing at its main repo).
  for wt in "$workspace"/*; do
    [[ -d "$wt" ]] || continue
    [[ -e "$wt/.git" ]] || continue
    repo=$(basename "$wt")

    branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)

    # Dirty check (skipped entirely when forcing)
    if [[ $force -eq 0 ]]; then
      dirty=0
      if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        dirty=1
      fi
      if [[ $dirty -eq 0 && -n "$branch" ]]; then
        on_origin=0
        for upstream in "origin/$branch" "origin/HEAD"; do
          if git -C "$wt" merge-base --is-ancestor "$branch" "$upstream" 2>/dev/null; then
            on_origin=1; break
          fi
        done
        if [[ $on_origin -eq 0 ]]; then
          dirty=1
        fi
      fi
      if [[ $dirty -eq 1 ]]; then
        echo "  [$repo] SKIP (dirty or unpushed) — worktree kept at $wt"
        continue
      fi
    fi

    if [[ $force -eq 1 ]]; then
      if git -C "$REPOS_DIR/$repo" worktree remove --force "$wt" 2>/dev/null; then
        echo "  [$repo] force-removed worktree"
      else
        echo "  [$repo] FAILED worktree remove --force — skipping branch delete"
        continue
      fi
    else
      if git -C "$REPOS_DIR/$repo" worktree remove "$wt" 2>/dev/null; then
        echo "  [$repo] removed worktree"
      else
        echo "  [$repo] FAILED worktree remove — skipping branch delete"
        continue
      fi
    fi

    if [[ -n "$branch" ]]; then
      if [[ $force -eq 1 ]]; then
        if git -C "$REPOS_DIR/$repo" branch -D "$branch" >/dev/null 2>&1; then
          echo "  [$repo] force-deleted branch $branch"
        else
          echo "  [$repo] FAILED to delete branch $branch"
        fi
      else
        if git -C "$REPOS_DIR/$repo" branch -d "$branch" >/dev/null 2>&1; then
          echo "  [$repo] deleted branch $branch"
        else
          echo "  [$repo] kept branch $branch (not fully merged/pushed)"
        fi
      fi
    fi
  done

  # Prune the session folder if no live worktree remains. Any subdir with a
  # .git entry is still a live worktree (dirty/unpushed were skipped above).
  remaining=0
  for wt in "$workspace"/*; do
    [[ -d "$wt" ]] || continue
    if [[ -e "$wt/.git" ]]; then
      remaining=1
      break
    fi
  done
  if [[ $remaining -eq 1 ]]; then
    echo "  kept workspace $workspace (dirty worktrees still live there)"
  else
    rm -rf "$workspace"
    echo "  removed workspace $workspace"

    if [[ -n "$nvim_session_uuid" ]]; then
      nvim_session_file="$HOME/.local/share/nvim/crue-sessions/${nvim_session_uuid}.vim"
      if [[ -f "$nvim_session_file" ]]; then
        rm -f "$nvim_session_file"
        echo "  removed nvim session $nvim_session_uuid"
      fi
    fi
  fi

  # Kill the tmux session last (may SIGHUP us if this is the current session)
  if tmux has-session -t "$s" 2>/dev/null; then
    tmux kill-session -t "$s" && echo "  killed tmux session"
  fi
done

echo "crue-clean: done"
