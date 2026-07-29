#!/usr/bin/env bash
# PreToolUse guard: reject git commits that carry Claude attribution.
#
# Blocks the signature lines only — "Co-Authored-By: Claude ...",
# "Generated with Claude Code", "Claude-Session: ...". A commit message that
# merely talks about Claude, or names the file CLAUDE.md, passes.
#
# Reads the hook payload on stdin, denies via PreToolUse JSON output.
#
# Known limits: it can only see the message when the message is in the command
# (-m, --trailer, a heredoc). `git commit -F file`, `--amend --no-edit`, and
# messages typed in an editor are invisible to it. A git commit-msg hook is the
# catch-all if those matter.

set -uo pipefail

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -n "$cmd" ] || exit 0

# Only look at commands that create a commit.
printf '%s' "$cmd" | grep -Eq '(^|[;&|`(]|[[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' || exit 0

attribution='co-authored-by:[[:space:]]*claude|generated with[[:space:]]*(\[|🤖)?[[:space:]]*claude code|claude-session:|co-authored-by:[[:space:]]*.*@anthropic\.com'

if printf '%s' "$cmd" | grep -Eqi "$attribution"; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"This repo does not accept Claude attribution in commit messages. Remove the 'Co-Authored-By: Claude', 'Generated with Claude Code', or 'Claude-Session' line and commit again. Guard: .claude/hooks/no-claude-attribution.sh"}}
JSON
  exit 0
fi

exit 0
