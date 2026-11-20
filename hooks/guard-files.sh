#!/usr/bin/env bash
# PreToolUse guard for file-editing tools (Edit, Write, MultiEdit,
# NotebookEdit, Codex apply_patch): an edit to a file that constrains the
# agent or to its persistent memory goes to the user to confirm. The shell
# guard sees only shell commands, and an edit tool reaches these files without
# one.
# Known ceiling: a file written through the shell (echo > AGENTS.md) is not seen.
set -euo pipefail

payload=$(cat)

# Codex sends a turn_id and cannot ask (see guard.sh), so there the edit is
# denied and the reason names the switch that turns this check off.
codex=0
if printf '%s' "$payload" | grep -q '"turn_id"[[:space:]]*:'; then codex=1; fi

# The edited paths: file_path, notebook_path or (Copilot CLI) path of an edit tool, or every
# "*** Add/Update/Delete File:" and "*** Move to:" line of an apply_patch.
# JSON-escaped backslashes become forward slashes.
paths=$(printf '%s' "$payload" |
  grep -oE '"(file_path|notebook_path|path)"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"|\*\*\* (Add|Update|Delete) File: ([^"\\]|\\[^n])*|\*\*\* Move to: ([^"\\]|\\[^n])*' |
  sed -E 's/^"(file_path|notebook_path|path)"[[:space:]]*:[[:space:]]*"//; s/"$//; s/^\*\*\* ((Add|Update|Delete) File|Move to): //; s/\\\\/\//g; s/\\\//\//g') || true
[ -n "$paths" ] || exit 0

switch_file="$HOME/.silverback/guard"
if grep -qxF "files=off" "$switch_file" 2>/dev/null; then exit 0; fi

# Instruction files every agent reads, agent settings and hooks, the git and
# CI gates, and the agents' memory stores.
protected='(^|/)(AGENTS(\.override)?\.md|CLAUDE(\.local)?\.md|GEMINI\.md|QWEN\.md|MEMORY\.md|\.gitignore|\.pre-commit-config\.ya?ml|lefthook\.ya?ml|copilot-instructions\.md)$|(^|/)\.(claude|codex|gemini|qwen|cursor|kimi-code|devin|windsurf)/(settings[^/]*\.json|config\.toml|hooks[^/]*|rules/|agents/|policies/)|(^|/)\.(husky|githooks)/|(^|/)\.github/(workflows|hooks)/|(^|/)\.claude/projects/[^/]+/memory/|(^|/)\.(codex|qwen)/(memories|projects/[^/]+/memory)/'

hit=$(printf '%s\n' "$paths" | grep -Ei -m 1 -- "$protected") || exit 0
hit=${hit//\"/}
message="silverback: this edits $hit, a file that steers or gates the agent (instructions, agent settings, hooks, CI, .gitignore) or holds its memory. Approve only if you asked for this edit."
decision=ask
if printf '%s' "$payload" | grep -q '"client_type"[[:space:]]*:[[:space:]]*"kimi'; then
  # Kimi Code documents deny and no ask.
  decision=deny
  message="$message Kimi Code cannot ask for approval, so the edit is blocked: the user makes it."
elif [ "$codex" = 1 ]; then
  decision=deny
  message="$message Codex cannot ask for approval, so the edit is blocked: the user makes it, or turns this check off with /silverback:guard files off."
fi
# Copilot CLI (its hooks file sets SILVERBACK_AGENT) reads top-level fields.
if [ "${SILVERBACK_AGENT:-}" = copilot ]; then
  printf '{"permissionDecision":"%s","permissionDecisionReason":"%s"}\n' "$decision" "$message"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
  "$decision" "$message"
exit 0
