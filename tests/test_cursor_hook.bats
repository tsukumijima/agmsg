#!/usr/bin/env bats
# cursor-hook.sh: Cursor's postToolUse / stop hook for a conversation holding a
# Cursor seat (fork: tsukumijima/agmsg). Cursor's turn mode was a rule asking the
# model to check the inbox after a tool call; a conversation waiting for a reply
# runs no tool, so on 2026-11-01 a reply that arrived while it waited never
# reached it.

setup() {
  export TEST_SKILL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cursor-hook.XXXXXX")"
  TEST_SKILL_DIR="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$TEST_SKILL_DIR/scripts"
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/db" "$TEST_SKILL_DIR/project" "$TEST_SKILL_DIR/other"
  export AGMSG_CONFIG="$TEST_SKILL_DIR/config.json"
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db"
  export PROJECT="$TEST_SKILL_DIR/project"
  bash "$SCRIPTS/join.sh" t1 kimi-test cursor "$PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 fable-review claude-code "$TEST_SKILL_DIR/other" >/dev/null
  HOOK="$SCRIPTS/drivers/types/cursor/cursor-hook.sh"
}

teardown() { rm -rf "$TEST_SKILL_DIR"; }

@test "cursor-hook: a conversation without a seat is not held at stop" {
  bash "$SCRIPTS/send.sh" t1 fable-review kimi-test "please review" >/dev/null
  SECONDS=0
  run bash "$HOOK" stop <<<'{"conversation_id":"plain","status":"completed"}'
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
  [ "$SECONDS" -lt 5 ]
}

@test "cursor-hook: a conversation that joined as a cursor seat is resumed by unread mail at stop" {
  bash "$SCRIPTS/send.sh" t1 fable-review kimi-test "please review" >/dev/null
  run bash "$HOOK" post <<<"{\"conversation_id\":\"conv-1\",\"tool_name\":\"Shell\",\"tool_input\":{\"command\":\"bash ~/.agents/skills/agmsg/scripts/join.sh t1 kimi-test cursor $PROJECT\"}}"
  [ "$status" -eq 0 ]
  [[ "$output" == *additional_context* ]]
  run bash "$HOOK" stop <<<'{"conversation_id":"conv-1","status":"completed"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *followup_message* ]]
  [[ "$output" == *"inbox.sh t1 kimi-test"* ]]
}
