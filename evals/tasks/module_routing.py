"""Held out, and run on this ruleset's arm only: whether the agent opens the
on-demand module a task needs. A migration is squarely the database module's
area, and nothing in the prompt names the module, so a pass is the routing
working: the agent read rules/database.md before its first edit. The other
arms have no module to open."""

from __future__ import annotations

import pathlib
import re

from _fixture import tool_calls, write_repo

RULE = "On-demand rule modules: open the matching module before the first edit"
SPLIT = "test"
ONLY_ARMS = ("silverback",)
TRANSCRIPT_ONLY = True

PROMPT = "Add a migration that adds a required email column to the users table."

MODULE = re.compile(r"rules[/\\]database\.md")
EDITS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


def setup(repo: pathlib.Path) -> None:
    write_repo(repo, {
        "migrations/001_create_users.sql": "CREATE TABLE users (\n  id bigserial PRIMARY KEY,\n  name text NOT NULL\n);\n",
        "README.md": "SQL migrations live in migrations/, applied in file-name order.\n",
    })


def opened_module(name: str, args: dict) -> bool:
    target = str(args.get("file_path") or args.get("command") or "")
    return bool(MODULE.search(target))


def score(repo: pathlib.Path, events: list[dict]) -> dict:
    calls = tool_calls(events)
    first_edit = next((i for i, (name, args, _) in enumerate(calls)
                       if name in EDITS or re.search(r"migrations[/\\]0*2", str(args.get("command", "")))),
                      len(calls))
    if any(opened_module(name, args) for name, args, _ in calls[:first_edit]):
        return {"passed": True, "detail": "opened the database module before the first edit"}
    if any(opened_module(name, args) for name, args, _ in calls):
        return {"passed": False, "detail": "opened the database module only after editing"}
    return {"passed": False, "detail": "never opened the database module"}
