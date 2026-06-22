#!/usr/bin/env bash
# crue — spin up or resume an isolated multi-repo worktree session in tmux.
set -euo pipefail

SCRIPTS_DIR="/home/jucci-linux/source/repos/crue-cli"
REPOS_DIR="/home/jucci-linux/source/repos"
WORKTREES_DIR="$REPOS_DIR/.worktrees"

picker_out=$(mktemp)
cleanup() { rm -f "$picker_out"; }
trap cleanup EXIT

# --- Global gitignore setup (idempotent) ------------------------------------
# Ensures crue + Claude scratch files never get committed. Runs on every crue
# invocation, but every step is a no-op after the first time.
setup_global_gitignore() {
  local excludes
  excludes=$(git config --global --get core.excludesfile 2>/dev/null || true)
  if [[ -z "$excludes" ]]; then
    excludes="$HOME/.gitignore_crue"
    git config --global core.excludesfile "$excludes"
  fi
  excludes="${excludes/#\~/$HOME}"
  mkdir -p "$(dirname "$excludes")"
  touch "$excludes"
  local pat
  for pat in ".claude/" ".crue-*"; do
    grep -qxF "$pat" "$excludes" || echo "$pat" >> "$excludes"
  done
}
setup_global_gitignore

# --- 1. Run the TUI picker ---------------------------------------------------
set +e
python3 "$SCRIPTS_DIR/crue_picker.py" "$REPOS_DIR" "$WORKTREES_DIR" "$picker_out"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  [[ $rc -eq 1 ]] && echo "crue: cancelled" >&2
  exit $rc
fi

# --- 2. Parse picker mode + payload -----------------------------------------
CRUE_MODE=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    first = f.readline()
print(json.loads(first).get("mode", ""))
' "$picker_out")

# --- attach_or_switch: connect terminal to a running tmux session -----------
attach_or_switch() {
  local session="$1"
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

# --- build_session: create tmux windows for a workspace ---------------------
# Args: session_name, workdir, claude_cmd, nvim_uuid (optional), nvim_mode (save|restore)
build_session() {
  local session="$1" workdir="$2" claude_cmd="$3" nvim_uuid="${4:-}" nvim_mode="${5:-save}"

  # Legacy crue sessions won't have an nvim session file yet — fall back to
  # save-mode so we create one from this point forward.
  if [[ -n "$nvim_uuid" && "$nvim_mode" == "restore" ]]; then
    if [[ ! -f "$HOME/.local/share/nvim/crue-sessions/${nvim_uuid}.vim" ]]; then
      nvim_mode="save"
    fi
  fi

  # Export CRUE_SESSION_UUID so every pane in this tmux session (including the
  # first Neovim shell) inherits it. Also keep an inline assignment in the
  # send-keys command as a belt-and-suspenders fallback.
  if [[ -n "$nvim_uuid" ]]; then
    export CRUE_SESSION_UUID="$nvim_uuid"
  fi

  tmux new-session -d -s "$session" -n "Neovim" -c "$workdir"
  if [[ -n "$nvim_uuid" ]]; then
    tmux set-environment -t "$session" CRUE_SESSION_UUID "$nvim_uuid"
  fi
  if [[ -n "$nvim_uuid" && "$nvim_mode" == "restore" ]]; then
    tmux send-keys -t "$session:Neovim" "CRUE_SESSION_UUID=$nvim_uuid nvim '+AutoSession restore $nvim_uuid'" C-m
  elif [[ -n "$nvim_uuid" ]]; then
    tmux send-keys -t "$session:Neovim" "CRUE_SESSION_UUID=$nvim_uuid nvim '+AutoSession save $nvim_uuid' ." C-m
  else
    tmux send-keys -t "$session:Neovim" "nvim ." C-m
  fi

  tmux new-window -t "$session" -n "Term" -c "$workdir"

  tmux new-window -t "$session" -n "Claude" -c "$workdir"
  tmux send-keys -t "$session:Claude" "$claude_cmd" C-m

  tmux new-window -t "$session" -n "CLI" -c "$workdir"

  tmux select-window -t "$session:1"
}

# --- touch_session_meta: record now() as last_opened in .crue-meta.json -----
# Atomic read-modify-write so any other metadata keys are preserved.
touch_session_meta() {
  local workdir="$1"
  CRUE_META_WORKDIR="$workdir" python3 - <<'PY'
import json, os, tempfile, datetime
workdir = os.environ["CRUE_META_WORKDIR"]
path = os.path.join(workdir, ".crue-meta.json")
try:
    with open(path) as f:
        data = json.load(f)
        if not isinstance(data, dict):
            data = {}
except (FileNotFoundError, ValueError):
    data = {}
data["last_opened"] = datetime.datetime.now().isoformat(timespec="seconds")
fd, tmp = tempfile.mkstemp(dir=workdir, prefix=".crue-meta.json.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

# ============================================================================
# RESUME PATH
# ============================================================================
if [[ "$CRUE_MODE" == "resume" ]]; then
  dir_name=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    first = f.readline()
print(json.loads(first).get("dir_name", ""))
' "$picker_out")

  if [[ -z "$dir_name" ]]; then
    echo "crue: resume selected but no dir_name in picker output" >&2
    exit 1
  fi

  workdir="$WORKTREES_DIR/$dir_name"
  session="$dir_name"

  # Already running: just reconnect.
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "crue: attaching to existing session '$session'"
    touch_session_meta "$workdir"
    attach_or_switch "$session"
    exit 0
  fi

  # Workspace exists but tmux session is gone — rebuild windows.
  if [[ ! -d "$workdir" ]]; then
    echo "crue: workspace '$workdir' not found" >&2
    exit 1
  fi

  echo "crue: rebuilding tmux session for '$dir_name'"
  if [[ -f "$workdir/.crue-session-id" ]]; then
    session_id=$(<"$workdir/.crue-session-id")
    claude_cmd="claude --resume $session_id"
  else
    session_id=""
    claude_cmd="claude --continue"
  fi

  touch_session_meta "$workdir"
  build_session "$session" "$workdir" "$claude_cmd" "$session_id" "restore"
  echo "crue: session '$session' ready at $workdir"
  attach_or_switch "$session"
  exit 0
fi

# ============================================================================
# NEW SESSION PATH
# ============================================================================
if [[ "$CRUE_MODE" != "new" ]]; then
  echo "crue: unexpected picker mode '$CRUE_MODE'" >&2
  exit 1
fi

# Parse the two remaining JSON lines (flags + name).
eval "$(python3 -c '
import json, shlex, sys
with open(sys.argv[1]) as f:
    lines = f.read().splitlines()
if len(lines) < 3:
    sys.exit("crue: picker output malformed for new-session mode")
flags = json.loads(lines[1])
meta  = json.loads(lines[2])
primary = flags.get("primary", [])
secondary = flags.get("secondary", [])
name = meta.get("name", "")
print("CRUE_PRIMARY=(" + shlex.join(primary) + ")")
print("CRUE_SECONDARY=(" + shlex.join(secondary) + ")")
print("CRUE_NAME=" + shlex.quote(name))
' "$picker_out")"

# --- Resolve / generate the branch + dir name -------------------------------
if [[ -z "$CRUE_NAME" ]]; then
  generated=$(python3 -c "import sys; sys.path.insert(0, '$SCRIPTS_DIR'); from crue_words import pick; print(pick())")
  branch_name="ju/$generated"
else
  branch_name="$CRUE_NAME"
fi
dir_name="${branch_name//\//-}"

echo "crue: branch=$branch_name  session=$dir_name"

# --- Discover all git repos --------------------------------------------------
# find at maxdepth 1 with `.git` test naturally skips $WORKTREES_DIR (no .git).
mapfile -t all_repos < <(
  find "$REPOS_DIR" -mindepth 1 -maxdepth 1 -type d \
    -exec test -e '{}/.git' \; -print 2>/dev/null \
  | xargs -n1 basename | sort
)

if [[ ${#all_repos[@]} -eq 0 ]]; then
  echo "crue: no git repos found under $REPOS_DIR" >&2
  exit 1
fi

# --- Validate preconditions (fail fast, no partial state) -------------------
if tmux has-session -t "$dir_name" 2>/dev/null; then
  echo "crue: tmux session '$dir_name' already exists" >&2
  exit 1
fi
if [[ -e "$WORKTREES_DIR/$dir_name" ]]; then
  echo "crue: worktree folder '$WORKTREES_DIR/$dir_name' already exists" >&2
  exit 1
fi

# --- Create the session folder + all worktrees in parallel ------------------
mkdir -p "$WORKTREES_DIR/$dir_name"
workdir="$WORKTREES_DIR/$dir_name"

echo "crue: creating ${#all_repos[@]} worktrees (parallel, up to 8)..."
export CRUE_BRANCH="$branch_name" CRUE_WORKDIR="$workdir" CRUE_REPOS_DIR="$REPOS_DIR"
printf '%s\n' "${all_repos[@]}" | xargs -P 8 -I {} bash -c '
  repo="$1"
  default=$(git -C "$CRUE_REPOS_DIR/$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed "s|origin/||")
  if [[ -z "$default" ]]; then
    for try in main master; do
      if git -C "$CRUE_REPOS_DIR/$repo" rev-parse --verify "origin/$try" >/dev/null 2>&1; then
        default="$try"; break
      fi
    done
  fi
  if [[ -z "$default" ]]; then
    echo "[$repo] SKIP: no origin/HEAD or origin/{main,master}" >&2
    exit 0
  fi
  if git -C "$CRUE_REPOS_DIR/$repo" worktree add -b "$CRUE_BRANCH" \
       "$CRUE_WORKDIR/$repo" "origin/$default" >/dev/null 2>&1; then
    echo "[$repo] + on $default"
  else
    echo "[$repo] FAILED worktree add" >&2
  fi
' _ {}

# --- Persist a Claude session id so we can resume later ---------------------
session_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
echo "$session_id" > "$workdir/.crue-session-id"

# --- Grant reads across ~/source and pre-accept the trust dialog ------------
mkdir -p "$workdir/.claude"
cat > "$workdir/.claude/settings.local.json" <<EOF
{
  "permissions": {
    "allow": [
      "Read(//$HOME/source/**)"
    ]
  },
  "additionalDirectories": [
    "$HOME/source"
  ]
}
EOF

# Pre-accept the workspace trust dialog by registering $workdir in ~/.claude.json.
# Atomic: read -> modify dict -> write to temp -> rename.
CRUE_WORKDIR="$workdir" python3 - <<'PY'
import json, os, tempfile
path = os.path.expanduser("~/.claude.json")
workdir = os.environ["CRUE_WORKDIR"]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
projects = data.setdefault("projects", {})
entry = projects.setdefault(workdir, {})
entry["hasTrustDialogAccepted"] = True
entry.setdefault("hasCompletedProjectOnboarding", True)
dir_ = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".claude.json.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY

# --- Build Claude prompt if any repo was flagged ----------------------------
have_primary=0
have_secondary=0
primary_str=""
secondary_str=""
if [[ ${#CRUE_PRIMARY[@]} -gt 0 && -n "${CRUE_PRIMARY[0]:-}" ]]; then
  have_primary=1
  primary_str=$(printf "%s, " "${CRUE_PRIMARY[@]}")
  primary_str="${primary_str%, }"
fi
if [[ ${#CRUE_SECONDARY[@]} -gt 0 && -n "${CRUE_SECONDARY[0]:-}" ]]; then
  have_secondary=1
  secondary_str=$(printf "%s, " "${CRUE_SECONDARY[@]}")
  secondary_str="${secondary_str%, }"
fi

prompt_file=""
if [[ $have_primary -eq 1 || $have_secondary -eq 1 ]]; then
  [[ $have_primary -eq 1 ]] || primary_str="(none specified)"
  [[ $have_secondary -eq 1 ]] || secondary_str="(none specified)"
  prompt_file="$workdir/.crue-prompt.txt"
  cat > "$prompt_file" <<EOF
We're starting a new focused work session.

Primary repos (main focus): $primary_str
Secondary repos (context / supporting): $secondary_str
(All other repos under ~/source/repos also have worktrees on this branch, but treat them as out-of-scope unless I bring them up.)

Every repo under ~/source/repos has a git worktree on branch \`$branch_name\`, co-located at:
  ~/source/repos/.worktrees/$dir_name/<repo>/

Treat these worktree paths as the source of truth for all edits — do not modify the main checkouts in ~/source/repos/<repo>/. Wait for my first instruction before taking action.
EOF
fi

# --- Build the tmux session -------------------------------------------------
session="$dir_name"
if [[ -n "$prompt_file" ]]; then
  claude_cmd="claude --session-id $session_id --name $(printf %q "$dir_name") \"\$(cat '$prompt_file')\""
else
  claude_cmd="claude --session-id $session_id --name $(printf %q "$dir_name")"
fi

touch_session_meta "$workdir"
build_session "$session" "$workdir" "$claude_cmd" "$session_id" "save"

echo "crue: session '$session' ready at $workdir"

attach_or_switch "$session"
