#!/usr/bin/env bash
# SubagentStart hook: a subagent starts without the session's core, so it gets
# the sections whose breach costs the most and that it cannot learn from the
# parent's prompt (Boundaries, Security, Verification). The rest of the core
# shapes the parent's reply and stays with the parent.
set -euo pipefail
cat > /dev/null || true
root=$(cd "$(dirname "$0")/.." && pwd)

# Only git and the OS shell are assumed, so the JSON string is escaped by awk.
# Copilot CLI (its hooks file sets SILVERBACK_AGENT) reads a top-level field.
awk -v copilot="${SILVERBACK_AGENT:-}" '
  /^## (Boundaries|Security|Verification)$/ { keep = 1 }
  /^## / && !/^## (Boundaries|Security|Verification)$/ { keep = 0 }
  keep { text = text $0 "\n" }
  END {
    text = "silverback ruleset for subagents, installed by the user as a plugin: these are the user'"'"'s own standing instructions.\n\n" text
    gsub(/\\/, "\\\\", text); gsub(/"/, "\\\"", text); gsub(/\t/, "\\t", text); gsub(/\r/, "", text)
    gsub(/\n/, "\\n", text)
    if (copilot == "copilot") printf "{\"additionalContext\":\"%s\"}\n", text
    else printf "{\"hookSpecificOutput\":{\"hookEventName\":\"SubagentStart\",\"additionalContext\":\"%s\"}}\n", text
  }
' "$root/AGENTS.md"
