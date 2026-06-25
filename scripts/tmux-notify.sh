#!/usr/bin/env bash
# claude-tmux-notify.nvim — Claude Code hook.
# Appends a notification event to a cache file that Neovim tails. Fires on the
# Notification (Claude waiting for input) and Stop (turn finished) hook events.
# Must never block Claude: always exits 0.

set -u

CACHE_FILE="${CLAUDE_TMUX_NOTIFY_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-tmux-notify.jsonl}"
mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true

input="$(cat)"

if command -v jq >/dev/null 2>&1; then
  event="$(printf '%s' "$input" | jq -r '.hook_event_name // "Notification"')"
  message="$(printf '%s' "$input" | jq -r '.message // empty')"
else
  # Minimal fallback parse (best effort, no jq).
  event="$(printf '%s' "$input" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
  message="$(printf '%s' "$input" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
  event="${event:-Notification}"
fi

# Default copy when the event carries no message (Stop has none).
if [ -z "$message" ]; then
  if [ "$event" = "Stop" ]; then
    message="Claude finished its turn"
  else
    message="Claude is waiting for your input"
  fi
fi

window_id=""
label=""
session=""
if [ -n "${TMUX:-}" ]; then
  info="$(tmux display-message -p -t "${TMUX_PANE:-}" -F '#{window_id}|#{window_index}:#{window_name}|#{session_name}' 2>/dev/null)"
  window_id="${info%%|*}"
  rest="${info#*|}"
  label="${rest%%|*}"
  session="${rest#*|}"
fi

if command -v jq >/dev/null 2>&1; then
  line="$(jq -nc \
    --arg event "$event" \
    --arg window_id "$window_id" \
    --arg label "$label" \
    --arg session "$session" \
    --arg message "$message" \
    '{event:$event, window_id:$window_id, label:$label, session:$session, message:$message}')"
else
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  line="{\"event\":\"$(esc "$event")\",\"window_id\":\"$(esc "$window_id")\",\"label\":\"$(esc "$label")\",\"session\":\"$(esc "$session")\",\"message\":\"$(esc "$message")\"}"
fi

printf '%s\n' "$line" >> "$CACHE_FILE" 2>/dev/null || true

exit 0
