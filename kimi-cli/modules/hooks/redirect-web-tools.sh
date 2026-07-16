#!/usr/bin/env bash
# PreToolUse hook: intercepts WebSearch / FetchURL and redirects to the
# parallel-search MCP. Exits 2 so the stderr message is fed back as the
# denial reason, prompting a retry with the correct tool.

set -u

payload="$(cat)"

# Extract tool_name without requiring jq.
tool_name="$(printf '%s' "$payload" \
  | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 \
  | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"

case "$tool_name" in
  WebSearch)
    cat >&2 <<'EOF'
WebSearch is disabled in this environment. Use the parallel-search MCP instead:

  tool:  mcp__parallel-search__web_search_preview
  input: { "query": "<your query>" }

Re-issue the call with that tool. Do not fall back to WebSearch.
EOF
    exit 2
    ;;
  FetchURL)
    cat >&2 <<'EOF'
FetchURL is disabled in this environment. Use the parallel-search MCP instead:

  tool:  mcp__parallel-search__web_fetch
  input: { "urls": ["<url>", ...], "search_objective": "<what to extract>" }

Re-issue the call with that tool. Do not fall back to FetchURL.
EOF
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
