#!/usr/bin/env bash
# PreCompact hook: what the compaction summary must keep, printed as extra
# instructions for it. Codex (the payload carries a turn_id) takes no plain
# text from this event, so there it prints nothing.
set -euo pipefail
payload=$(cat)
if printf '%s' "$payload" | grep -q '"turn_id"[[:space:]]*:'; then exit 0; fi
# /silverback:rules off writes rules=off to the switch file: no ruleset then.
if grep -qx 'rules=off' "$HOME/.silverback/guard" 2>/dev/null; then exit 0; fi
printf '%s\n' 'Keep in the summary, verbatim where it is a command, path or error: the task as the user stated it and every constraint or correction they gave; the files changed; each check run with its exact command and result, and each check not run; the open items. Record a finished step as claimed, with the command that proves it, so the next context re-runs that command before repeating the claim.'
