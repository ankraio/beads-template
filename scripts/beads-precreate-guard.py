#!/usr/bin/env python3
"""PreToolUse(Bash) hook: show likely duplicates BEFORE a bead is filed.

bd's duplicate machinery all runs too late or on the wrong data. `bd
find-duplicates` scores EXISTING beads against each other, so it cannot see a
bead that does not exist yet; bd-dup-check runs it from SessionStart, before the
duplicate is born; and the workflow rule that fires it is gated behind
`bd update --claim`, which an author who files and moves on never reaches. The
one moment a duplicate is actually created had no check at all.

On 2026-08-27 that cost a duplicate of a P0 that had been in_progress and
assigned since earlier the same day, on a live incident - the exact
"two agents race on the same change" failure the beads rules exist to prevent.
The author's own `bd list` grep missed it because it searched their framing
('export', 'scope', 'owned') and the existing bead said 'overwrites' and
'ownership'.

This denies ONCE with the candidates, and always names the way through. A false
positive must cost one acknowledgement, never a blocked bead:

    BD_DUP_ACK=1 bd create "..." -d "..."

WHY THE COMMAND IS PARSED AND NOT REGEXED. The lint slot hook learned this the
hard way: matching the whole command string denied `bd comment`
calls that merely NAMED a tool inside a quoted argument. A tool named in an
argument is data; only a tool in COMMAND POSITION is an invocation. So the
command is tokenised with shlex - which collapses a quoted argument into a
single token, making `bd comment "... we should bd create ..."` structurally
unable to match - and `bd`/`create` must be adjacent at a command position.

Fails OPEN on every error. A hook that cannot parse the command, find the
checker or read the corpus must not stand between anyone and filing a bead.
"""

import json
import os
import shlex
import subprocess
import sys

ACK_VARIABLE = "BD_DUP_ACK"
SEPARATORS = {";", "&&", "||", "|", "&", "\n"}
# Commands that run another command; the real command word is further right.
WRAPPERS = {"sudo", "env", "command", "time", "nice", "nohup", "stdbuf", "exec"}


def allow():
    sys.exit(0)


def deny(reason):
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, sys.stdout)
    sys.exit(0)


def tokenize(command):
    """Shell-aware split. Quoted spans collapse to one token, which is the point."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def find_bd_create(tokens):
    """Return the token index just after `create`, or None.

    Walks command positions only: the start of the line, or the token after a
    separator, skipping env assignments and wrappers. Anything else consumes the
    rest of its segment as data.
    """
    at_command_position = True
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in SEPARATORS:
            at_command_position = True
            index += 1
            continue
        if not at_command_position:
            index += 1
            continue
        if "=" in token and not token.startswith("-") and token.split("=", 1)[0].isidentifier():
            index += 1  # environment assignment precedes the command word
            continue
        if token.startswith("-"):
            index += 1
            continue
        base = os.path.basename(token)
        if base in WRAPPERS:
            index += 1
            continue
        if base == "bd":
            # The subcommand must be the very next word for this to be a create.
            if index + 1 < len(tokens) and tokens[index + 1] == "create":
                return index + 2
            at_command_position = False
            index += 1
            continue
        at_command_position = False
        index += 1
    return None


def extract_title_and_description(tokens, start):
    """First positional after `create` is the title; -d/--description is the body."""
    title, description = None, ""
    index = start
    while index < len(tokens):
        token = tokens[index]
        if token in SEPARATORS:
            break
        if token in ("-d", "--description"):
            if index + 1 < len(tokens):
                description = tokens[index + 1]
                index += 2
                continue
        if token.startswith("--description="):
            description = token.split("=", 1)[1]
            index += 1
            continue
        if token.startswith("-"):
            # Flags that take a value; skip the value so it is not read as a title.
            if token in ("-p", "--priority", "-t", "--type", "-a", "--assignee", "--owner",
                         "--status", "--parent", "--label", "--external"):
                index += 2
                continue
            index += 1
            continue
        if title is None:
            title = token
        index += 1
    return title, description


def locate_checker():
    """Resolve the checker from BEADS_DIR only, deliberately.

    A machine can run more than one tracker: each workspace has its own, which
    is exactly why BEADS_DIR is set
    per-workspace and never globally. A hardcoded fallback to one of them would
    score a proposal against the WRONG tracker and report confident nonsense, so
    an unset or unusable BEADS_DIR means no check rather than the wrong check.
    """
    beads_directory = os.environ.get("BEADS_DIR", "")
    if not beads_directory:
        return None
    # BEADS_DIR points at <repo>/.beads; the scripts live beside it.
    path = os.path.join(os.path.dirname(beads_directory.rstrip("/")),
                        "scripts", "bd-precreate-check")
    if os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        allow()

    command = (payload.get("tool_input") or {}).get("command") or ""
    if "bd" not in command or "create" not in command:
        allow()  # cheap reject before paying for the parse

    try:
        tokens = tokenize(command)
    except ValueError:
        allow()  # unbalanced quotes: cannot tell data from code, so do not judge

    if ACK_VARIABLE in command and any(
        token.startswith(ACK_VARIABLE + "=") and not token.endswith("=0") for token in tokens
    ):
        allow()  # author has seen the candidates and decided

    start = find_bd_create(tokens)
    if start is None:
        allow()

    title, description = extract_title_and_description(tokens, start)
    if not title:
        allow()

    checker = locate_checker()
    if checker is None:
        allow()

    try:
        completed = subprocess.run(
            [checker, "--title", title, "--description", description],
            capture_output=True, text=True, timeout=25, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        allow()

    if completed.returncode != 1 or not completed.stdout.strip():
        allow()

    deny(
        "STOP - this bead may already exist.\n\n"
        + completed.stdout.rstrip()
        + "\n\nBeads filed twice get batch-launched as separate jobs and two agents "
          "race on the same change. On 2026-08-27 a duplicate of an in_progress P0 "
          "was filed during a live incident this way.\n\n"
          "If one of these covers your work, add to it instead:\n"
          "  bd comment <id> \"<what you found>\"\n\n"
          "If yours is genuinely distinct, say so and re-run the SAME command with:\n"
          "  " + ACK_VARIABLE + "=1 bd create ...\n"
          "and reference the closest id in the description so the next author sees "
          "why they are separate."
    )


if __name__ == "__main__":
    main()
