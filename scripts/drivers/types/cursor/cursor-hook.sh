#!/usr/bin/env bash
# cursor-hook.sh — Cursor (IDE and cursor-agent) postToolUse / stop hook that
# hands new agmsg messages to the conversation holding a Cursor seat
# (fork: tsukumijima/agmsg).
#
# Cursor's turn mode used to be a rule file asking the model to check the inbox
# after each tool call. A Cursor conversation that has finished its turn runs no
# tool and reads no rule, so a reply that arrives while it waits never reaches
# it. Cursor's own hooks close both gaps (measured 2026-11-01 on cursor-agent
# 2026.10.22, interactive mode):
#   - postToolUse returning {"additional_context": ...} puts text into the
#     running turn;
#   - stop returning {"followup_message": ...} submits it as the next prompt, so
#     a stop hook that waits for unread mail wakes the conversation when it lands.
#
# Which conversation holds which seat is read from the shell commands it runs:
# `join.sh <team> <name> cursor ...`, or `send.sh`/`inbox.sh <team> <name>` for a
# name registered as a cursor seat, binds the conversation to that seat;
# `leave.sh <team> <name>` or `reset.sh <project> cursor <name>` unbinds it. A
# conversation with no seat gets nothing from either hook, so ordinary Cursor
# work is never held at stop.
#
# Usage (from .cursor/hooks.json, hook JSON on stdin): cursor-hook.sh post|stop
set -u

KIND="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/compat.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/storage.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/sqlpath.sh"

# How long a stop hook waits for unread mail. hooks.json gives the stop entry a
# timeout above this, so Cursor never kills the wait first.
WAIT_SECONDS="${AGMSG_CURSOR_WAIT_SECONDS:-1800}"
POLL_SECONDS="${AGMSG_CURSOR_POLL_SECONDS:-3}"

emit() { printf '%s\n' "$1"; exit 0; }

case "$KIND" in post|stop) ;; *) emit '{}' ;; esac

INPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/agmsg-cursor.XXXXXX")"
trap 'rm -f "$INPUT_FILE"' EXIT
cat > "$INPUT_FILE"
INPUT_SQL="$(agmsg_sql_readfile_path "$INPUT_FILE")"
json_field() {   # <json path> — a field of the hook input, empty when absent or unreadable
  agmsg_sqlite_mem "SELECT COALESCE(json_extract(readfile('$INPUT_SQL'), '$1'), '');" 2>/dev/null || true
}

CONVERSATION="$(json_field '$.conversation_id')"
case "$CONVERSATION" in ''|*[!A-Za-z0-9_-]*) emit '{}' ;; esac
SEAT_FILE="$SKILL_DIR/run/cursor-seat.$CONVERSATION"

# The seat file: line 1 = team, line 2 = agent, line 3 = checksum of the unread
# set last announced, line 4 = the token of the stop hook currently waiting.
read_seat() {
  SEAT_TEAM="" SEAT_AGENT="" SEAT_NOTIFIED="" SEAT_WAITER=""
  [ -f "$SEAT_FILE" ] || return 1
  { IFS= read -r SEAT_TEAM; IFS= read -r SEAT_AGENT; IFS= read -r SEAT_NOTIFIED; IFS= read -r SEAT_WAITER; } < "$SEAT_FILE" || true
  [ -n "$SEAT_TEAM" ] && [ -n "$SEAT_AGENT" ]
}
write_seat() {   # <team> <agent> <notified> <waiter>
  mkdir -p "$SKILL_DIR/run"
  local tmp="$SEAT_FILE.$$"
  printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "$tmp" && mv "$tmp" "$SEAT_FILE"
}

is_cursor_seat() {   # <team> <agent>
  local config="$SKILL_DIR/teams/$1/config.json" sql
  [ -f "$config" ] || return 1
  sql="$(agmsg_sql_readfile_path "$config")"
  [ "$(agmsg_sqlite_mem "SELECT count(*) FROM json_each(json_extract(readfile('$sql'), '\$.agents.\"$2\".registrations')) WHERE json_extract(value, '\$.type') = 'cursor';" 2>/dev/null)" -gt 0 ] 2>/dev/null
}

unread_jsonl() {   # <team> <agent>
  agmsg_storage_load
  storage_list_unread "$1" "$2" 2>/dev/null || true
}

notice() {   # <team> <agent> <unread jsonl> — the text handed to the conversation
  local count senders
  count="$(printf '%s\n' "$3" | grep -c '.')"
  senders="$(printf '%s\n' "$3" | grep -o '"from":"[^"]*"' | cut -d'"' -f4 | sort -u | paste -sd, -)"
  printf '[agmsg] %s has %s unread message(s) in team %s from %s. Read them with %s/scripts/inbox.sh %s %s and reply if needed.' \
    "$2" "$count" "$1" "$senders" "$SKILL_DIR" "$1" "$2"
}

json_out() {   # <key> <text>
  local lit
  lit="$(printf '%s' "$2" | sed "s/'/''/g")"
  emit "$(agmsg_sqlite_mem "SELECT json_object('$1', '$lit');")"
}

NAME='[A-Za-z0-9._-]+'
Q="['\"]?"
S='[[:space:]]+'

if [ "$KIND" = post ]; then
  COMMAND="$(json_field '$.tool_input.command')"
  [ -n "$COMMAND" ] || COMMAND="$(json_field '$.tool_input')"
  read_seat || true
  # Unbind first, so a command that leaves and joins in one line ends on the join.
  if [[ "$COMMAND" =~ leave\.sh$Q$S$Q($NAME)$Q$S$Q($NAME) ]] \
     && [ "${BASH_REMATCH[1]}" = "$SEAT_TEAM" ] && [ "${BASH_REMATCH[2]}" = "$SEAT_AGENT" ]; then
    rm -f "$SEAT_FILE"; SEAT_TEAM=""
  fi
  if [[ "$COMMAND" =~ reset\.sh$S[^[:space:]]+$S${Q}cursor$Q$S$Q($NAME) ]] && [ "${BASH_REMATCH[1]}" = "$SEAT_AGENT" ]; then
    rm -f "$SEAT_FILE"; SEAT_TEAM=""
  fi
  if [[ "$COMMAND" =~ join\.sh$Q$S$Q($NAME)$Q$S$Q($NAME)$Q$S${Q}cursor ]]; then
    SEAT_TEAM="${BASH_REMATCH[1]}" SEAT_AGENT="${BASH_REMATCH[2]}" SEAT_NOTIFIED=""
  elif [[ "$COMMAND" =~ (send|inbox)\.sh$Q$S$Q($NAME)$Q$S$Q($NAME) ]] \
       && [ "${BASH_REMATCH[3]}" != "$SEAT_AGENT" ] && is_cursor_seat "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; then
    SEAT_TEAM="${BASH_REMATCH[2]}" SEAT_AGENT="${BASH_REMATCH[3]}" SEAT_NOTIFIED=""
  fi
  [ -n "$SEAT_TEAM" ] || emit '{}'
  UNREAD="$(unread_jsonl "$SEAT_TEAM" "$SEAT_AGENT")"
  # The conversation is moving again, so any stop hook still waiting from the
  # previous turn stands down (an empty waiter token).
  if [ -z "$UNREAD" ]; then
    write_seat "$SEAT_TEAM" "$SEAT_AGENT" "" ""
    emit '{}'
  fi
  SUM="$(printf '%s' "$UNREAD" | cksum | cut -d' ' -f1)"
  write_seat "$SEAT_TEAM" "$SEAT_AGENT" "$SUM" ""
  # The same unread set is announced once, not after every tool call.
  [ "$SUM" = "$SEAT_NOTIFIED" ] && emit '{}'
  json_out additional_context "$(notice "$SEAT_TEAM" "$SEAT_AGENT" "$UNREAD")"
fi

# stop: wait for unread mail, then resume the conversation with a notice. A turn
# the user stopped, or one that ended in an error, is left alone.
read_seat || emit '{}'
[ "$(json_field '$.status')" = completed ] || emit '{}'
# When the user types while this hook waits, Cursor runs that prompt and this
# hook keeps waiting in the background (measured); the newest wait owns the seat
# and an older one stands down instead of resuming the conversation twice.
WAITER="$$-$(date +%s)"
write_seat "$SEAT_TEAM" "$SEAT_AGENT" "$SEAT_NOTIFIED" "$WAITER"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  current_waiter="$(sed -n '4p' "$SEAT_FILE" 2>/dev/null || true)"
  [ "$current_waiter" = "$WAITER" ] || emit '{}'
  UNREAD="$(unread_jsonl "$SEAT_TEAM" "$SEAT_AGENT")"
  if [ -n "$UNREAD" ]; then
    write_seat "$SEAT_TEAM" "$SEAT_AGENT" "$(printf '%s' "$UNREAD" | cksum | cut -d' ' -f1)" ""
    json_out followup_message "$(notice "$SEAT_TEAM" "$SEAT_AGENT" "$UNREAD")"
  fi
  # A seat that left the team while this waited is not waited for.
  if ! is_cursor_seat "$SEAT_TEAM" "$SEAT_AGENT" || [ "$(date +%s)" -ge "$deadline" ]; then
    write_seat "$SEAT_TEAM" "$SEAT_AGENT" "$SEAT_NOTIFIED" ""
    emit '{}'
  fi
  sleep "$POLL_SECONDS"
done
