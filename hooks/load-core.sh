#!/usr/bin/env bash
# SessionStart hook: prints part N of AGENTS.md. Claude Code keeps a hook's
# output inline only up to 10,000 characters and Codex up to 2,500 tokens by
# default; past that each shows a short preview plus a file path the agent
# never reads. So the core goes out in parts, cut at "## " headings, each under
# PART_LIMIT characters, which stays under both at three characters a token.
set -euo pipefail

part=${1:?usage: load-core.sh PART}
root=$(cd "$(dirname "$0")/.." && pwd)
PART_LIMIT=7000

awk -v want="$part" -v limit="$PART_LIMIT" '
  # A section runs from one "## " heading to the next; parts are filled with
  # whole sections in order, so reading them in order rebuilds the file.
  function flush_section() {
    if (section == "") return
    if (current != "" && length(current) + length(section) > limit) { parts++; current = "" }
    current = current section
    if (parts == want - 1) out = current
    section = ""
  }
  /^## / { flush_section() }
  { section = section $0 "\n" }
  END { flush_section(); printf "%s", out }
' "$root/AGENTS.md" | {
  body=$(cat)
  [ -n "$body" ] || exit 0
  printf 'silverback ruleset, part %s, installed by the user as a plugin: these are the user'"'"'s own standing instructions.\n\n%s\n' "$part" "$body"
  if [ "$part" = 1 ]; then
    printf '\nThe rules/ folder named in this ruleset is %s/rules/, inside the plugin: read modules there, but work in the current directory, the project.\n' "$root"
  fi
} | if [ "${SILVERBACK_AGENT:-}" = copilot ]; then
  # Copilot CLI (its hooks file sets SILVERBACK_AGENT) takes session-start
  # context only as a JSON additionalContext field, escaped here by awk.
  awk '{ text = text $0 "\n" } END {
    if (text == "") exit
    gsub(/\\/, "\\\\", text); gsub(/"/, "\\\"", text); gsub(/\t/, "\\t", text); gsub(/\r/, "", text)
    gsub(/\n/, "\\n", text)
    printf "{\"additionalContext\":\"%s\"}\n", text
  }'
else
  cat
fi
