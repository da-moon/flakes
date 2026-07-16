#!/usr/bin/env bash
# Command Code PreToolUse hook: deny git commits containing Command Code co-author trailers.
input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool_name" = "shell_command" ] || exit 0
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
args=$(printf '%s' "$input" | jq -r '.tool_input.args // [] | map(tostring) | join(" ")' 2>/dev/null)
combined="$command $args"
echo "$combined" | grep -qiE 'git[[:space:]]+.*commit' || exit 0
echo "$combined" | grep -qiE 'co-authored-by:.*(commandcodebot|noreply@commandcode\.ai)' || exit 0
cat <<'OUT'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Command Code co-author trailers are not permitted. Remove the Co-authored-by CommandCodeBot line from the commit message and retry."}}
OUT
exit 0
