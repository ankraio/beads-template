# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [SYNC_CONCEPTS.md](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)
> for the one-screen overview and anti-patterns (don't treat JSONL as the
> source of truth; don't `bd import` during normal operation; don't
> reach for third-party Dolt hosting before trying the default).

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Agent Context Profiles

The Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - the offline test suites below
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile** - conservative reports proposed commands and waits
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.

## What this repo is

This repo **is** the issue tracker, not a codebase that uses one. Start at
[README.md](README.md); the operations guide is [SETUP.md](SETUP.md).

Nothing to build. Validate changes with:

```bash
bash -n scripts/bd-health scripts/bd-dup-check scripts/bd-sweep-merged \
        scripts/bd-reconcile-fork scripts/bd-setup-sync \
        scripts/bd-setup-report
sh -n templates/beads-sync.sh
jq empty templates/workspace-settings.json
scripts/test-bd-dup-check          # offline
scripts/test-bd-health             # offline
scripts/test-bd-sweep-merged       # offline
scripts/test-bd-sweep-merged-e2e   # offline (fake bd + fake gh)
scripts/test-bd-setup-sync         # offline
scripts/bd-health                  # live check, report-only
scripts/bd-sweep-merged            # dry run, closes nothing without --apply
```

`templates/` holds files that must live *outside* a git repo to work (the
workspace-root `CLAUDE.md`, `.claude/settings.json`, `.beads/PRIME.md`). They
are versioned here and copied out — **edit team rules here**, not only in your
local copy, or teammates' agents drift apart.

## Tracker health

**`scripts/bd-health`** reports automation that has died quietly: a nightly
sweep that stopped succeeding, bd version drift against the CI pin, an unpinned
Homebrew formula, recent Dolt sync failures, a sync hook that has not succeeded
on this machine in a week, an installed hook that is not the copy `templates/`
ships, an export fork, a stalled `in_review` backlog, and a machine running an
out-of-date setup. Report-only, always exits 0, wired into SessionStart with
`--quiet`; `--json` for machine use.

It exists because everything else here is fail-soft, so a broken tracker looks
exactly like a healthy one — and it runs **outside** GitHub Actions on purpose:
the nightly sweep once stopped running on an Actions billing failure, and
because the job never STARTED, no in-workflow notification could fire. Eight
nights failed unnoticed. A watchdog for a scheduled job cannot live inside that
job.

**`scripts/bd-setup-sync` / `scripts/bd-setup-report`** answer whether this
machine is running the current setup, and which machines are not. The setup is
everything in `templates/`, all of which only works once copied OUTSIDE every
git repo — which is exactly why nothing versions the installed copies, and why
a machine running last month's agent rules used to be invisible. The setup
version is derived from template content, so it cannot be forgotten on a bump.

`--apply` is not a force: it installs `missing` and `stale` artifacts and
refuses `local-edits` and `differs`, because the installed copy is sometimes
the NEWER one. If your copy is the improvement, commit it to `templates/`
instead of overwriting it.

## Progress Hygiene (avoid double work)

The bead lifecycle usually ends at "PR opened", but the PR merges after the
session is gone — without the rules below, done work parks in `in_progress`
forever and gets re-triaged.

- **Cite the bead id in every PR**, on a `Bead: <id>` line in the body
  (`Beads: <a>, <b>` for several). This is what lets automation close the
  bead when the PR merges — and in multi-PR features, every PR must cite it
  or the bead can close before the siblings land. The title and the branch
  name are fallbacks, not additions: when a `Bead:` line is present it is the
  whole list, and the branch counts only when nothing else names a bead, and
  then only the id it starts with (CLAUDE.md has the rule).
- **Set `in_review` when the PR opens**: `bd update <id> --status=in_review`.
- **`scripts/bd-sweep-merged`** closes `in_progress`/`in_review` beads whose
  delivering PRs have all merged. Dry-run by default; `--apply` to close,
  `--quiet` for hooks. A PR state GitHub will not answer is reported as
  `DEGRADED`, not as "not merged". Requires `gh` and `jq`.
- **`BEADS_DIR`**: bd's workspace resolution stops at each sub-repo's git
  boundary, so from inside a code repo `bd` reports "no beads database found".
  Export `BEADS_DIR=<workspace>/beads/.beads` per workspace (direnv `.envrc`
  at the workspace root, or your agent settings env). Never set it globally
  if you work with more than one tracker.
