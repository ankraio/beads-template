# Beads: the tracker rules that survive compaction

Work items live in the shared Dolt tracker; `bd` is the only interface. Ids look like `acme-8u72`. The full rules are in the workspace `CLAUDE.md`; this is the short form.

## Every task
- Find and claim: `bd ready` → `bd show <id>` → `bd update <id> --claim`, then `bd find-duplicates` once. An `in_progress` twin means yield or take over, never race.
- Work in a worktree under `.worktrees/`, never in a shared checked-out tree.
- Ship as a PR that cites the bead id on a `Bead: <id>` line in the body (`Beads: <a>, <b>` for several). The title and branch name count only when there is no such line; body prose never does. Then record the PR on the bead and park it:
  `bd comment <id> "PR: https://github.com/<org>/<repo>/pull/<n>"` and `bd update <id> --status=in_review`. Automation closes it when the PR merges.
- File follow-ups only after searching (`bd list`, `bd search`): `bd create --title=... --description=... --type=task|bug|feature --priority=2` (priority is numeric, 0 critical to 4 backlog; `--parent=<id>` for children).
- Before opening a PR, `bd search` for other open beads the diff also delivers and put them on the `Beads:` line too: work shipped under another bead id is the biggest source of dead beads. A parent closes when its own scope ships.
- Checks with a window ("verify after deploy", a forensic look at one burst) are filed with `--defer <when>` or `--due`. Waiting on a decision or another bead: `bd defer <id> --until <date> --reason ...` (+ `needs-human` for a decision). Valid but not worth doing: label `accepted-risk` and close with the reason.
- Incident-class work (red main, failed nightly, an alert everyone sees): search open PRs on GitHub first, and open the draft PR before implementing. The PR is the cross-machine lock.

## Never
- `bd dolt push` / `bd dolt pull` by hand. The session hooks own sync. The one exception is the claim-sync after claiming a P0/P1: `sh <workspace>/beads/templates/beads-sync.sh <workspace>/beads --quick`.
- `bd edit` (opens `$EDITOR` and hangs). Use `bd update <id> --title=... --description=... --notes=...`.
- `bd init --force` (destructive). Repair is `bd bootstrap`.
- TodoWrite, TaskCreate, or markdown TODO lists for task tracking.
- Hand-editing `.beads/issues.jsonl` (it is an export, not the truth).

## Session close
1. `bd close <id...>` for finished work; leave `in_review` for anything with an open PR.
2. Quality gates if code changed. 3. `git status`. 4. PR-first: push the branch and open the PR. Never push to `main`.

## Knowledge
Stored notes are not injected here. Before touching sync, Dolt, the sweep, or a past incident: `bd memories <keyword>`. Add one with `bd remember "..."`. Tracker health: `scripts/bd-health`. Setup and runbooks: `beads/SETUP.md`.
