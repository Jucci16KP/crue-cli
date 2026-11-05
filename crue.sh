#!/usr/bin/env bash
# crue — spin up or resume an isolated multi-repo worktree session in herdr
# (when run inside herdr) or tmux.
#
#   crue                 picker: resume a session or start a new one
#   crue add <repo>...   add worktrees for more repos to the current session
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="${CRUE_REPOS_DIR:-$HOME/source/repos}"
WORKTREES_DIR="${CRUE_WORKTREES_DIR:-$REPOS_DIR/.worktrees}"

# shellcheck source=crue_mux.sh
source "$SCRIPTS_DIR/crue_mux.sh"

die() { echo "$*" >&2; exit 1; }

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

# --- Session metadata (.crue-meta.json) -------------------------------------
# write_session_meta <workdir> [key value]...
# Atomic read-modify-write that always stamps last_opened and preserves any
# other keys already in the file.
write_session_meta() {
  local workdir="$1"; shift
  CRUE_META_WORKDIR="$workdir" python3 - "$@" <<'PY'
import json, os, sys, tempfile, datetime
workdir = os.environ["CRUE_META_WORKDIR"]
path = os.path.join(workdir, ".crue-meta.json")
try:
    with open(path) as f:
        data = json.load(f)
        if not isinstance(data, dict):
            data = {}
except (FileNotFoundError, ValueError):
    data = {}
pairs = sys.argv[1:]
for k, v in zip(pairs[0::2], pairs[1::2]):
    data[k] = v
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

# session_branch <workdir>: the session's branch, from metadata or (for
# sessions created before it was recorded) from any worktree inside it.
session_branch() {
  local workdir="$1" branch wt
  branch=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("branch", ""))
except Exception:
    print("")
' "$workdir/.crue-meta.json")
  if [[ -z "$branch" ]]; then
    for wt in "$workdir"/*/; do
      [[ -e "$wt/.git" ]] || continue
      branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)
      [[ -n "$branch" ]] && break
    done
  fi
  [[ -n "$branch" ]] || return 1
  echo "$branch"
}

# --- create_worktree <repo> <branch> <dest> ---------------------------------
# Adds <dest> as a worktree of $CRUE_REPOS_DIR/<repo> on <branch>. Reuses the
# branch if it already exists; otherwise branches from a freshly fetched
# origin/<default>. Exported so xargs can run it in parallel.
create_worktree() {
  local repo="$1" branch="$2" dest="$3"
  local src="$CRUE_REPOS_DIR/$repo" default try

  if [[ -e "$dest" ]]; then
    echo "[$repo] already in this session"
    return 0
  fi

  if git -C "$src" show-ref --verify --quiet "refs/heads/$branch"; then
    if git -C "$src" worktree add "$dest" "$branch" >/dev/null 2>&1; then
      echo "[$repo] + existing branch $branch"
      return 0
    fi
    echo "[$repo] FAILED worktree add (is $branch checked out somewhere else?)" >&2
    return 1
  fi

  default=$(git -C "$src" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed "s|origin/||")
  if [[ -z "$default" ]]; then
    for try in main master; do
      if git -C "$src" rev-parse --verify "origin/$try" >/dev/null 2>&1; then
        default="$try"; break
      fi
    done
  fi
  if [[ -z "$default" ]]; then
    echo "[$repo] SKIP: no origin/HEAD or origin/{main,master}" >&2
    return 1
  fi
  # Worktrees are based on origin/<default>; without a fetch that ref is only as
  # fresh as the last manual fetch, so new sessions can start hundreds of commits
  # behind. Fetch just the default branch; warn-and-continue so offline still works.
  if ! git -C "$src" fetch origin "$default" --quiet 2>/dev/null; then
    echo "[$repo] WARN: fetch failed, using last-known origin/$default" >&2
  fi
  if git -C "$src" worktree add -b "$branch" "$dest" "origin/$default" >/dev/null 2>&1; then
    echo "[$repo] + on $default"
  else
    echo "[$repo] FAILED worktree add" >&2
    return 1
  fi
}
export -f create_worktree
export CRUE_REPOS_DIR="$REPOS_DIR"

# --- build_session: create the session's Neovim / Term / Claude / CLI -------
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

  local nvim_cmd env=("CRUE_WORKDIR=$workdir")
  if [[ -n "$nvim_uuid" ]]; then
    env+=("CRUE_SESSION_UUID=$nvim_uuid")
    if [[ "$nvim_mode" == "restore" ]]; then
      nvim_cmd="CRUE_SESSION_UUID=$nvim_uuid nvim '+AutoSession restore $nvim_uuid'"
    else
      nvim_cmd="CRUE_SESSION_UUID=$nvim_uuid nvim '+AutoSession save $nvim_uuid' ."
    fi
  else
    nvim_cmd="nvim ."
  fi

  mux_build_session "$session" "$workdir" "$nvim_cmd" "$claude_cmd" "${env[@]}"
}

# ============================================================================
# crue add <repo>...
# ============================================================================
crue_add() {
  local workdir="" rel
  # Prefer the session folder we're standing in; fall back to the session the
  # pane was created for.
  rel="${PWD#"$WORKTREES_DIR"/}"
  if [[ "$rel" != "$PWD" ]]; then
    workdir="$WORKTREES_DIR/${rel%%/*}"
  elif [[ -n "${CRUE_WORKDIR:-}" ]]; then
    workdir="$CRUE_WORKDIR"
  fi
  [[ -n "$workdir" && -d "$workdir" ]] \
    || die "crue add: not in a crue session (cd into $WORKTREES_DIR/<session> first)"

  local branch
  branch=$(session_branch "$workdir") \
    || die "crue add: can't tell which branch $(basename "$workdir") uses"

  if [[ $# -eq 0 ]]; then
    echo "usage: crue add <repo>..." >&2
    echo "repos without a worktree in $(basename "$workdir"):" >&2
    local r
    while IFS= read -r r; do
      [[ -e "$workdir/$r" ]] || echo "  $r" >&2
    done < <(find "$REPOS_DIR" -mindepth 1 -maxdepth 1 -type d \
               -exec test -e '{}/.git' \; -print 2>/dev/null | xargs -n1 basename | sort)
    exit 1
  fi

  local repo failed=0
  for repo in "$@"; do
    repo="${repo%/}"
    if [[ "$repo" == */* || ! -e "$REPOS_DIR/$repo/.git" ]]; then
      echo "[$repo] not a repo in $REPOS_DIR" >&2
      failed=1
      continue
    fi
    create_worktree "$repo" "$branch" "$workdir/$repo" || failed=1
  done
  write_session_meta "$workdir"
  exit "$failed"
}

case "${1:-}" in
  add) shift; crue_add "$@" ;;
  "") ;;
  -h|--help)
    sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) die "crue: unknown command '$1' (try: crue, crue add <repo>...)" ;;
esac

setup_global_gitignore

picker_out=$(mktemp)
cleanup() { rm -f "$picker_out"; }
trap cleanup EXIT

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
  if mux_has_session "$session"; then
    echo "crue: attaching to existing session '$session'"
    write_session_meta "$workdir"
    mux_attach "$session"
    exit 0
  fi

  # Workspace exists but the session is gone — rebuild it.
  if [[ ! -d "$workdir" ]]; then
    echo "crue: workspace '$workdir' not found" >&2
    exit 1
  fi

  echo "crue: rebuilding $CRUE_MUX_BACKEND session for '$dir_name'"
  if [[ -f "$workdir/.crue-session-id" ]]; then
    session_id=$(<"$workdir/.crue-session-id")
    claude_cmd="claude --resume $session_id"
  else
    session_id=""
    claude_cmd="claude --continue"
  fi

  write_session_meta "$workdir"
  build_session "$session" "$workdir" "$claude_cmd" "$session_id" "restore"
  echo "crue: session '$session' ready at $workdir"
  mux_attach "$session"
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

# --- Pick the repos that get worktrees ---------------------------------------
# Flagged repos (primary + secondary) only; more can be added later with
# `crue add <repo>`. Nothing flagged keeps the old behaviour: every repo.
have_primary=0
have_secondary=0
[[ ${#CRUE_PRIMARY[@]} -gt 0 && -n "${CRUE_PRIMARY[0]:-}" ]] && have_primary=1
[[ ${#CRUE_SECONDARY[@]} -gt 0 && -n "${CRUE_SECONDARY[0]:-}" ]] && have_secondary=1

lazy=0
if [[ $have_primary -eq 1 || $have_secondary -eq 1 ]]; then
  lazy=1
  wt_repos=()
  [[ $have_primary -eq 1 ]] && wt_repos+=("${CRUE_PRIMARY[@]}")
  [[ $have_secondary -eq 1 ]] && wt_repos+=("${CRUE_SECONDARY[@]}")
else
  # find at maxdepth 1 with `.git` test naturally skips $WORKTREES_DIR (no .git).
  mapfile -t wt_repos < <(
    find "$REPOS_DIR" -mindepth 1 -maxdepth 1 -type d \
      -exec test -e '{}/.git' \; -print 2>/dev/null \
    | xargs -n1 basename | sort
  )
fi

if [[ ${#wt_repos[@]} -eq 0 ]]; then
  echo "crue: no git repos found under $REPOS_DIR" >&2
  exit 1
fi

# --- Validate preconditions (fail fast, no partial state) -------------------
if mux_has_session "$dir_name"; then
  echo "crue: $CRUE_MUX_BACKEND session '$dir_name' already exists" >&2
  exit 1
fi
if [[ -e "$WORKTREES_DIR/$dir_name" ]]; then
  echo "crue: worktree folder '$WORKTREES_DIR/$dir_name' already exists" >&2
  exit 1
fi

# --- Create the session folder + worktrees in parallel ----------------------
mkdir -p "$WORKTREES_DIR/$dir_name"
workdir="$WORKTREES_DIR/$dir_name"
write_session_meta "$workdir" branch "$branch_name"

echo "crue: creating ${#wt_repos[@]} worktree(s) (parallel, up to 8)..."
printf '%s\n' "${wt_repos[@]}" | xargs -P 8 -I {} bash -c \
  'create_worktree "$1" "$2" "$3/$1" || true' _ {} "$branch_name" "$workdir"

# --- Persist a Claude session id so we can resume later ---------------------
session_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
echo "$session_id" > "$workdir/.crue-session-id"

# --- Grant reads across ~/source and pre-accept the trust dialog ------------
# `crue add` is pre-approved so Claude can pull in another repo's worktree.
mkdir -p "$workdir/.claude"
cat > "$workdir/.claude/settings.local.json" <<EOF
{
  "permissions": {
    "allow": [
      "Read(//$HOME/source/**)",
      "Bash($SCRIPTS_DIR/crue.sh add:*)"
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
prompt_file=""
if [[ $lazy -eq 1 ]]; then
  primary_str="(none specified)"
  secondary_str="(none specified)"
  if [[ $have_primary -eq 1 ]]; then
    primary_str=$(printf "%s, " "${CRUE_PRIMARY[@]}"); primary_str="${primary_str%, }"
  fi
  if [[ $have_secondary -eq 1 ]]; then
    secondary_str=$(printf "%s, " "${CRUE_SECONDARY[@]}"); secondary_str="${secondary_str%, }"
  fi
  show_workdir="${workdir/#$HOME/\~}"
  show_repos="${REPOS_DIR/#$HOME/\~}"
  prompt_file="$workdir/.crue-prompt.txt"
  cat > "$prompt_file" <<EOF
We're starting a new focused work session.

Primary repos (main focus): $primary_str
Secondary repos (context / supporting): $secondary_str

Only these repos have git worktrees in this session, all on branch \`$branch_name\`, at:
  $show_workdir/<repo>/

Treat these worktree paths as the source of truth for all edits. Do not modify the main checkouts in $show_repos/<repo>/; you may read them (and any other repo under $show_repos) for context.

If you need to change a repo that has no worktree here yet, first run this from $show_workdir:
  $SCRIPTS_DIR/crue.sh add <repo>
It creates $show_workdir/<repo>/ on the same branch; make your edits there. Tell me when you add a repo.

Wait for my first instruction before taking action.
EOF
fi

# --- Build the session ------------------------------------------------------
session="$dir_name"
if [[ -n "$prompt_file" ]]; then
  claude_cmd="claude --session-id $session_id --name $(printf %q "$dir_name") \"\$(cat '$prompt_file')\""
else
  claude_cmd="claude --session-id $session_id --name $(printf %q "$dir_name")"
fi

build_session "$session" "$workdir" "$claude_cmd" "$session_id" "save"

echo "crue: session '$session' ready at $workdir"

mux_attach "$session"
