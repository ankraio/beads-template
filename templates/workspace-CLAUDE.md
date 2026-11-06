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


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
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

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

**Where it lives:** the tracker is the dedicated repo `beads/` in this workspace. The workspace-root `.beads` is a symlink into `beads/.beads`, and `BEADS_DIR` (set in `.claude/settings.json` env and `.envrc`) makes `bd` resolve from inside the sub-repos and worktrees too — plain directory walking stops at each sub-repo's git boundary. Never set `BEADS_DIR` globally: a second workspace with its own tracker would silently share this one's database. The workspace root itself is NOT a git repo — commits and `bd dolt push` happen inside `beads/` (automated by the `beads-sync.sh` session hooks).

Full install and wiring instructions: `beads/SETUP.md`.

### Progress hygiene (avoid double work)

Auto-closing a bead when its PR merges needs the link recorded in **both directions**. Miss either and the bead parks in `in_review` forever. On 2026-08-17 a sweep found **263 such beads**, some months old, and the cause was direction 1 below being skipped essentially every time.

- **1. The bead must record its PR** (this is the one that was missing). `bd-sweep-merged` harvests PR references from the bead's own description and comments; a bead with none prints `no PR references found — skipping` and can never close, no matter how correct the PR is. So after `gh pr create`, paste the PR back — **as a full URL**:
  ```bash
  bd comment <bead-id> "PR: https://github.com/<org>/<repo>/pull/<n>"
  ```
  Use the URL, not `<repo>#<n>`. The short form is only resolvable when that repo happens to be checked out as a **sibling directory of this workspace** (the sweep builds its repo vocabulary from `*/.git`), so it silently harvests nothing for any repo you have not cloned — and it makes bead closure depend on each person's local directory layout, which is exactly wrong for a shared tracker. One bead filed with `<org>/<repo>#2` reported `no PR references found` until the URL was added.
- **2. The PR must delivery-cite the bead** on a `Bead: <id>` line in the body (`Beads: <a>, <b>` when it delivers several). **Body prose does NOT count** — deliberately, because PR bodies routinely list follow-up beads they *filed*, and counting prose would close unfinished work. The **PR title** and the **branch name** count only as fallbacks, ranked below the line rather than added to it: a `Bead:`/`Beads:` line, when present, is the complete list (a title id that is a listed bead's child or epic also counts); without one, the title's ids count; with neither, only the id the branch name *starts* with (after optional `fix/`-style segments). So a title or branch that names a bead the PR is only *about* does not deliver it. This part the team already does well: a 2026-08-17 sample of merged PRs was 8/8 correctly cited.
- Then move the bead with `bd update <id> --status=in_review`. `in_progress` means someone is actively working right now.
- `beads/scripts/bd-sweep-merged` runs automatically with `--apply` from the beads-sync session hooks (actions logged to `~/.claude/logs/beads-sweep.log`); run it by hand for a dry-run report.
- The hook sweep does **not** pass `--search-citing`, because GitHub search is rate limited to ~30/min (a full pass over ~300 beads takes 10-20 minutes). That flag asks GitHub which PRs name each bead, so it is the only thing that can rescue a bead missing direction 1.
- `--search-citing` therefore runs on a schedule, not by hand: the **`nightly-review-sweep` workflow in this repo**. It is the safety net for direction 1, which makes it a single point of failure worth watching, and `scripts/bd-health` (SessionStart hook) warns when its last success is over 48h old. If that warning appears, the backlog is silently growing: check org Actions billing first, since a spending-limit block means the job never *starts* and so can emit no in-workflow alert of its own (in one tracker it was dead for eight nights and `in_review` passed 360). Draining a backlog by hand is `beads/scripts/bd-sweep-merged --search-citing`, but that is recovery, not the mechanism.

### Duplicate hygiene (avoid twin beads)

Twin beads get filed when two sessions each record the same follow-up, then get batch-launched as separate "fix <bead>" jobs and two agents race on the same change.

- **Before `bd create` for follow-up work**, search for an existing bead covering it (keyword-grep `bd list`); update the existing one instead of filing a twin.
- **After `bd update <id> --claim`**, run `bd find-duplicates`. If your bead appears paired with a twin that is `in_progress`, STOP: another session is (or was) on it — compare with `bd show <a> <b>`, and either yield (close yours as the duplicate) or take over the twin, never both in parallel. Fold true dupes with `bd duplicate <dup> --of <keeper>` or `bd close <dup> --reason "duplicate of <keeper>"`.
- `beads/scripts/bd-dup-check` runs this scan report-only once an hour from one host via `bd-hygiene` (findings in `~/.claude/logs/beads-dup-check.log`), not at session start any more: `bd find-duplicates` is quadratic in open beads and took over a minute. If a pair is reported for a bead you are about to claim, resolve it first.

### Backlog hygiene (beads that stop mattering)

Nine in ten beads that ever close do so within about a week of filing; on 2026-10-24 the open backlog was 4,347 and growing 300-700 a week, with 43% untouched for a month. A verified sample of 124 of those stale beads was about 55% still valid, 20% waiting on a decision or condition nobody recorded, and 26% already done or obsolete — most of the dead ones delivered under ANOTHER bead id by a PR that never cited them. So:

- **Before `gh pr create`, search for the other beads your diff delivers** (`bd search "<subject>"`) and list every one on the `Beads:` line. Close a bead only for scope that actually shipped.
- **A parent closes when its own scope ships**; the open children carry the rest. A parent held open by its children reads as undone work forever.
- **Checks with a window get a date**: "verify after the deploy", "watch for a recurrence", a forensic look at one burst — `bd create --defer <when>` (or `--due`), so it comes back once instead of sitting open after the moment passed. Something that waits on a decision or another bead: `bd defer <id> --until <date> --reason "<what it waits on>"`, plus `bd label add <id> needs-human` for a decision.
- **Valid but not worth doing is a verdict**: `bd label add <id> accepted-risk`, then `bd close <id> --reason "<why>"`. Not a silent maybe that stays open.

### Cross-machine claims (incident-class work)

Every check above reads the LOCAL database, and sync runs only at session start/end — another machine's bead or claim filed mid-session is invisible until that session ends, and invisible entirely while `~/.claude/logs/beads-tracker-stale-<workspace>` exists (the sync hook writes that marker while this machine cannot sync; bd-dup-check then warns that every bd-side dup check is blind both ways, and healing the partition — SETUP.md "Dolt pull conflict: operator merge" — outranks new work). For **incident-class** work — anything discovered from a shared live signal several agents see at once (red `main`, a failed nightly, a CI alert channel) — the tracker structurally cannot referee the race; GitHub is the only real-time shared store, so claim there:

1. **Before filing**: `gh pr list -R <org>/<repo> --state open --search "<failing check or surface>"` and glance at recently pushed branches — an open PR or fresh branch on the incident means join or yield, never fork.
2. **After `bd create`/`--claim` on any P0/P1** (incident or not): run the claim-sync `sh <workspace>/beads/templates/beads-sync.sh <workspace>/beads --quick`, then re-run `bd find-duplicates`.
3. **Open the draft PR citing the bead BEFORE implementing** (or at minimum push the branch) — the draft PR is the cross-machine lock.
4. **Re-run the open-PR search immediately before `gh pr create`** if you did not open early.

### Tracker health

`beads/scripts/bd-health` runs report-only from the SessionStart hook and is the ONLY thing that notices when the tracker's automation dies quietly — a nightly sweep that stopped running, bd version drift against the CI pin, a swallowed Dolt sync failure, a sync hook that has not succeeded on this machine in a week, a forked tracker (`.beads/issues.jsonl` and the local Dolt store holding different issues), an in_review backlog that is no longer draining, or an open backlog that grows faster than it drains or has gone mostly untouched. If it prints a finding at session start, act on it or file a bead; do not scroll past it. Findings also go to `~/.claude/logs/beads-health.log`.

A reported tracker fork is normally healed by the sync hook itself: it runs `beads/scripts/bd-reconcile-fork --apply` after every `bd dolt pull`, importing beads that reached this machine only as jsonl (a union merge — it never rewrites an issue the database already has). bd-health runs *before* that sync in the same session start, so it says which kind it found: a line reading **"Tracker fork, self-healing"** is the ordinary one — this session's own sync merges it, so do not act on it and do not file a bead for it. Any other fork wording means the hook is *not* clearing it — read `~/.claude/logs/beads-sync.log` and SETUP.md's "Tracker fork". Never hand-edit `.beads/issues.jsonl` — that makes a third lineage.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **PR-first (default)**: Use `bd` for task tracking. Completed code changes ship as pull requests, not as uncommitted handoffs: work in a dedicated worktree (`.worktrees/*` — never commit, branch-switch, or stash a shared checked-out tree), branch, commit, push, and open a draft PR that cites the bead id, then move the bead with `bd update <id> --status=in_review` and shepherd CI to green. Follow the per-repo PR workflow notes where they exist. Never push directly to `main`. Dolt remote sync stays hook-automated — never run `bd dolt push`/`pull` by hand; the one sanctioned extra invocation is the claim-sync (`sh <workspace>/beads/templates/beads-sync.sh <workspace>/beads --quick`) after claiming a P0/P1. A hand-run pull is unbounded and holds the embedded Dolt lock for as long as it runs, so it does not just fail — it freezes `bd` for every other session on the machine: one orphaned `bd dolt pull` held the lock 42 minutes while 13 `bd` processes from other sessions stacked up behind it, the oldest waiting 1h33m. "Pull for longer" is never the fix for a sync that is not converging.
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
   gh pr create --draft --body-file <body.md>  # a `Bead: acme-xyz` line in the body: it is the
                                               # whole list. Body prose does NOT count.
   gh pr view <n> --json title,headRefName,body \
     | BD_SWEEP_MERGED_LIB=1 bash -c '. "$0" && cites_bead "$1"' <workspace>/beads/scripts/bd-sweep-merged <bead-id> \
     | grep -qx true || echo "NOT DELIVERY-CITED — the sweep will never close this bead"
   bd update <id> --status=in_review           # then shepherd CI to green

   # Report-only opt-in (analysis tasks, or a current "do not commit" instruction):
   git status                                  # report status and proposed commands instead
   ```
5. **Hand off** - Summarize changes, validation, issue status, PR links, and any blocked push/CI step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block; a current "do not commit"/"do not push" always wins.
- Never commit or mutate a shared checked-out tree — PR work happens in dedicated worktrees. Never push directly to `main`.
- If a push, PR creation, or CI gate is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
