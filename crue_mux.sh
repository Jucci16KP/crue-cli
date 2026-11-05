# crue_mux.sh — terminal multiplexer backend for crue (sourced, not executed).
#
# herdr is used when crue runs inside a herdr pane (HERDR_ENV=1); tmux is the
# fallback everywhere else. Set CRUE_MUX=herdr or CRUE_MUX=tmux to force one.
#
# A crue "session" is a tmux session or a herdr workspace, named/labelled after
# the session folder. Its four tmux windows become four herdr tabs.

crue_mux_backend() {
  case "${CRUE_MUX:-}" in
    herdr|tmux) echo "$CRUE_MUX"; return ;;
    "") ;;
    *) echo "crue: unknown CRUE_MUX='$CRUE_MUX' (use herdr or tmux)" >&2; return 1 ;;
  esac
  if [[ "${HERDR_ENV:-}" == 1 ]] && command -v herdr >/dev/null 2>&1; then
    echo herdr
  else
    echo tmux
  fi
}
CRUE_MUX_BACKEND=$(crue_mux_backend)

# --- herdr helpers ----------------------------------------------------------
# _json_get <dotted.path>: read one field from the JSON on stdin.
_json_get() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[k]
print(d)
' "$1"
}

# _herdr_ws_id <label>: workspace id for a label, empty if none.
_herdr_ws_id() {
  herdr workspace list 2>/dev/null | python3 -c '
import json, sys
label = sys.argv[1]
try:
    ws = json.load(sys.stdin)["result"]["workspaces"]
except Exception:
    sys.exit(0)
for w in ws:
    if w.get("label") == label:
        print(w["workspace_id"])
        break
' "$1"
}

# --- Public API -------------------------------------------------------------

# mux_has_session <name>
mux_has_session() {
  if [[ "$CRUE_MUX_BACKEND" == herdr ]]; then
    [[ -n "$(_herdr_ws_id "$1")" ]]
  else
    tmux has-session -t "$1" 2>/dev/null
  fi
}

# mux_current_session: name of the session this shell runs in, empty if none.
mux_current_session() {
  if [[ "$CRUE_MUX_BACKEND" == herdr ]]; then
    [[ -n "${HERDR_WORKSPACE_ID:-}" ]] || return 0
    herdr workspace get "$HERDR_WORKSPACE_ID" 2>/dev/null \
      | _json_get result.workspace.label 2>/dev/null || true
  else
    [[ -n "${TMUX:-}" ]] || return 0
    tmux display-message -p '#S' 2>/dev/null || true
  fi
}

# mux_build_session <name> <workdir> <nvim_cmd> <claude_cmd> [KEY=VALUE...]
# Creates the session with Neovim / Term / Claude / CLI, each starting in
# <workdir>, with the KEY=VALUE pairs in every shell's environment.
mux_build_session() {
  local session="$1" workdir="$2" nvim_cmd="$3" claude_cmd="$4"
  shift 4
  local kv

  if [[ "$CRUE_MUX_BACKEND" == herdr ]]; then
    local env_args=() out ws nvim_tab nvim_pane claude_pane
    for kv in "$@"; do env_args+=(--env "$kv"); done

    out=$(herdr workspace create --cwd "$workdir" --label "$session" "${env_args[@]}" --no-focus)
    ws=$(_json_get result.workspace.workspace_id <<<"$out")
    nvim_tab=$(_json_get result.tab.tab_id <<<"$out")
    nvim_pane=$(_json_get result.root_pane.pane_id <<<"$out")
    herdr tab rename "$nvim_tab" Neovim >/dev/null
    herdr pane run "$nvim_pane" "$nvim_cmd" >/dev/null

    herdr tab create --workspace "$ws" --cwd "$workdir" --label Term "${env_args[@]}" --no-focus >/dev/null

    out=$(herdr tab create --workspace "$ws" --cwd "$workdir" --label Claude "${env_args[@]}" --no-focus)
    claude_pane=$(_json_get result.root_pane.pane_id <<<"$out")
    herdr pane run "$claude_pane" "$claude_cmd" >/dev/null

    herdr tab create --workspace "$ws" --cwd "$workdir" --label CLI "${env_args[@]}" --no-focus >/dev/null
    herdr tab focus "$nvim_tab" >/dev/null
  else
    tmux new-session -d -s "$session" -n "Neovim" -c "$workdir"
    for kv in "$@"; do
      tmux set-environment -t "$session" "${kv%%=*}" "${kv#*=}"
    done
    # The first window's shell started before set-environment, so nvim_cmd
    # carries its own inline assignments.
    tmux send-keys -t "$session:Neovim" "$nvim_cmd" C-m
    tmux new-window -t "$session" -n "Term" -c "$workdir"
    tmux new-window -t "$session" -n "Claude" -c "$workdir"
    tmux send-keys -t "$session:Claude" "$claude_cmd" C-m
    tmux new-window -t "$session" -n "CLI" -c "$workdir"
    tmux select-window -t "$session:1"
  fi
}

# mux_attach <name>: bring the session to the front.
mux_attach() {
  local session="$1"
  if [[ "$CRUE_MUX_BACKEND" == herdr ]]; then
    local ws; ws=$(_herdr_ws_id "$session")
    [[ -n "$ws" ]] && herdr workspace focus "$ws" >/dev/null
    # Forced herdr from outside a herdr pane: attach a client now.
    if [[ "${HERDR_ENV:-}" != 1 ]]; then
      exec herdr
    fi
  elif [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

# mux_leave_session <name>: move this client off a session about to be killed.
mux_leave_session() {
  local current="$1"
  if [[ "$CRUE_MUX_BACKEND" == herdr ]]; then
    # herdr focuses a neighbouring workspace when the current one closes.
    return 0
  fi
  local other
  other=$(tmux list-sessions -F '#S' 2>/dev/null | grep -vx "$current" | head -n1 || true)
  if [[ -n "$other" ]]; then
    echo "crue-clean: switching client to '$other' before cleaning '$current'"
    tmux switch-client -t "$other" || true
  else
    echo "crue-clean: no other tmux session; detaching client before cleaning '$current'"
    tmux detach-client || true
  fi
}

# mux_kill_session <name>: returns non-zero if there was nothing to kill.
mux_kill_session() {
  if [[ "$CRUE_MUX_BACKEND" == herdr ]]; then
    local ws; ws=$(_herdr_ws_id "$1")
    [[ -n "$ws" ]] && herdr workspace close "$ws" >/dev/null
  else
    tmux kill-session -t "$1" 2>/dev/null
  fi
}
