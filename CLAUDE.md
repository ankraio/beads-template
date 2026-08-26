# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on **this repo** — the beads tracker itself, not a codebase that uses one.

## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

Once you have adopted this template as your team's tracker, the workspace `CLAUDE.md` (maintained as `templates/workspace-CLAUDE.md`) supersedes the profile above with whatever your team decided — PR-first by default. The one exception is the sync hook's own `chore: sync issue export` commits, which land on `main` by design.

## What this repo is

This repo **is** the issue tracker, not a codebase that uses one. Start at
[README.md](README.md); the operations guide is [SETUP.md](SETUP.md).

There is nothing to build. The shipped artifacts are shell scripts, one GitHub
workflow, and docs:

```bash
bash -n scripts/bd-health scripts/bd-dup-check scripts/bd-sweep-merged \
        scripts/bd-reconcile-fork scripts/bd-setup-sync \
        scripts/bd-setup-report scripts/bd-review-gate                   # syntax
sh -n templates/beads-sync.sh
jq empty templates/workspace-settings.json                               # valid JSON
scripts/test-bd-dup-check                                                # offline tests
scripts/test-bd-sweep-merged                                             # offline tests
scripts/test-bd-sweep-merged-e2e                                         # offline tests
scripts/test-bd-health                                                   # offline tests
scripts/test-bd-setup-sync                                               # offline tests
scripts/test-bd-review-gate                                              # offline tests
scripts/bd-health                                                        # live check
scripts/bd-sweep-merged                                                  # dry run, closes nothing
scripts/bd-reconcile-fork                                                # dry run, imports nothing
scripts/bd-setup-sync <repo>                                             # check only, installs nothing
scripts/bd-setup-report <repo>                                           # report only, never writes
```

Run the report-only scripts against the live tracker before shipping a
change to them — they are safe (`bd-health`, `bd-dup-check` and
`bd-setup-report` never mutate; `bd-sweep-merged` and `bd-reconcile-fork`
without `--apply` are dry runs).

## Architecture Overview

- **`.beads/`** — the Dolt database (gitignored) plus the passive `issues.jsonl`
  export that the sync hook keeps committed. The jsonl is never the source of
  truth; it is regenerated from the database.
- **`scripts/`** — report-only health and duplicate checks, plus the two scripts
  that mutate: the merged-PR sweep (closes beads, never opens or edits) and the
  fork reconcile (imports beads the local store is missing, never rewrites one
  it has). Both are dry-run by default and need `--apply`.
- **`templates/`** — files that must live *outside* a git repo to work
  (workspace-root `CLAUDE.md`, `.claude/settings.json`, `~/.claude/hooks/`).
  They are versioned here and copied out. **Edit team rules here**, not only in
  your local copy, or teammates' agents drift apart. Their combined content is
  the SETUP VERSION (`scripts/bd-setup-sync`), so touching any of them is what
  tells every machine it has something to pick up — and adding a new
  distributed file means adding it to `setup_manifest`, or it is invisible
  again.
- **`.beads-setup/heartbeats/`** — one committed file per machine saying which
  setup version it is running and when it last checked. Written by
  `bd-setup-sync`, read by `bd-setup-report`. Never edit by hand.
- **`.github/workflows/`** — the nightly sweep. It cannot detect its own death,
  so `scripts/bd-health` watches it from the laptop session hooks instead.

## Conventions & Patterns

Every script in `scripts/` carries a long header explaining the incident that
motivated it. **Those headers are the documentation** — read the one for a
script before changing it, and update it when the behaviour changes. The
recurring design rules they encode:

- **Absence is not a negative answer.** Every verdict that can fail to be
  computed has its own value and its own exit code: `DEGRADED` is not "not
  merged", `lane-unavailable` is not "no findings", `unverifiable` is not
  "drift", `silent` is not "current". Collapsing any of these into a boolean is
  how each of the incidents in README.md became invisible.
- **A watchdog cannot live inside the thing it watches.** The nightly sweep is
  watched from laptop session hooks, not from a step inside the workflow.
- **Report-only unless the header says otherwise**, and both mutating scripts
  are dry-run by default.
- **Suppression is never silent.** The duplicate checker names and counts every
  pair it suppresses, and refuses per-family rules.
- **Distribution is the hard part.** Anything this repo ships by copying it
  outside a git repo must be added to `setup_manifest` in `bd-setup-sync`, or
  nothing will ever notice a machine running the old copy.

### Progress hygiene

- **Cite the bead id in every PR** — in the PR title, the branch name, or on
  a `Bead: <id>` line in the body. This is what lets automation close the
  bead when the PR merges — and in multi-PR features, every PR must cite it
  or the bead can close before the siblings land. A mention elsewhere in the
  body prose does NOT count as delivery: bodies routinely name beads they
  filed as follow-ups or cite parent features, and those must never close a
  bead.
- **Set `in_review` when the PR opens**: `bd update <id> --status=in_review`.
  `in_progress` means someone is actively working right now. The status lives
  in DB-backed config and syncs with the tracker; if `bd statuses` doesn't
  list it after a pull, run `bd config set status.custom "in_review:wip"` once.
- **Run the matching test suite after touching any script.** Each judgement
  function is pinned offline: source the script with `BD_SWEEP_MERGED_LIB=1`,
  `BD_HEALTH_LIB=1`, `BD_SETUP_SYNC_LIB=1` or `BD_REVIEW_GATE_LIB=1` to get its
  helpers without touching bd or GitHub. `test-bd-sweep-merged-e2e` additionally
  drives the whole close path with a fake `bd` and a fake `gh` on `PATH`, so
  **changing how `bd-sweep-merged` invokes `gh` means changing that file too** —
  it fails loudly on a call it does not model rather than inventing a verdict.
