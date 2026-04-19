#!/usr/bin/env bash
# install — idempotent setup for the WSL-only bits of crue:
#   - copy bundled notification sounds into ~/sounds/
#   - merge Stop + Notification hooks into ~/.claude/settings.json
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

stop_cmd='powershell.exe -NoProfile -Command "(New-Object Media.SoundPlayer '"'"'$(wslpath -w ~/sounds/mixkit-correct-answer-tone-2870.wav)'"'"').PlaySync()"'
notif_cmd='powershell.exe -NoProfile -Command "(New-Object Media.SoundPlayer '"'"'$(wslpath -w ~/sounds/mixkit-bell-notification-933.wav)'"'"').PlaySync()"'

tmp=$(mktemp)
jq \
  --arg stop_cmd "$stop_cmd" \
  --arg notif_cmd "$notif_cmd" \
  '
  def ensure_hook(event; cmd):
    .hooks //= {} |
    .hooks[event] //= [] |
    if ([.hooks[event][]?.hooks[]?.command] | any(. == cmd)) then .
    else .hooks[event] += [{"hooks":[{"type":"command","async":true,"command":cmd}]}]
    end;
  ensure_hook("Stop"; $stop_cmd) | ensure_hook("Notification"; $notif_cmd)
  ' "$SETTINGS" > "$tmp"

if cmp -s "$tmp" "$SETTINGS"; then
  echo "install: Stop + Notification hooks already present in $SETTINGS"
  rm -f "$tmp"
else
  mv "$tmp" "$SETTINGS"
  echo "install: merged Stop + Notification hooks into $SETTINGS"
fi

echo "install: done."
