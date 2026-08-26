# Beads setup

How to get a shared team issue tracker running on your machine, from zero to `bd ready` — and how to wire your agents so they work the same way everyone else's do.

Beads (`bd`) is the issue tracker. Issues live in a local Dolt database, not a web UI. The database syncs to `refs/dolt/data` on a GitHub repo, so everyone works against the same set of issues. `.beads/issues.jsonl` in that repo is a passive export for reading on GitHub, it is not the source of truth.

Issue ids look like `acme-4f2k`, where the prefix is whatever you name your tracker. `bd status` prints the current counts.

Upstream project: https://github.com/gastownhall/beads

**Read this end to end before starting.** Steps 7 and 8 are what make your agents behave like everyone else's; a setup that stops at step 6 gives you a working CLI and an agent that knows nothing about the tracker.

> Everywhere below, `<your-org>` is your GitHub org and `$WS` is your workspace root — the directory that holds your code repos side by side. Substitute your own.

---

## Before you start

You need:

- **A GitHub org you can create a repo in**, and SSH access to it. Sync uses `git+ssh://git@github.com/<your-org>/beads.git`. Check with `ssh -T git@github.com`.
- **`gh` and `jq`**, used by the sweep and health scripts. `brew install gh jq` then `gh auth login`.
- **`direnv`** (optional but recommended, see step 4). `brew install direnv` plus the shell hook in your `.zshrc`.

`dolt` is installed automatically as a dependency of the `beads` Homebrew formula; install it directly if you install `bd` from a release tarball.

---

## 0. What this repo is, and how you adopt it

This is a **template**, not a running tracker. It ships the parts that took the longest to get right:

- three report-only checks that catch the ways a beads tracker dies silently,
- a sweep that closes beads when their PRs merge,
- a reconciler that heals the export fork this design produces,
- a distribution checker for the files that must live outside every git repo,
- offline test suites for all of the judgement calls above.

Adopt it by creating your own tracker repo from it:

```sh
gh repo create <your-org>/beads --private --template <this-repo> --clone
```

or click **Use this template** on GitHub. Then work through the steps below. Your tracker repo becomes the place your team's beads live and the place these scripts are maintained.

**Everything marked `EDIT ME` in the files is meant to be changed.** The rest is meant to be kept.

---

## 1. Install `bd`, pinned to one team version

**Pin a version. Do not let laptops float.** All laptops and the nightly CI job share one Dolt database, and the database schema is tied to the `bd` version. Mixed versions risk schema drift in shared data.

Preferred, matching exactly what CI installs, with the binary verified against the checksum published for that release:

```sh
BD_VERSION=1.1.0          # whatever version your team agrees on
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -fsSL -o /tmp/bd.tar.gz \
  "https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}/beads_${BD_VERSION}_darwin_${ARCH}.tar.gz"

# sha256 from that release's checksums.txt. A release asset can be re-uploaded,
# so verify rather than trust the URL:
#   curl -fsSL https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}/checksums.txt
case "$ARCH" in
  arm64) BD_SHA=c42e24d83b258f7ba9f52a6d2d5f6b055869dfe7807165055988b12e7ea8c564 ;;  # v1.1.0 darwin
  amd64) BD_SHA=5d7d30fdadcf012b7e0c1933a62cdfaef106e2561509b904e50a6733621cf8da ;;  # v1.1.0 darwin
esac
echo "${BD_SHA}  /tmp/bd.tar.gz" | shasum -a 256 -c -   # must print "OK"

tar -xzf /tmp/bd.tar.gz -C /tmp bd
sudo install -m 0755 /tmp/bd /usr/local/bin/bd
brew install dolt      # bd needs the dolt binary on PATH
bd version
```

If you install through Homebrew instead (`brew install beads`), **pin it immediately** so a routine upgrade cannot move you off the team version:

```sh
brew pin beads
```

An unpinned Homebrew install is one `brew upgrade` away from schema drift in shared data. `scripts/bd-health` warns when it finds `beads` installed and unpinned.

Bumping the version is a team-wide operation: every laptop plus `BD_VERSION` **and** `BD_SHA256` in `.github/workflows/nightly-review-sweep.yml` move together. Announce it first.

---

## 2. Clone the tracker into your workspace

The tracker is its own repo that sits alongside the code repos in the workspace.

```sh
WS="$HOME/work/myworkspace"     # your workspace root
cd "$WS"
git clone git@github.com:<your-org>/beads.git
```

Optional, matches the reference setup: symlink the tracker to the workspace root so tools that walk directories find it.

```sh
ln -s beads/.beads "$WS/.beads"
```

Note the workspace root itself is not a git repo. All tracker commits and pushes happen inside `beads/`.

---

## 3. Initialize the database (first person only)

The very first person to set this up creates the database and pushes it:

```sh
cd "$WS/beads"
bd init --prefix acme          # your tracker's id prefix
bd config set status.custom "in_review:wip"
bd dolt push
```

`in_review` is DB-backed config that everyone else inherits with their bootstrap. This setup relies on it heavily — it is the status a bead sits in between "PR opened" and "PR merged". Everyone else skips this step and goes to step 5.

---

## 4. Point `BEADS_DIR` at the tracker

This is the step people miss. `bd` resolves its workspace by walking up directories, and that walk **stops at each sub-repo's git boundary**. So from inside `api/` or `web/` or a worktree, `bd` reports "no beads database found" unless you tell it where to look.

Add to `$WS/.envrc` (then run `direnv allow`):

```sh
export BEADS_DIR=$HOME/work/myworkspace/beads/.beads
```

Agents get it from the workspace settings file you install in step 8.

> **Never export `BEADS_DIR` globally** in `.zshrc`. If you also work in another workspace with its own tracker, a global value silently points every command at the wrong database. Keep it per workspace.

---

## 5. Bootstrap the database

```sh
cd "$WS/beads"
bd bootstrap --yes
```

`bd bootstrap` reads `sync.remote` from `.beads/config.yaml` and clones the Dolt database from the remote. It never deletes existing issues, so it is also the right command for recovering on a new machine or repairing a broken local database. Use `bd bootstrap --dry-run` first if you want to see the plan.

Do **not** use `bd init --force`, which is destructive. (Some `bd` help output suggests it as a repair step — ignore that advice here; `bd bootstrap` is the repair path.)

---

## 6. Verify

```sh
bd status     # issue counts (bd stats is an alias)
bd ready      # available work
bd statuses   # must list a custom status: in_review
```

If `bd status` shows an empty database on a tracker that is not new, the bootstrap did not reach the remote. Check `ssh -T git@github.com` and that `git ls-remote origin | grep dolt` on the beads repo shows `refs/dolt/data`.

If `bd statuses` does not list `in_review`, add it once:

```sh
bd config set status.custom "in_review:wip"
```

> `bd doctor` is **not supported in embedded mode**, which is the mode this setup runs. It prints a generic message that suggests the destructive `bd init --force`. Use `scripts/bd-health` (step 8) instead — it checks the things that actually break here.

---

## 7. Give your agents the same rules

Everything so far set up the CLI for *you*. This step is what makes your coding agents work the way the rest of the team's do. Skip it and your agent will not know the tracker exists, will invent its own TODO lists, and will open PRs that never close their beads.

The workspace root is not a git repo, so its `CLAUDE.md` cannot be version-controlled in place. It is maintained in this repo under `templates/` and copied out:

```sh
WS="$HOME/work/myworkspace"
cp "$WS/beads/templates/workspace-CLAUDE.md" "$WS/CLAUDE.md"
```

That file carries the rules every agent is expected to follow: bd for all task tracking, the PR-first shipping profile, work-in-a-worktree, bead-id citation in PRs, and duplicate hygiene. **Edit the repo list at the top of the template for your workspace, and add whatever machine-wide rules your team needs.**

**When the rules change, they change in `templates/workspace-CLAUDE.md` and everyone re-copies.** Editing only your local workspace copy is how two teammates' agents start behaving differently.

Codex users: this repo also ships `.codex/hooks.json` and `.codex/config.toml`, which load beads context on session start, prompt submit, and compaction.

---

## 8. Session hooks

The hooks keep the tracker synced without anyone remembering to do it, and surface problems that are otherwise invisible. Install the sync script from the repo (do not hand-copy it out of a doc — that is how the script and its documentation drifted apart):

```sh
cp "$WS/beads/templates/beads-sync.sh" ~/.claude/hooks/beads-sync.sh
chmod +x ~/.claude/hooks/beads-sync.sh
```

Then install the workspace settings, substituting your own absolute workspace path:

```sh
mkdir -p "$WS/.claude"
sed "s#/ABSOLUTE/PATH/TO/WORKSPACE#$WS#g" \
    "$WS/beads/templates/workspace-settings.json" > "$WS/.claude/settings.json"
```

If you already have a `$WS/.claude/settings.json`, merge the `env` and `hooks` blocks into it by hand rather than overwriting.

Use absolute paths in that file: hook commands are not shell-expanded, so `~` and `$WS` will not resolve. (`"$HOME"` inside the quoted command string does work, which is why the sync hook uses it.)

What each hook does:

- `bd prime --hook-json` loads tracker workflow context and stored memories into the session.
- `bd-health --quiet` reports tracker automation that has quietly died. Silent when clean, findings also in `~/.claude/logs/beads-health.log`.
- `bd-dup-check --quiet` reports likely duplicate beads, report only. Silent when clean, findings also in `~/.claude/logs/beads-dup-check.log`.
- `beads-sync.sh` does `bd dolt commit`, `bd dolt pull`, the fork reconcile, the merged-PR sweep, `bd dolt push`, and commits the jsonl export. A clean run appends a `sync OK` heartbeat line to `~/.claude/logs/beads-sync.log`; that is what lets `bd-health` tell "the hook has nothing to complain about" apart from "the hook has not run here in a week".

**Re-copy the hook whenever this repo's template changes.** The installed file lives outside every git repo — that is the only way hooks work — so nothing versions it: no diff, no `git status`, no CI will ever tell you your copy is old, while the machine keeps syncing and every other check stays green. That is not theoretical. In the tracker this setup grew in, the automatic fork repair shipped in the template on one day, and a laptop still running its two-day-old copy re-forked the tracker on every sync for three days while three people healed it by hand. `bd-health` now compares the installed hook against `templates/beads-sync.sh` on every session start and says so when they differ, so this is caught rather than deduced — but the fix is still yours to run, and run it when no sync is in flight: `sh` reads a running script by byte offset, so overwriting it mid-run executes a mixture of the old and new file.

**Pass your workspace path as the argument** to `beads-sync.sh`, as the template does. There is deliberately no default: on a machine running two trackers, a hardcoded fallback silently syncs the wrong one.

If you run the hooks, **do not run `bd dolt push` / `bd dolt pull` by hand.** Let the hooks own remote sync. Concurrent manual syncs are how this tracker once forked into two divergent lineages for five days. The one sanctioned extra invocation is the **claim-sync**: right after `bd create` or `bd update --claim` on a P0/P1, run

```sh
~/.claude/hooks/beads-sync.sh "$WS/beads" --quick
```

then re-run `bd find-duplicates`. It is the same script under the same lock (so it cannot race a session hook), doing commit + pull + reconcile + push while skipping the merged-PR sweep and the jsonl export. It exists because plain hook cadence syncs claims only at session boundaries, which is how two machines once fixed the same incident on the same afternoon without ever seeing each other's bead.

**The stale-tracker marker.** When a sync fails, the hook writes `~/.claude/logs/beads-tracker-stale-<workspace>` and removes it on the first clean sync; the file keeps its first-failure timestamp so its age measures the partition. While it exists, this machine can neither see other machines' beads nor publish its own — every local duplicate check is blind in both directions. `bd-dup-check` warns loudly while the marker is present, a GitHub open-PR search becomes the only duplicate check that means anything, and a partition older than six hours auto-files a machine-scoped P1 bead so it becomes work instead of a log line. Heal it with the operator merge under Troubleshooting ("Dolt pull conflict: operator merge").

Verify the wiring by starting a fresh session, or directly:

```sh
cd "$WS/beads" && scripts/bd-health
```

---

## 9. Keep the setup up to date, and say so

Steps 7 and 8 copied three files out of this repo: the agent rules, the sync hook, and the settings. That copy is a point-in-time snapshot. When you improve how you work with beads, your machine keeps running the old snapshot until someone remembers to re-copy — and **nothing anywhere can tell that it is happening**, on your machine or on anyone else's.

Install the checker, which also registers a periodic run:

```sh
"$WS/beads/scripts/bd-setup-sync" "$WS/beads" --install-cron
```

That schedules it every 12 hours (`--cron-hours N`, max 24) via launchd on macOS or crontab elsewhere, logging to `~/.claude/logs/beads-setup-sync.log`. The session hook runs the same check, but a session-start check cannot see the machine that has not started a session — which is precisely the machine most likely to be behind.

Run it by hand any time to see where you stand:

```sh
"$WS/beads/scripts/bd-setup-sync" "$WS/beads"           # check only
"$WS/beads/scripts/bd-setup-sync" "$WS/beads" --apply   # install what is stale
```

It reports one of these per artifact, and the distinction matters:

| verdict | meaning | what to do |
| --- | --- | --- |
| `current` | matches the template | nothing |
| `missing` | never installed | `--apply` |
| `stale` | the template moved after you installed | `--apply` |
| `local-edits` | **your copy is newer** — you changed it and never upstreamed it | commit the change to `templates/`, do not overwrite |
| `differs` | differs, and there is no record saying which side is newer | diff them first |
| `unverifiable` | a templated/hand-merged file (`settings.json`) that cannot be decided | re-apply the block by hand |

**`--apply` will not touch `local-edits` or `differs`.** The first live run of this checker found a workspace `CLAUDE.md` *ahead* of its template: it carried a fix to a machine-wide rule that the template still shipped broken. A tool that assumed "differs means behind" would have handed that regression to everyone. If your copy is the improvement, upstream it.

### Who else is up to date

Every run publishes a heartbeat to `.beads-setup/heartbeats/<machine>.json` in this repo — one file per machine, so machines never conflict — and it travels on the sync everyone already runs:

```sh
"$WS/beads/scripts/bd-setup-report"
```

```
MACHINE                            WORKSPACE          VERSION         AGE_H     CRON  VERDICT
laptop-a-alice                     myworkspace        56e15867e163        2     true  current
laptop-b-bob                       myworkspace        0f31c9aa71bd       11     true  behind
laptop-c-carol                     myworkspace        56e15867e163        3    false  not-applied
```

- `behind` — has not even pulled the current templates.
- `not-applied` — has them and has not installed them. A separate verdict on purpose: matching version strings prove only that the machine *read* the templates.
- `silent` — has not reported inside the window (48h by default). The weakest signal, not the strongest: its last known version may be stale too. Usually the cron is missing.

The **setup version** is derived from the content of `templates/`, not declared anywhere. Change a template and it changes; there is no field to forget in the same PR that changes the rules.

---

## Daily workflow

```sh
bd ready                      # find available work
bd show <id>                  # read the issue
bd update <id> --claim        # claim it
bd find-duplicates            # right after claiming, see below
# ... do the work in a worktree, open a PR citing the bead id ...
bd update <id> --status=in_review
```

### Cite the bead id in every PR

Put the bead id in the **PR title, the branch name, or a `Bead: <id>` line in the body**. That citation is what lets automation close the bead when the PR merges.

A mention buried in body prose does **not** count. PR bodies routinely name beads as follow-ups or cite parent features, and those must never close a bead. Only title, branch, or the `Bead:` line count as delivery. In a multi-PR feature, every delivering PR must cite the bead, or it can close before the siblings land.

A citation in a PR that merged **before the bead's work started** does not count either. A PR title often names two beads — the one it delivers and one whose lane it merely touches — and nothing in the text distinguishes them. Such a PR is reported as discounted; it neither closes the bead nor blocks a later close. (Real case: a bead was closed on a PR that had merged six days before the work began and named it in the bead's own title, while the PR that actually delivered it was still an open draft.)

Then set `in_review`. Reserve `in_progress` for "someone is actively working on this right now".

`scripts/bd-sweep-merged` closes beads once all their delivering PRs merge. It runs from the session hooks with `--apply`, and nightly in CI. Run it by hand with no flags for a dry-run report.

A PR state GitHub will not answer is reported as `DEGRADED`, never as "not merged": the lookup falls back from GraphQL to the REST API, retries once, and if it still cannot tell, the bead is left open, the run exits 3, and the nightly job fails so the night is not recorded as clean.

### Avoid twin beads

Two sessions filing the same follow-up produces two beads, then two agents race on one change. It happens.

- **Before `bd create`** for follow-up work, search first (`bd list` plus grep, or `bd search`). Update the existing bead instead of filing a twin.
- **After `bd update <id> --claim`**, run `bd find-duplicates`. If your bead is paired with an `in_progress` twin, stop. Compare with `bd show <a> <b>`, then either yield (close yours as the duplicate) or take over the twin. Never both in parallel.
- Fold true duplicates with `bd duplicate <dup> --of <keeper>`.
- If a reported pair is **not** a duplicate, record that in `scripts/dup-check-known-distinct.txt` — one line per pair, with a reason. Otherwise it is reported again at every SessionStart, and a check that is mostly noise is one people learn to scroll past.

Do not try to fix that noise with `--threshold`. The twin this check exists for scored **79%**; four sibling child beads splitting one feature across four cloud providers — four different integrations the parent required be shipped as separate PRs — scored up to **82%**. Any threshold that hides the lanes also hides the twin, which is why known-distinct pairs are named explicitly instead. Suppression is always counted and named in the report, never silent, and only ever per-pair: listing two lanes of a family does not hide a third (`scripts/test-bd-dup-check` pins that).

### Incident-class work claims on GitHub, not in the tracker

Everything above assumes the twin is visible in your local database. Across machines it usually is not: sync runs at session start and end, so a bead filed mid-session on another machine reaches you at the earliest when *that* session ends — and not at all while either machine is partitioned (see the stale-tracker marker in step 8). For **incident-class** work — anything discovered from a shared live signal every agent sees at once: a red `main`, a failed nightly, a CI alert — simultaneous starts are the norm, so the tracker structurally cannot referee the race. GitHub is the only store all machines share in real time, so the claim that counts is made there:

1. **Search open PRs before filing**: `gh pr list -R <your-org>/<repo> --state open --search "<failing check or subsystem>"`, and glance at recently pushed branches. An open PR or fresh branch already on the incident means you join or yield — never fork.
2. **File and claim the bead, then run the claim-sync** (`~/.claude/hooks/beads-sync.sh "$WS/beads" --quick`) and re-run `bd find-duplicates`: it pushes your claim out and pulls other machines' claims in, in seconds.
3. **Open the draft PR before implementing** — or at minimum push the branch — citing the bead. The draft PR is the cross-machine lock; from that moment the race is visible to everyone.
4. **Re-run the open-PR search immediately before `gh pr create`** if you did not open early.

This is verbatim the race that produced twin fixes for one incident on one afternoon: both sides ran every bd-side check this file prescribes, both came back clean, and both were blind — the tracker was partitioned, and even healthy it could not have carried a mid-session claim across in time. The open-PR search would have caught it five minutes before the second PR was opened.

---

## Keeping the tracker healthy

Every piece of automation here is deliberately fail-soft so it can never block a session. The cost of that choice is that **a broken tracker looks exactly like a healthy one**, so health has to be checked actively.

Run the check any time, or let the SessionStart hook do it:

```sh
cd "$WS/beads" && scripts/bd-health
```

It reports:

| Check | Why it matters |
|---|---|
| Nightly sweep liveness | The sweep is what closes beads whose PRs merged. If it stops, `in_review` grows without bound. |
| bd version drift | Local `bd` vs the CI-pinned `BD_VERSION`. The shared Dolt schema is tied to the version. |
| Homebrew pin | An unpinned formula is one `brew upgrade` away from that drift. |
| Dolt sync failures | Recent `FAILED` lines in the sync log — the fork-the-tracker failure mode. |
| Sync liveness | No successful sync on this machine for days. |
| Hook drift | The installed `~/.claude/hooks/beads-sync.sh` is not the copy `templates/` ships. |
| Export fork | `.beads/issues.jsonl` and the Dolt store hold different issues. |
| `in_review` backlog | Size and age. A growing backlog means merged PRs are not citing bead ids, or the sweep is dead. |
| `BEADS_DIR` wiring | Resolves to a real database. |
| Setup drift | The other files copied out of `templates/` are not current, or no periodic checker is installed. |

**Why this lives outside GitHub Actions:** the nightly sweep once stopped running because of an Actions billing failure — the job was *never started*, so no step inside the workflow could report its own death. Eight nights failed unnoticed while the `in_review` backlog grew past 360 beads. Any watchdog for a scheduled job has to run somewhere other than that job, which is why this one runs from your laptop's session hooks.

If `bd-health` reports a dead sweep, check your repo's Actions tab and fix the underlying cause; a dead sweep is a billing, permissions, or schedule problem, not something the script can repair.

---

## Command cheat sheet

**Finding work**

```sh
bd ready                      # ready to work, nothing blocking
bd list --status=open
bd list --status=in_progress
bd list --status=in_review
bd show <id>
bd search <query>
bd blocked
```

**Creating and updating**

```sh
bd create --title="Short summary" \
          --description="Why this exists and what needs doing" \
          --type=task|bug|feature --priority=2
bd create ... --parent=<id>          # child of an epic or task
bd update <id> --claim
bd update <id> --assignee=<user>
bd update <id> --status=in_review
bd close <id> --reason="explanation"
bd close <id1> <id2> <id3>           # batch close
```

Priority is **numeric**, 0 to 4 (0 = critical, 2 = medium, 4 = backlog). Not "high" / "low".

**Dependencies**

```sh
bd dep add <issue> <depends-on>
```

**Health**

```sh
bd status                       # overview and statistics
scripts/bd-health               # tracker automation health (see above)
scripts/test-bd-health          # tests for its fork verdict; run after editing either
scripts/bd-dup-check            # likely duplicate beads
scripts/test-bd-dup-check       # tests for that filtering; run after editing either
scripts/bd-sweep-merged         # dry-run: beads whose PRs have merged
scripts/test-bd-sweep-merged    # tests for its citation match
scripts/test-bd-sweep-merged-e2e  # tests for its whole close path, with fake bd + gh
scripts/bd-setup-sync           # is this machine running the current setup?
scripts/bd-setup-report         # which machines are?
scripts/bd-review-gate <pr>     # has a bot review seen this PR's current head?
bd stale
bd orphans
bd preflight                    # pre-PR checks
```

**Memory**

```sh
bd remember "insight worth keeping"
bd memories <keyword>
bd forget <key>
```

---

## Gotchas

- **`bd edit` opens `$EDITOR`.** It blocks AI agents indefinitely. Use `bd update <id> --title/--description/--notes` instead.
- **`bd doctor` does not work in embedded mode**, and its output suggests the destructive `bd init --force`. Use `scripts/bd-health`.
- **`BEADS_DIR` per workspace, never global.** See step 4.
- **Version lockstep.** Laptops and the CI `BD_VERSION`/`BD_SHA256` must match. Bump together, and `brew pin beads` so upgrades cannot drift you.
- **Don't hand-run dolt sync when hooks are enabled.** See step 8.
- **`bd init --force` is destructive.** Use `bd bootstrap`.
- **The jsonl is an export, not the truth.** Editing `.beads/issues.jsonl` by hand does nothing useful, it gets regenerated from the database.
- **Workspace rules live in `templates/workspace-CLAUDE.md`.** Edit there, not only in your local copy, or teammates' agents drift apart.
- **Nightly CI needs `BEADS_SWEEP_TOKEN`**, a fine-grained PAT for your org (all repos, Pull requests: read, Metadata: read). Without it the nightly sweep degrades to a loud no-op. This is a repo secret, nothing for you to do locally.

---

## Security notes

- **Nothing in this repo should ever hold a credential.** `.beads/config.yaml` carries an SSH remote URL and no secret. The nightly workflow rewrites that URL with the job token at runtime, `chmod 600`s the file, and restores it in an `if: always()` step so a failed run cannot leave the token on the runner; the jsonl commit adds explicit paths only, so the rewritten config can never land on `main`.
- **The workflow pins what it runs.** `actions/checkout` is pinned to a commit SHA rather than a movable tag, and the `bd` release tarball is verified against a recorded sha256 before it is installed. This job holds `contents: write` on the tracker, so both matter.
- **`BEADS_SWEEP_TOKEN` is read-only by design** — Pull requests: read, Metadata: read. It exists to *see* PRs across the org. It must never be granted write scopes; the sweep only ever writes to the beads database, using the job token.
- **Sync is SSH from laptops, https-with-job-token from CI.** Never commit a change to `sync.remote` that embeds a token.
- **The scripts are report-or-close only.** `bd-health`, `bd-dup-check` and `bd-setup-report` never mutate anything. `bd-sweep-merged` only ever closes beads, only when a merged PR delivery-cites the bead id, and it leaves the bead open whenever its GitHub check cannot run — a failed lookup is never read as "nothing is blocking". `bd-reconcile-fork` only ever imports ids the database lacks. `bd-setup-sync --apply` refuses to overwrite an installed copy that may be newer than the template.

---

## Troubleshooting

**"no beads database found"** from inside a code repo or worktree
`BEADS_DIR` is not set in that shell. `echo $BEADS_DIR`, and check `direnv allow` ran in the workspace root.

**`bd status` shows 0 issues**
Bootstrap did not reach the remote. Verify `ssh -T git@github.com`, then re-run `bd bootstrap --dry-run` in `beads/` to see what it plans to do.

**Sync warnings in your session context**
The sync script is fail-soft but not fail-silent. A `WARNING: beads ... failed` line means the tracker may not be syncing. Full output is in `~/.claude/logs/beads-sync.log`.

**"beads repo has unpushed hand-written commits and main has diverged"**
You committed something to the beads repo (a script or doc change) and `main` moved. The sync script refuses to reset over your work. Rebase and push by hand: `git -C "$WS/beads" pull --rebase origin main && git -C "$WS/beads" push origin main`.

**Bead stuck in `in_progress` or `in_review` after the PR merged**
The PR probably did not cite the bead id in the title, branch, or a `Bead:` line. Close it by hand: `bd close <id> --reason="delivered in <PR url>"`.

**`bd-health` says the nightly sweep is stale**
Open your repo's Actions tab. Most likely causes, in order: GitHub Actions billing/spend limit (the job shows as failed in ~4s with "the job was not started"), an expired `BEADS_SWEEP_TOKEN`, or GitHub having disabled the schedule after repo inactivity.

**`bd-health` says "Tracker fork"**
`.beads/issues.jsonl` and your local Dolt store hold different issues, so the tracker has split into two lineages. The database is the source of truth; the jsonl is only its export.

- *JSONL-only records*: someone else's lineage is ahead of yours. bd will not overwrite them, so it skips the auto-export entirely and prints `Warning: auto-export skipped: ... contains N JSONL-only issue record(s)` on every write — the line everyone scrolls past. Fix by pulling their lineage in: `bd dolt pull` (the sync hook does this), then let the next hook run rewrite the jsonl.
- *Dolt-only records*: your export is frozen, so the committed jsonl — and with it the GitHub issue view and anything reading it — is stale. Usually the same cause: the export is blocked by JSONL-only records, so clearing those clears this too.

A pull only fixes it when the other lineage actually pushed those issues to `refs/dolt/data`. When it did not, they exist on your machine *only* as jsonl — the git convergence at the bottom of the sync hook brought them in — and no number of pulls will find them. That is the fork that keeps coming back (healed by hand three times in three days, back within a day each time). `scripts/bd-reconcile-fork` closes that gap by importing the JSONL-only records into the local store:

```sh
scripts/bd-reconcile-fork            # dry run: how many, which ids
bd dolt pull                         # take everything the remote does have first
scripts/bd-reconcile-fork --apply    # merge in what only the jsonl carries
```

It is a union merge: it imports ids the database does not have and never rewrites one it does, so a stale export from a machine that is behind cannot roll your tracker back. The sync hook runs it with `--apply --quiet` after every `bd dolt pull`, so this is normally self-healing and you should only ever run it by hand to inspect a fork or after a hook failure. It always says what it merged, on stdout and in `~/.claude/logs/beads-sync.log`.

Because it is normally self-healing, `bd-health` says which kind of fork it found before it asks you for anything. **"Tracker fork, self-healing"** is the ordinary one — the hook merges it during this session's own sync, and there is nothing to do and nothing to file. The wording changes to a repair instruction only when the hook is *not* clearing it: the installed hook is not the copy this repo ships (so nothing reconciles), the last reconcile exited nonzero, or a reconcile completed cleanly *after* your `issues.jsonl` was last written and the two sides still disagree. Those are the ones worth a bead; the self-healing line is not, and one was filed and dispatched to an agent for a fork the hook had already merged minutes earlier.

Never hand-edit `issues.jsonl` or resolve the split by checking out an older copy of it; that creates a third lineage. If `bd dolt pull` reports a conflict, read `~/.claude/logs/beads-sync.log` and resolve it in Dolt, not in git — the full recipe is the next entry.

**Dolt pull conflict: operator merge** (`bd dolt pull` fails with "merge conflicts in issues require operator resolution")

This one never heals on its own: every later pull aborts identically, every push stays rejected non-fast-forward behind it, and the machine is partitioned from the tracker in both directions while everything else looks green. Once, this hid a twin-fix race for a whole incident. The hook cannot resolve it because row conflicts need a human-judgment merge. The recipe:

```sh
# 1. Take the sync lock so no session hook can interleave (wait for any
#    in-flight beads-sync.sh first: pgrep -f beads-sync.sh):
mkdir ~/.claude/locks/beads-sync-<workspace>.lock

# 2. The embedded Dolt repo is a normal dolt directory:
cd "$WS/beads/.beads/embeddeddolt/<db>"
dolt config --local --add user.name  "<your name>"
dolt config --local --add user.email "<your email>"

# 3. Merge and inspect - the conflicts are usually beads both sides
#    closed, differing only in timestamps:
dolt fetch origin
dolt merge origin/main
dolt sql -q "SELECT * FROM dolt_conflicts_issues" -r json   # read our_/their_ pairs

# 4. Resolve. --theirs is right when the rows are equivalent (both closed);
#    for a row where OUR side is meaningfully newer, REPLACE it back after.
#    A blanket --theirs SILENTLY REVERTS every local row the other side also
#    touched, so read the conflict rows before you resolve them.
dolt conflicts resolve --theirs issues
dolt commit -m "operator merge: join remote lineage, resolve issue conflicts"
dolt push origin main

# 5. Release the lock and let the hook converge the rest:
rmdir ~/.claude/locks/beads-sync-<workspace>.lock
~/.claude/hooks/beads-sync.sh "$WS/beads"
tail -1 ~/.claude/logs/beads-sync.log        # must say "sync OK"
```

The stale-tracker marker (step 8) is removed by that first clean run. Afterwards check whether beads that were filed on other machines during the partition duplicate local ones, and fold them.

A fork that keeps returning after this is usually a hook that is not the one this repo ships — see the next entry — either here (the reconcile never runs, so the fork the sync creates is never repaired) or on the *other* machine (it is not pushing its Dolt lineage at all). Also check that `bd dolt push` succeeds there and that `sync.remote` in its `.beads/config.yaml` points at this repo.

**`bd-health` says the installed sync hook differs from the template**
Your `~/.claude/hooks/beads-sync.sh` is not the copy in `templates/beads-sync.sh`. Because the installed file must live outside every git repo, nothing versions it, so this cannot be seen any other way — and an old hook fails silently: it keeps syncing, so nothing else looks wrong. A copy predating the fork reconcile does not run `scripts/bd-reconcile-fork`, which means it re-forks the tracker on every sync and the "Tracker fork" entry above comes back a day after each hand repair. Re-copy it:

```sh
cp "$WS/beads/templates/beads-sync.sh" ~/.claude/hooks/beads-sync.sh
chmod +x ~/.claude/hooks/beads-sync.sh
```

Do it when no sync is in flight (`pgrep -f beads-sync.sh`): `sh` reads a running script by byte offset, so overwriting it mid-run makes the rest of that run a mixture of the old and new file. If the difference is an *uncommitted local edit* to the template, commit it here instead — team rules belong in `templates/`, or everyone's agents drift apart.

**`bd-health` says the sync last succeeded N days ago, or has no successful-sync line**
The `beads-sync.sh` hook has stopped running on this machine — check the SessionStart/SessionEnd wiring in `$WS/.claude/settings.json` (step 8) and that `~/.claude/hooks/beads-sync.sh` is still executable. Your bead changes are staying local until it runs. The "no successful-sync line at all" wording means the log has never recorded a clean run, which is only reported once the installed hook is known to be current — an old hook does not write the heartbeat, so for those the silence means nothing and the check stays quiet.

**Logs to check**

```
~/.claude/logs/beads-sync.log        # remote sync
~/.claude/logs/beads-sweep.log       # merged-PR sweep actions
~/.claude/logs/beads-dup-check.log   # duplicate findings
~/.claude/logs/beads-health.log      # tracker health findings
~/.claude/logs/beads-setup-sync.log  # setup distribution checker
```
