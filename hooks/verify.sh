#!/usr/bin/env bash
# The verification check at the end of a turn. One script on four events,
# named by its argument:
#   edit    PostToolUse on a file edit: marks the session as edited.
#   ran     PostToolUse on a shell command: clears the mark.
#   prompt  UserPromptSubmit: clears the mark, so a new request starts clean.
#   stop    Stop: a turn that edited files and ran no command after the last
#           edit is sent back once, to run the check that exercises the change
#           or to say which check did not run.
# /silverback:guard verify on|observe|off sets the mode: observe logs the turn
# to ~/.silverback/verify.log instead of sending it back. The mark lives under
# ~/.silverback, which the shell guard keeps the agent out of.
# Known ceiling: any command clears the mark, a read-only one included.
set -euo pipefail

event=${1:?usage: verify.sh edit|ran|prompt|stop}
payload=$(cat)
session=$(printf '%s' "$payload" |
  grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]+"' | head -n 1 |
  sed -E 's/.*"([A-Za-z0-9_-]+)"$/\1/') || true
[ -n "$session" ] || exit 0
dir="$HOME/.silverback/state"
mark="$dir/$session.edited"

case $event in
  edit)
    mkdir -p "$dir"
    : > "$mark"
    ;;
  ran | prompt)
    rm -f "$mark"
    ;;
  stop)
    [ -f "$mark" ] || exit 0
    # A turn the check already sent back ends the second time.
    if printf '%s' "$payload" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then exit 0; fi
    rm -f "$mark"
    mode=$(grep -E '^verify=' "$HOME/.silverback/guard" 2>/dev/null | tail -n 1 | cut -d= -f2) || true
    case ${mode:-on} in
      off) ;;
      observe)
        printf '%s %s files edited after the last command\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session" \
          >> "$HOME/.silverback/verify.log"
        ;;
      *)
        # Kimi Code documents a Stop block as exit 2 with the reason on stderr.
        if printf '%s' "$payload" | grep -q '"client_type"[[:space:]]*:[[:space:]]*"kimi'; then
          printf '%s\n' 'silverback: files were edited after the last command ran. Run the check that exercises the change and cite its result, or say in the reply which check did not run and why. A change with nothing to run (prose, a comment) says so in one line.' >&2
          exit 2
        fi
        printf '%s\n' '{"decision":"block","reason":"silverback: files were edited after the last command ran. Run the check that exercises the change and cite its result, or say in the reply which check did not run and why. A change with nothing to run (prose, a comment) says so in one line."}'
        ;;
    esac
    ;;
esac
exit 0
