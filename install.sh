#!/usr/bin/env bash
# install — idempotent setup for the WSL-only bits of crue:
#   - copy bundled notification sounds into ~/sounds/
#   - merge Stop + Notification hooks into ~/.claude/settings.json
#     (silent inside herdr, which plays its own sounds)
#
# Re-runnable; skips work already done. Leaves unrelated settings untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  echo "install: WSL not detected — sound hooks use powershell.exe. Aborting." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "install: jq required (sudo apt install jq)" >&2; exit 1; }
command -v wslpath >/dev/null 2>&1 || { echo "install: wslpath required (WSL)" >&2; exit 1; }

# --- 1. Sounds --------------------------------------------------------------
mkdir -p "$HOME/sounds"
for src in "$SCRIPT_DIR/assets/sounds"/*.wav; do
  [[ -f "$src" ]] || continue
  dest="$HOME/sounds/$(basename "$src")"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    echo "install: $(basename "$src") already in ~/sounds/"
  else
    cp "$src" "$dest"
    echo "install: copied $(basename "$src") → ~/sounds/"
  fi
done

# --- 2. Claude hooks --------------------------------------------------------
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo "{}" > "$SETTINGS"

play() {
  echo 'powershell.exe -NoProfile -Command "(New-Object Media.SoundPlayer '"'"'$(wslpath -w ~/sounds/'"$1"')'"'"').PlaySync()"'
}
# Inside herdr (HERDR_ENV=1) the hooks stay quiet and herdr's own sounds play.
herdr_guard='[ "${HERDR_ENV:-}" = 1 ] || '
stop_cmd="$herdr_guard$(play mixkit-correct-answer-tone-2870.wav)"
notif_cmd="$herdr_guard$(play mixkit-bell-notification-933.wav)"
# Commands written by earlier versions of this script; replaced, not duplicated.
old_stop_cmd="$(play mixkit-correct-answer-tone-2870.wav)"
old_notif_cmd="$(play mixkit-bell-notification-933.wav)"

tmp=$(mktemp)
jq \
  --arg stop_cmd "$stop_cmd" \
  --arg notif_cmd "$notif_cmd" \
  --arg old_stop_cmd "$old_stop_cmd" \
  --arg old_notif_cmd "$old_notif_cmd" \
  '
  def drop_hook(event; cmd):
    if .hooks[event] then
      .hooks[event] |= (map(.hooks |= map(select(.command != cmd)))
                        | map(select((.hooks | length) > 0)))
    else . end;
  def ensure_hook(event; cmd):
    .hooks //= {} |
    .hooks[event] //= [] |
    if ([.hooks[event][]?.hooks[]?.command] | any(. == cmd)) then .
    else .hooks[event] += [{"hooks":[{"type":"command","async":true,"command":cmd}]}]
    end;
  drop_hook("Stop"; $old_stop_cmd) | drop_hook("Notification"; $old_notif_cmd)
  | ensure_hook("Stop"; $stop_cmd) | ensure_hook("Notification"; $notif_cmd)
  ' "$SETTINGS" > "$tmp"

if cmp -s "$tmp" "$SETTINGS"; then
  echo "install: Stop + Notification hooks already present in $SETTINGS"
  rm -f "$tmp"
else
  mv "$tmp" "$SETTINGS"
  echo "install: merged Stop + Notification hooks into $SETTINGS"
fi

echo "install: done."
