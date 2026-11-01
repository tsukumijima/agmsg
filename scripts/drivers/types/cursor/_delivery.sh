#!/usr/bin/env bash
# cursor delivery plug — Cursor CLI (cursor-agent) rule file (#131).
#
# The Cursor CLI auto-loads project rules from .cursor/rules/*.mdc. An .mdc with
# `alwaysApply: true` in its frontmatter is applied on every turn, which is the
# always-on instruction channel agmsg needs — the cursor-agent equivalent of
# gemini/opencode's markdown rules file. Only turn|off reach this function:
# cursor's manifest declares delivery_modes=turn off, so delivery.sh's central
# gate rejects monitor/both first. Uses resolve_hooks_file + SKILL_DIR from
# delivery.sh's sourced context.
agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"
  # Refuse before any write: an empty SKILL_DIR would render broken guidance
  # paths into the rule file, and the rm -f below removes the existing rule
  # file first -- an unreadable value must never be treated as "nothing to
  # preserve" (#1234 review).
  [ -n "${SKILL_DIR:-}" ] || { echo "agmsg_delivery_apply (cursor): SKILL_DIR is not set; refusing rather than writing a broken rule file" >&2; return 1; }
  local rule_file
  rule_file=$(resolve_hooks_file "$type" "$project")

  rm -f "$rule_file"

  if [ "$mode" = "turn" ]; then
    mkdir -p "$(dirname "$rule_file")"
    cat <<EOF > "$rule_file"
---
alwaysApply: true
---
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'

## Terminal/pane self-awareness
Asked about your own terminal, pane, or driver — or before using arrange/peek/poke
— run '$SKILL_DIR/scripts/where.sh' first and answer from its terminal=/capabilities=
fields. Never guess from environment variables or a grep/ps command; a driver
that IS present can be wrongly reported absent that way. Per-driver detail:
'$SKILL_DIR/scripts/drivers/terminals/<terminal>/README.md' (terminal= names which).

## Teammates: placement, status, and reaching them
Placement and status for a teammate: '$SKILL_DIR/scripts/team.sh' <team> — never a
stale memory of their last known pane. Act on one with '$SKILL_DIR/scripts/peek.sh'
/ 'poke.sh' / 'arrange.sh' <team> <name> directly, not a guess: its exit code
says whether it worked and, if not, why.
EOF
  fi
  _agmsg_cursor_hooks_apply "$project" "$mode"
}
agmsg_delivery_status() { rulefile_status "$@"; }

# Cursor hooks (fork: tsukumijima/agmsg). The rule file above only asks the model
# to check the inbox after a tool call; a conversation waiting for a reply runs
# no tool and never sees one. Turn mode therefore also installs cursor-hook.sh as
# the project's postToolUse and stop hooks in .cursor/hooks.json (Cursor's own
# hooks file, read by both the IDE and cursor-agent), and off removes them. Only
# entries that run cursor-hook.sh are touched; every other hook stays as it was.
_agmsg_cursor_hooks_apply() {   # <project> <mode>
  local project="$1" mode="$2"
  local hooks_file="$project/.cursor/hooks.json"
  local script="$SKILL_DIR/scripts/drivers/types/cursor/cursor-hook.sh"
  [ "$mode" = turn ] || [ -f "$hooks_file" ] || return 0
  local post_cmd stop_cmd
  if command -v cygpath >/dev/null 2>&1; then
    # Native Windows: Cursor starts the command without a POSIX shell, so name bash.
    local bash_path script_path
    bash_path="$(cygpath -m "$(command -v bash)")"
    script_path="$(cygpath -m "$script")"
    post_cmd="\"$bash_path\" \"$script_path\" post"
    stop_cmd="\"$bash_path\" \"$script_path\" stop"
  else
    post_cmd="'$script' post"
    stop_cmd="'$script' stop"
  fi
  mkdir -p "$(dirname "$hooks_file")"
  [ -f "$hooks_file" ] || printf '{"version":1,"hooks":{}}\n' > "$hooks_file"
  local src_sql tmp tmp_sql post_lit stop_lit add_post add_stop wrote
  src_sql="$(agmsg_sql_readfile_path "$hooks_file")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")"
  tmp_sql="$(agmsg_sql_readfile_path "$tmp")"
  post_lit="$(printf '%s' "$post_cmd" | sed "s/'/''/g")"
  stop_lit="$(printf '%s' "$stop_cmd" | sed "s/'/''/g")"
  add_post="" add_stop=""
  if [ "$mode" = turn ]; then
    add_post="UNION ALL SELECT json_object('command', '$post_lit', 'timeout', 10)"
    # The stop hook waits up to AGMSG_CURSOR_WAIT_SECONDS (1800) for mail; the
    # timeout stays above that, and loop_limit null lets every new message wake it.
    add_stop="UNION ALL SELECT json_object('command', '$stop_lit', 'timeout', 1900, 'loop_limit', json('null'))"
  fi
  wrote="$(agmsg_sqlite_mem "
    WITH base AS (SELECT CASE WHEN json_extract(readfile('$src_sql'), '\$.hooks') IS NULL
                              THEN json_set(readfile('$src_sql'), '\$.hooks', json('{}'))
                              ELSE readfile('$src_sql') END AS s),
    out AS (SELECT json_set(s,
      '\$.hooks.postToolUse', json((SELECT json_group_array(json(v)) FROM (
        SELECT value AS v FROM json_each(json_extract(s, '\$.hooks.postToolUse'))
          WHERE COALESCE(json_extract(value, '\$.command'), '') NOT LIKE '%cursor-hook.sh%'
        $add_post))),
      '\$.hooks.stop', json((SELECT json_group_array(json(v)) FROM (
        SELECT value AS v FROM json_each(json_extract(s, '\$.hooks.stop'))
          WHERE COALESCE(json_extract(value, '\$.command'), '') NOT LIKE '%cursor-hook.sh%'
        $add_stop)))) AS blob FROM base)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;")" || { rm -f "$tmp"; return 1; }
  [ "$wrote" = 1 ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$hooks_file"
}
