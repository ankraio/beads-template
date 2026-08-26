# Workspace rules

<!--
  TEMPLATE — copy to the ROOT of your workspace as CLAUDE.md:
      cp templates/workspace-CLAUDE.md <workspace>/CLAUDE.md

  The workspace root is not a git repo, so this file cannot live there under
  version control. It is maintained HERE and copied out, which is the only
  way every teammate's agents get the same rules. If you change the rules,
  change them in this template and tell the team to re-copy — or better, let
  `scripts/bd-setup-sync` tell them.

  EDIT ME: the list of repos below, and add whatever machine-wide rules your
  team needs (build/lint concurrency, sandbox paths, house style). Everything
  under "Beads Issue Tracker" is the part that makes bd work the same way for
  everyone, and is meant to be kept close to as-is.
-->

These rules apply to every repo and worktree under this workspace (`api`, `web`, `worker`, `infra`, `.worktrees/*`, …).

## Beads Issue Tracker

This workspace uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

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

**Where it lives:** the tracker is the dedicated repo `beads/` in this workspace. The workspace-root `.beads` is a symlink into `beads/.beads`, and `BEADS_DIR` (set in `.claude/settings.json` env and `.envrc`) makes `bd` resolve from inside the sub-repos and worktrees too — plain directory walking stops at each sub-repo's git boundary. Never set `BEADS_DIR` globally: a second workspace with its own tracker would silently share this one's database. The workspace root itself is NOT a git repo — commits and `bd dolt push` happen inside `beads/` (automated by the `beads-sync.sh` session hooks).

Full install and wiring instructions: `beads/SETUP.md`.

### Progress hygiene (avoid double work)

- When you open a PR for a bead: put the bead id (e.g. `acme-4f2k`) in the **PR title, the branch name, or a `Bead: <id>` line in the body**. A mention buried in body prose does NOT count — that is how a parent PR's "follow-up beads" list once closed work that had not shipped. Then move the bead with `bd update <id> --status=in_review`. `in_progress` means someone is actively working right now.
- `beads/scripts/bd-sweep-merged` closes beads whose citing PRs have all merged. It runs automatically with `--apply` from the beads-sync session hooks (actions logged to `~/.claude/logs/beads-sweep.log`); run it by hand for a dry-run report. It only trusts PRs that cite the bead id back — PRs mentioned as context/prior art never close a bead, and a bead none of whose PRs cite it is reported for manual check instead of closed. A citing PR that merged before the bead's work started is discounted too (a PR title naming a second bead whose lane it only touched is context, not delivery), so cite the bead in the PR that actually delivers it.

### Duplicate hygiene (avoid twin beads)

Twin beads get filed when two sessions each record the same follow-up, then get batch-launched as separate "fix <bead>" jobs and two agents race on the same change.

- **Before `bd create` for follow-up work**, search for an existing bead covering it (keyword-grep `bd list`); update the existing one instead of filing a twin.
- **After `bd update <id> --claim`**, run `bd find-duplicates`. If your bead appears paired with a twin that is `in_progress`, STOP: another session is (or was) on it — compare with `bd show <a> <b>`, and either yield (close yours as the duplicate) or take over the twin, never both in parallel. Fold true dupes with `bd duplicate <dup> --of <keeper>` or `bd close <dup> --reason "duplicate of <keeper>"`.
- `beads/scripts/bd-dup-check` runs this scan report-only from the SessionStart hook (silent when clean, findings also in `~/.claude/logs/beads-dup-check.log`). If it reports a pair at session start, resolve it before claiming or batch-launching fixes for either bead.

### Cross-machine claims (incident-class work)

Every check above reads the LOCAL database, and sync runs only at session start/end — another machine's bead or claim filed mid-session is invisible until that session ends, and invisible entirely while `~/.claude/logs/beads-tracker-stale-<workspace>` exists (the sync hook writes that marker while this machine cannot sync; bd-dup-check then warns that every bd-side dup check is blind both ways, and healing the partition — SETUP.md "Dolt pull conflict: operator merge" — outranks new work). For **incident-class** work — anything discovered from a shared live signal several agents see at once (red `main`, a failed nightly, a CI alert channel) — the tracker structurally cannot referee the race; GitHub is the only real-time shared store, so claim there:

1. **Before filing**: `gh pr list -R <org>/<repo> --state open --search "<failing check or surface>"` and glance at recently pushed branches — an open PR or fresh branch on the incident means join or yield, never fork.
2. **After `bd create`/`--claim` on any P0/P1** (incident or not): run the claim-sync `~/.claude/hooks/beads-sync.sh <workspace>/beads --quick`, then re-run `bd find-duplicates`.
3. **Open the draft PR citing the bead BEFORE implementing** (or at minimum push the branch) — the draft PR is the cross-machine lock.
4. **Re-run the open-PR search immediately before `gh pr create`** if you did not open early.

### Tracker health

`beads/scripts/bd-health` runs report-only from the SessionStart hook and is the ONLY thing that notices when the tracker's automation dies quietly — a nightly sweep that stopped running, bd version drift against the CI pin, a swallowed Dolt sync failure, a sync hook that has not succeeded on this machine in a week, a forked tracker (`.beads/issues.jsonl` and the local Dolt store holding different issues), or an in_review backlog that is no longer draining. If it prints a finding at session start, act on it or file a bead; do not scroll past it. Findings also go to `~/.claude/logs/beads-health.log`.

A reported tracker fork is normally healed by the sync hook itself: it runs `beads/scripts/bd-reconcile-fork --apply` after every `bd dolt pull`, importing beads that reached this machine only as jsonl (a union merge — it never rewrites an issue the database already has). bd-health runs *before* that sync in the same session start, so it says which kind it found: a line reading **"Tracker fork, self-healing"** is the ordinary one — this session's own sync merges it, so do not act on it and do not file a bead for it. Any other fork wording means the hook is *not* clearing it — read `~/.claude/logs/beads-sync.log` and SETUP.md's "Tracker fork". Never hand-edit `.beads/issues.jsonl` — that makes a third lineage.

## Agent Context Profiles

The Beads block above is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **PR-first (default)**: Use `bd` for task tracking. Completed code changes ship as pull requests, not as uncommitted handoffs: work in a dedicated worktree (`.worktrees/*` — never commit, branch-switch, or stash a shared checked-out tree), branch, commit, push, and open a draft PR that cites the bead id, then move the bead with `bd update <id> --status=in_review` and shepherd CI to green. Follow the per-repo PR workflow notes where they exist. Never push directly to `main`. Dolt remote sync stays hook-automated — never run `bd dolt push`/`pull` by hand; the one sanctioned extra invocation is the claim-sync (`~/.claude/hooks/beads-sync.sh <workspace>/beads --quick`) after claiming a P0/P1.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same PR-first git policy unless active instructions say otherwise.
- **Report-only (opt-in)**: When the task is analysis/review with no code change, or the user says not to commit, report changed files, validation, and suggested next commands instead of opening a PR. A current "do not commit" or "do not push" instruction always wins over the default.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Ship by active profile**:
   ```bash
   # PR-first (default): from the task's dedicated worktree, never the shared tree —
   git status                                  # confirm only this task's files changed
   git push -u origin <branch>
   gh pr create --draft --body-file <body.md>  # cite the bead id in the TITLE, branch, or a
                                               # `Bead: <id>` line. Body prose does NOT count.
   bd update <id> --status=in_review           # then shepherd CI to green

   # Report-only opt-in (analysis tasks, or a current "do not commit" instruction):
   git status                                  # report status and proposed commands instead
   ```
5. **Hand off** - Summarize changes, validation, issue status, PR links, and any blocked push/CI step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block; a current "do not commit"/"do not push" always wins.
- Never commit or mutate a shared checked-out tree — PR work happens in dedicated worktrees. Never push directly to `main`.
- If a push, PR creation, or CI gate is blocked, stop and report the exact command and error.
