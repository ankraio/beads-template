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
cp templates/PRIME.md .beads/PRIME.md   # the rules `bd prime` injects; edit them to fit
bd dolt push
```

Then add these two blocks to `.beads/config.yaml` and commit it along with `.beads/PRIME.md`:

```yaml
export:
    auto: false     # scripts/bd-export-jsonl writes the export once per sync instead
backup:
    enabled: false  # the Dolt remote and the jsonl are the recovery paths
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

`in_review` is DB-backed config and normally arrives with the bootstrap. We rely on it heavily — it is the status a bead sits in between "PR opened" and "PR merged".

### Dolt engine: run the sql-server, not embedded

Beads can run Dolt two ways. **Run `server`.**

Mind where the two halves of that live, because they disagree by design.
`dolt_mode` in `.beads/metadata.json` is **tracked in git** — only the database
directories are ignored — so it is a *shared declaration*, and once one machine
commits `"server"` every checkout says `"server"`. The **database directory**
(`.beads/dolt` vs `.beads/embeddeddolt`) is gitignored and is therefore the only
per-machine fact about what this laptop is actually running. So a machine can
easily declare `server` while still holding all its data in `embeddeddolt` and
having migrated nothing — at which point `bd` tries to open a `.beads/dolt` that
does not exist. `scripts/bd-health` check 9 judges by the directory for exactly
this reason, and names the mismatch when it sees one.

**Embedded is single-writer**: every `bd` invocation takes an exclusive lock on
the whole database for its lifetime. One agent session is fine; a machine
running several serialises all of them on that lock, and one wedged holder
blocks the rest. On 2026-08-30 that meant 14 `bd` processes convoying with the
oldest waiting 1h33m — and among the blocked were a `bd close` and a
`bd comment`. That is the mechanism behind "beads that are already done but
still open": the write outlives its caller's timeout, so the agent never learns
whether it landed. Embedded mode also disables
`bd sql`, and disables `bd doctor` — so the one tool that would tell you about
the problem is switched off by the problem.

Check which you are on:

```bash
bd dolt status        # "Dolt engine: embedded (in-process, no server)" = migrate
```

**Migrating is a rename, not a data migration**, because
`.beads/embeddeddolt/<db>/.dolt` is already a normal Dolt database in exactly
the layout the server expects. It needs no `bd init`, no destroy-token, and no
re-fetch from the remote:

```bash
# with no bd running (and a recent backup — bd backup status):
mv .beads/embeddeddolt .beads/dolt
# .beads/metadata.json:  "dolt_mode": "embedded"  ->  "server"
bd dolt start
```

Then verify rather than assume — issue count and status breakdown unchanged,
remote intact, and concurrency actually working:

```bash
bd sql "select count(*) from issues"
bd sql "select status, count(*) from issues group by status"
bd dolt remote list                      # origin must still be there
bd doctor                                # runs at all only in server mode
for i in $(seq 1 12); do bd list --status=open >/dev/null & done; wait   # ~1s
```

Rollback is the same rename backwards plus flipping `dolt_mode` back.

`scripts/bd-health` reports a machine still on embedded (check 9), because
nothing else can see it.

> Note this fixes the *blast radius*, not every sync fault: a `bd dolt pull`
> that wedges still wedges, but in server mode it no longer freezes every other
> session's `bd`.

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

The hooks keep the tracker synced without anyone remembering to do it, and surface problems that are otherwise invisible.

**The sync script is referenced in place, not copied.** Since 2026-09-01 the settings run `sh $WS/beads/templates/beads-sync.sh` directly; the script copies itself to a temp file at start so the git convergence at the end of a run cannot rewrite the file it is executing. There is no installed copy to drift, which retires the re-copy step, the hook-drift check, and the whole class of incident where a laptop runs an old copy. If you still have `~/.claude/hooks/beads-sync.sh` from an older setup it is inert and can be deleted.

Install the workspace settings, substituting your own absolute workspace path:

```sh
mkdir -p "$WS/.claude"
sed "s#/ABSOLUTE/PATH/TO/WORKSPACE#$WS#g" \
    "$WS/beads/templates/workspace-settings.json" > "$WS/.claude/settings.json"
```

If you already have a `$WS/.claude/settings.json`, merge the `env` and `hooks` blocks into it by hand rather than overwriting.

Use absolute paths in that file: hook commands are not shell-expanded, so `~` and `$WS` will not resolve. (`"$HOME"` inside the quoted command string does work, which is why the sync hook uses it.)

What each hook does:

- `bd prime --hook-json` loads the tracker rules into the session. The output is `.beads/PRIME.md` (about 2 KB), not bd's default; the default was 111 KB per session start, 106 KB of it stored memories, at roughly 290 session starts a day. Memories are retrieved on demand with `bd memories <keyword>`.
- `bd-health --quiet` reports tracker automation that has quietly died. Silent when clean, findings also in `~/.claude/logs/beads-health.log`.
- `checkout-staleness --quiet` names every shared checkout in the workspace that is more than 100 commits behind its origin default branch. Work happens in worktrees, so the shared trees rot in place and anything that reads them (a review, an indexer, a daemon started from the checkout) gets old code and reports it as current; on 2026-09-05 they were 44 to 719 commits behind and a cross-repo review published two claims origin had already made false. Local refs only, no network. Silent when clean; `--max N` and `CHECKOUT_STALENESS_MAX` move the threshold.
- `beads-sync.sh` (SessionStart, async) does `bd dolt commit`, `bd dolt pull`, the merged-PR sweep, `bd dolt push`, and commits the jsonl export. A clean run appends a `sync OK` line to `~/.claude/logs/beads-sync.log` and a failed run a `sync FAILED` line; `bd-health` counts the second and reads the first for "when did this last work?".
- `beads-sync.sh --quick` (SessionEnd) does commit, pull, resolve and push only. Claude Code caps SessionEnd hooks at 60 seconds no matter what `timeout` says, and a full run takes minutes, so the full run only ever completes from the async SessionStart hook.

The duplicate scan is **not** a session hook any more. `bd find-duplicates` is quadratic in open beads (66 to 72 seconds at 1,100 open beads, against a 30-second hook timeout) and ran at every session start on every machine. It now runs once an hour from one host: `scripts/bd-hygiene --install-launchd` (see "Hourly hygiene" below). Prevention at create time stays in the pre-create guard.

**Pass your workspace path as the argument** to `beads-sync.sh`, as the template does. There is deliberately no default: on a machine running two trackers, a hardcoded fallback silently syncs the wrong one.

If you run the hooks, **do not run `bd dolt push` / `bd dolt pull` by hand.** Let the hooks own remote sync. Concurrent manual syncs are how this tracker once forked into two divergent lineages for five days. The one sanctioned extra invocation is the **claim-sync**: right after `bd create` or `bd update --claim` on a P0/P1, run

```sh
sh "$WS/beads/templates/beads-sync.sh" "$WS/beads" --quick
```

then re-run `bd find-duplicates`. It is the same script under the same lock (so it cannot race a session hook), doing commit + pull + reconcile + push while skipping the merged-PR sweep and the jsonl export. It exists because plain hook cadence syncs claims only at session boundaries, which is how two machines once fixed the same incident on the same afternoon without ever seeing each other's bead.

**The stale-tracker marker.** When a sync fails, the hook writes `~/.claude/logs/beads-tracker-stale-<workspace>` and removes it on the first clean sync; the file keeps its first-failure timestamp so its age measures the partition. While it exists, this machine can neither see other machines' beads nor publish its own — every local duplicate check is blind in both directions. `bd-dup-check` warns loudly while the marker is present, a GitHub open-PR search becomes the only duplicate check that means anything, and a partition older than six hours auto-files a machine-scoped P1 bead so it becomes work instead of a log line. Heal it with the operator merge under Troubleshooting ("Dolt pull conflict: operator merge").

Verify the wiring by starting a fresh session, or directly:

```sh
cd "$WS/beads" && scripts/bd-health
```

---

## 9. Keep the setup up to date, and say so

Steps 7 and 8 copied two files out of this repo: the agent rules and the settings (the sync hook is referenced in place). That copy is a point-in-time snapshot. When you improve how you work with beads, your machine keeps running the old snapshot until someone remembers to re-copy — and **nothing anywhere can tell that it is happening**, on your machine or on anyone else's. That is not a hypothetical cost: in the tracker this setup grew in, the automatic fork repair shipped in the hook on one day, one laptop kept its two-day-old copy, and the tracker was re-forked and hand-healed for three days while every check stayed green.

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

Put the bead id on a **`Bead: <id>` line in the body** (`Beads: <a>, <b>` when the PR delivers several). That citation is what lets automation close the bead when the PR merges.

A mention buried in body prose does **not** count. PR bodies routinely name beads as follow-ups or cite parent features, and those must never close a bead. In a multi-PR feature, every delivering PR must cite the bead, or it can close before the siblings land.

The PR title and the branch name count as well, but they are ranked below the `Bead:` line, not added to it:

1. A `Bead:`/`Beads:` line, when the body has one, is the **complete list** of what the PR delivers. A title id in a listed bead's family also counts — its child (`Bead: acme-x` over a title ending `(acme-x.3)`) or its epic (a title ending `(acme-x)` over `Beads: acme-x.1, acme-x.2`, and the epic still closes only once its children have); nothing else in the title or branch does.
2. Without one, the ids in the **title** count.
3. With neither, only the id the **branch name starts with** counts (after optional `fix/`-style segments): `fix/acme-x7q2-thing` cites `acme-x7q2`, `fix/thing-acme-x7q2` and the second id of `acme-a-then-acme-b` do not.

A title or branch that names a bead the PR is only *about* therefore does not deliver it. A PR carrying `Bead: acme-ouxc` and the title "record acme-eyrq / acme-h34r as distinct" would, read as a pool, deliver h34r, which was open and being worked. Branches go stale the same way: they keep the id the work was first filed under, and a child spelled with a hyphen (`acme-0xsd-28`) reads as its parent.

A citation in a PR that merged **before the bead's work started** does not count either. A PR title often names two beads — the one it delivers and one whose lane it merely touches — and nothing in the text distinguishes them. Such a PR is reported as discounted; it neither closes the bead nor blocks a later close. (Real case: a bead was closed on a PR that had merged six days before the work began and named it in the bead's own title, while the PR that actually delivered it was still an open draft.)

Then set `in_review`. Reserve `in_progress` for "someone is actively working on this right now".

`scripts/bd-sweep-merged` closes beads once all their delivering PRs merge. It runs from the session hooks with `--apply`, and nightly in CI. Run it by hand with no flags for a dry-run report.

A PR state GitHub will not answer is reported as `DEGRADED`, never as "not merged": the lookup falls back from GraphQL to the REST API, retries once, and if it still cannot tell, the bead is left open, the run exits 3, and the nightly job fails so the night is not recorded as clean.

### Avoid twin beads

Two sessions filing the same follow-up produces two beads, then two agents race on one change. It happens.

- **Before `bd create`** for follow-up work, search first (`bd list` plus grep, or `bd search`). Update the existing bead instead of filing a twin.
- **After `bd update <id> --claim`**, run `bd find-duplicates`. If your bead is paired with an `in_progress` twin, stop. Compare with `bd show <a> <b>`, then either yield (close yours as the duplicate) or take over the twin. Never both in parallel.
- Fold true duplicates with `bd duplicate <dup> --of <keeper>`.
- If a reported pair is **not** a duplicate, record that in `scripts/dup-check-known-distinct.txt` — one line per pair, with a reason. Otherwise it is reported again at every SessionStart, and a check that is mostly noise is one people learn to scroll past. Record it **through a PR from a worktree**, like any other change here, never as a commit on the shared `beads/` checkout's `main`: three such commits on 2026-09-04 stopped that machine's checkout from converging for 25 days (see "Sync hook will not converge" under Troubleshooting).

Do not try to fix that noise with `--threshold`. The twin this check exists for scored **79%**; four sibling child beads splitting one feature across four cloud providers — four different integrations the parent required be shipped as separate PRs — scored up to **82%**. Any threshold that hides the lanes also hides the twin, which is why known-distinct pairs are named explicitly instead. Suppression is always counted and named in the report, never silent, and only ever per-pair: listing two lanes of a family does not hide a third (`scripts/test-bd-dup-check` pins that).

### Incident-class work claims on GitHub, not in the tracker

Everything above assumes the twin is visible in your local database. Across machines it usually is not: sync runs at session start and end, so a bead filed mid-session on another machine reaches you at the earliest when *that* session ends — and not at all while either machine is partitioned (see the stale-tracker marker in step 8). For **incident-class** work — anything discovered from a shared live signal every agent sees at once: a red `main`, a failed nightly, a CI alert — simultaneous starts are the norm, so the tracker structurally cannot referee the race. GitHub is the only store all machines share in real time, so the claim that counts is made there:

1. **Search open PRs before filing**: `gh pr list -R <your-org>/<repo> --state open --search "<failing check or subsystem>"`, and glance at recently pushed branches. An open PR or fresh branch already on the incident means you join or yield — never fork.
2. **File and claim the bead, then run the claim-sync** (`sh "$WS/beads/templates/beads-sync.sh" "$WS/beads" --quick`) and re-run `bd find-duplicates`: it pushes your claim out and pulls other machines' claims in, in seconds.
3. **Open the draft PR before implementing** — or at minimum push the branch — citing the bead. The draft PR is the cross-machine lock; from that moment the race is visible to everyone.
4. **Re-run the open-PR search immediately before `gh pr create`** if you did not open early.

This is verbatim the race that produced twin fixes for one incident on one afternoon: both sides ran every bd-side check this file prescribes, both came back clean, and both were blind — the tracker was partitioned, and even healthy it could not have carried a mid-session claim across in time. The open-PR search would have caught it five minutes before the second PR was opened.

---

## Hourly hygiene (one host)

Detection runs once an hour, in one place, and routes findings to someone who decides:

```sh
cd "$WS/beads" && scripts/bd-hygiene                    # run once, print the report
scripts/bd-hygiene --install-launchd                    # schedule hourly on THIS machine
```

It runs `bd-dup-check` (likely duplicates, filtered through `scripts/dup-check-known-distinct.txt`), `bd stale`, and the age of the oldest `in_progress` and `in_review` beads, logs to `~/.claude/logs/beads-hygiene.log`. Install it on one machine only: the one that is always on.

## Where this is going: one shared Dolt server

Every failure mode in the Troubleshooting section below (forks, conflicts, partitions, the stale marker, the resolver, the reconcile) exists because each laptop holds its own Dolt replica and they sync at session boundaries. bd supports pointing every client at one `dolt sql-server` instead:

```sh
bd dolt set host <tailnet-address> --update-config      # team-wide, lands in .beads/config.yaml
bd dolt set port 3307 --update-config
export BEADS_DOLT_PASSWORD=...                            # per machine, never committed
bd dolt test
```

Upstream names server mode as the topology for "multiple agents writing simultaneously" and orchestrators, which is this team. With one server there is nothing to pull or push, a claim is visible on every machine the instant it is written, CI reads the same database instead of re-cloning it nightly, and the sync hook shrinks to the jsonl export. The git remote's `refs/dolt/data` survives as a one-way backup pushed from the server host.

The kit is `scripts/bd-dolt-server`. Create a dedicated remote user on the server first (the commands are in the script's header), and keep its password out of git, for example in a mode-0600 file.

1. **Network first.** The machines need a private path to the server host. A tailnet is the simple answer. Do not bind Dolt to a public address without TLS.
2. **Supervise and bind on the server host** (an always-on machine; the kit installs a launchd agent, so macOS): `scripts/bd-dolt-server install` binds `dolt sql-server` to `0.0.0.0` on the port bd already uses **and** to a Unix socket at `.beads/dolt.sock`, then points this host's own bd at the socket (`BEADS_DOLT_SERVER_SOCKET` in `.claude/settings.local.json` and `.envrc`). The socket is what keeps the two from fighting: bd auto-starts a server whenever it believes none is running and judges that from a pid file that goes stale on every supervised restart; with a socket configured it never auto-starts. Learned live on 2026-09-01, when the first version of the kit took bd down for five minutes on one machine. bd's root user stays localhost-only; remote clients authenticate as your dedicated user. Nothing tracked in git changes. This writes `~/.claude/beads-dolt/<workspace>/server.yaml`, installs a KeepAlive launchd agent, stops bd's auto-started server and points bd at the fixed port. `scripts/bd-dolt-server status` afterwards must show exactly one `dolt sql-server` process.
3. **Spike one laptop for a day** with bd's environment variables, which touch no tracked file (`bd dolt set host/port/user` writes the tracked `.beads/metadata.json` and stalls that machine's export convergence until committed): put `BEADS_DOLT_SERVER_HOST=<addr>`, `BEADS_DOLT_SERVER_PORT=<port>`, `BEADS_DOLT_SERVER_USER=beads` and `BEADS_DOLT_PASSWORD` in that workspace's `.claude/settings.local.json` env and `.envrc`, then `bd dolt test`. Compare `bd ready`, `bd list --status=open`, `bd show`, `bd close` against the loopback baseline (about 1.3, 0.6, 0.5 seconds). bd issues many small queries, so the round trip multiplies; this is the one number that decides the cutover.
4. **Cut over**: `bd dolt set host <addr> --update-config` and `bd dolt set port 3307 --update-config` so `.beads/config.yaml` carries them for everyone (CI keeps forcing embedded on its runner until it is pointed at the server too). Then delete the Dolt half of `templates/beads-sync.sh`, `scripts/bd-resolve-conflicts`, `scripts/bd-reconcile-fork`, the fork and partition checks in `bd-health`, and the claim-sync; keep the jsonl export as a timer on the server host and an hourly `bd dolt push` from there as the backup.

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
| Hook drift | Only on a machine still running a copy of the hook under `~/.claude/hooks/`: it is not the file `templates/` ships. Settings that reference the template in place pass by construction. |
| Export fork | `.beads/issues.jsonl` and the Dolt store hold different issues. |
| `in_review` backlog | Size and age. A growing backlog means merged PRs are not citing bead ids, or the sweep is dead. |
| `BEADS_DIR` wiring | Resolves to a real database. |
| Setup drift | The other files copied out of `templates/` are not current, or no periodic checker is installed. |
| Git remote history | The settings below are in place, the running server has read them, and dolt is 2.5.0 or later. Without them publishes re-upload the whole store. |
| Shared checkout convergence | The `beads/` checkout is on `main` and keeping up with `origin/main`. Reports commits the sync hook will not reset over once they have blocked it for a day (named, with the runbook), or a checkout more than 100 commits behind. The Dolt data syncs regardless, so this is the only thing that notices a machine running month-old tracker scripts. |

**Why this lives outside GitHub Actions:** the nightly sweep once stopped running because of an Actions billing failure — the job was *never started*, so no step inside the workflow could report its own death. Eight nights failed unnoticed while the `in_review` backlog grew past 360 beads. Any watchdog for a scheduled job has to run somewhere other than that job, which is why this one runs from your laptop's session hooks.

If `bd-health` reports a dead sweep, check your repo's Actions tab and fix the underlying cause; a dead sweep is a billing, permissions, or schedule problem, not something the script can repair.

### Dolt's history on the git remote

Every publish adds commits to `refs/dolt/data`. By default Dolt starts over with a parentless commit when that chain reaches 64 commits, or when a publish drops a table file, which every conjoin does. Git leaves out only what a parent edge says the remote already has, so a parentless commit sends the whole store. On 2026-11-04 one changed table file of 10.8 MiB was a 2.68 GB upload, which GitHub refuses over 2 GiB (`pack exceeds maximum allowed size` in the server log) and which outlasts the 900 s push bound. At two commits a publish that is about every 32nd publish across every machine, and it partitions whichever machine draws it. It looks like a slow link or a store rewrite, and it is neither.

Two settings turn it off, in the database's own `.dolt/config.json`:

```sh
git-remote.max-history-commits = 0          # 0 is unlimited, the default is 64
git-remote.reset-history-on-prune = false   # the default is true
```

The sync hook writes them and `bd-health` reports a machine that does not have them. Three things are worth knowing:

- **Both are needed.** With the limit alone, the next conjoin still goes parentless.
- **dolt 2.5.0 is the minimum.** An older dolt has the limit and no setting for it, so `brew upgrade dolt`. The nightly's dolt is pinned in `.github/workflows/`, and it sets the same two values globally.
- **bd's own Dolt cannot keep history.** bd embeds a Dolt library, and both 1.1.0 and 1.3.4 embed one from before 2.5.0. Whatever publishes through bd's embedded engine therefore cuts history at 64 commits, and upgrading bd does not change that. The laptops publish through the sql-server, which is the `dolt` binary, so they are covered. A machine still on embedded Dolt (bd-health check 9) is not. The nightly runs bd embedded, so it publishes with `dolt push` from the CLI.
- **A server keeps what it read.** It reads these once, when it first opens the remote, and a changed value does nothing until it restarts. The hook restarts a server older than the config, once, when the inspector confirms there is no remote work on it. Otherwise it leaves the restart to the next sync and prints a WARNING with the inspector's answer, because a deferral repeats until something changes. `scripts/bd-dolt-server restart` does the same by hand, once no push is running. `bd` fails fast for about 13 s during a restart.

**The price:** the remote now keeps its history, because old table files stay reachable and GitHub cannot collect them. Measured growth was 42.7 MiB over one 7-hour window, so roughly 145 MiB a day against 2.7 GB on 2026-11-04. A limit of any size is not a way out, since it only moves the whole-store upload to a later moment on a random machine. If the size becomes a problem, shed the history once, deliberately. That reset has not been tried yet.

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
scripts/checkout-staleness      # shared checkouts behind origin (see above)
scripts/test-bd-health          # tests for its fork verdict; run after editing either
scripts/bd-dup-check            # likely duplicate beads (pairs known to be distinct: scripts/dup-check-known-distinct.txt)
scripts/test-bd-dup-check       # tests for that filtering; run after editing either
scripts/bd-sweep-merged         # dry-run: beads whose PRs have merged
scripts/test-bd-sweep-merged    # tests for its citation match
scripts/test-bd-sweep-merged-e2e  # tests for its whole close path, with fake bd + gh
scripts/bd-resolve-conflicts    # dry-run: how a conflicted Dolt merge would resolve
scripts/bd-setup-sync           # is this machine running the current setup?
scripts/bd-setup-report         # which machines are?
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
- **Run the Dolt sql-server, not embedded.** Embedded is single-writer and deadlocks concurrent agent sessions; it also disables `bd doctor` and `bd sql`, and `bd doctor`'s embedded-mode message suggests the destructive `bd init --force`. See "Dolt engine" in step 6. `scripts/bd-health` check 9 reports a machine still on embedded.
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

**Sync hook will not converge: hand-written commits on main**
(`bd-health`: "Shared tracker checkout is not converging"; sync log: `push rejected with N non-export commit(s) on main ... not resetting. Blocking: <sha> <subject>; ...`)

Someone committed to the shared `beads/` checkout's `main` (a script, a doc, an allowlist line) instead of working in a worktree, and `origin/main` moved before the sync hook could push it. The hook converges `main` by resetting it onto `origin/main`, and it will not reset over somebody's work — correctly — so from then on every sync refuses, and the checkout stops converging: the machine keeps running the tracker scripts and hook template from that day, and its jsonl export and setup heartbeat stop publishing. The Dolt data keeps syncing, so nothing else turns red. On 2026-09-04 three allowlist commits did this to one machine for 25 days, 429 commits behind, with the refusal logged 73 times.

Never push `main` by hand to get out of it, and do not `pull --rebase` the export commits either (they conflict on the jsonl every time). Instead:

```sh
cd "$WS/beads"
git branch "backup/main-$(date +%Y%m%d-%H%M)" main       # keep everything, first
git log --reverse --format='%h %s' origin/main..main |
    grep -vE '^[0-9a-f]+ chore: (sync issue export|setup heartbeat)$'   # what is blocking
```

1. **Land what origin is missing, through a PR.** For each blocking commit, check whether `origin/main` already has its content (`git show <sha>`, then look at the same file on `origin/main` — another machine may have recorded the same thing in other words). Cherry-pick whatever is missing onto a branch from `origin/main` in a worktree and open a PR. Allowlist lines whose beads have since closed are not missing: the file's own rule is to prune those, so leave them out.
2. **Let the hook converge.** Once a commit's change is on `origin/main` it stops blocking: the hook recognises a clean cherry-pick or the same patch (`commit_is_upstream`), drops the commit, keeps the old `main` as a `backup/beads-sync-*` branch, and resets. A stuck checkout's own `templates/` copy is as old as the checkout, so run origin's copy as in the snippet below. An appended ledger line whose neighbours moved upstream is *not* recognisable that way (the same line in a different place is a judgement, not a git fact). For those, and for commits you have decided to discard, name them for one full run of the hook:

   ```sh
   pgrep -fl beads-sync || true                          # wait until this prints nothing
   # origin's copy of the hook: the stuck checkout's own templates/ is as old as the checkout
   git -C "$WS/beads" fetch -q origin main
   git -C "$WS/beads" show origin/main:templates/beads-sync.sh >/tmp/beads-sync.sh
   BEADS_SYNC_DROP_COMMITS="<sha> <sha>" sh /tmp/beads-sync.sh "$WS/beads"
   git -C "$WS/beads" status -sb                          # main...origin/main, at most the export modified
   ```

   It is the hook's own convergence under its own lock: it still refuses over uncommitted work outside the export, never replays a named commit onto `origin/main` (a rebase would push it), keeps the previous `main` as a branch, and carries this machine's `interactions.jsonl` records across the reset. That file is not an export — bd appends to it and nothing regenerates it — so a bare `git reset --hard` destroys every record not yet pushed (570 of them in the case that prompted this). `issues.jsonl` needs nothing: the next `bd` write re-exports it from the database, and the next sync commits it.

Keep the backup branch until the next `bd-health` is clean.

**Bead stuck in `in_progress` or `in_review` after the PR merged**
The PR probably did not delivery-cite the bead: no `Bead:` line naming it, or a `Bead:` line naming only other beads (which makes the title and branch context). Close it by hand: `bd close <id> --reason="delivered in <PR url>"`.

**`bd-health` says the nightly sweep is stale**
Open your repo's Actions tab. Most likely causes, in order: GitHub Actions billing/spend limit (the job shows as failed in ~4s with "the job was not started"), an expired `BEADS_SWEEP_TOKEN`, or GitHub having disabled the schedule after repo inactivity.

**`bd-health` says "Tracker fork"**
`.beads/issues.jsonl` and your local Dolt store hold different issues, so the tracker has split into two lineages. The database is the source of truth; the jsonl is only its export.

- *JSONL-only records*: someone else's lineage is ahead of yours. `scripts/bd-export-jsonl` will not overwrite them, so the sync hook logs a `jsonl export (rc=3)` block in `~/.claude/logs/beads-sync.log` and leaves the file alone. Fix by pulling their lineage in: `bd dolt pull` (the sync hook does this), then let the next hook run rewrite the jsonl.
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

**Row conflicts self-heal now.** Since `scripts/bd-resolve-conflicts`, the sync hook resolves a conflicted pull mechanically: ours as the base, the OTHER lineage's closes re-applied via `bd close` (never lost), OUR closes never reopened, counter tables taken as MAX, and a `dependencies` row taken as ours when both sides describe the SAME edge (two machines filing a child of one parent both mint `<parent>.1`, and the edge-derived key makes them the same row differing only in `created_at`/`created_by`; a different edge, or a side that deleted the row, still refuses). A close whose re-apply fails is journaled in `.beads/auto-resolve-pending-closes` and retried on every sync until it lands. What still stops the sync for a human — and prints the hint pointing here — is a SCHEMA conflict, a conflicted table outside the resolver's whitelist (issues, child_counters, issue_counter, dependencies), a dependency conflict whose two sides disagree about the edge, an ID COLLISION (see below), or a resolver failure; only then run the recipe below. Do not reach for it on the first conflict line you see in the log: check `tail ~/.claude/logs/beads-sync.log` first — an `auto-resolve (rc=0)` entry right after the conflict means it is already healed.

The manual recipe follows. Without the auto-resolve this never heals on its own: every later pull aborts identically, every push stays rejected non-fast-forward behind it, and the machine is partitioned from the tracker in both directions while everything else looks green. Once, this hid a twin-fix race for a whole incident.

```sh
# 1. Take the sync lock so no session hook can interleave (wait for any
#    in-flight beads-sync.sh first: pgrep -f beads-sync.sh):
mkdir ~/.claude/locks/beads-sync-<workspace>.lock

# 2. The Dolt repo is a normal dolt directory. In server mode it lives at
#    .beads/dolt/<db>; on a machine still running embedded, .beads/embeddeddolt/<db>.
cd "$WS/beads/.beads/dolt/<db>"    # or .beads/embeddeddolt/<db> if still embedded
dolt config --local --add user.name  "<your name>"
dolt config --local --add user.email "<your email>"

# 3. Merge and inspect - the conflicts are usually beads both sides
#    closed, differing only in timestamps:
dolt fetch origin
dolt merge origin/main
dolt sql -q "SELECT * FROM dolt_conflicts_issues" -r json   # read our_/their_ pairs

# 4. Resolve. Follow bd-resolve-conflicts' policy, not either wholesale side:
#    --theirs reopens beads this machine closed, --ours discards the other
#    side's closes, and timestamps are NOT a tiebreaker (the reconcile
#    import makes ours synthetically newer). Ours as base, then re-apply
#    every close where their_status='closed' and ours is not (bd close, so
#    the audit trail is real); counters take the MAX of the two sides:
dolt conflicts resolve --ours issues
dolt commit -m "operator merge: join remote lineage, resolve issue conflicts"
dolt push origin main

# 5. Release the lock and let the hook converge the rest:
rmdir ~/.claude/locks/beads-sync-<workspace>.lock
sh "$WS/beads/templates/beads-sync.sh" "$WS/beads"
tail -1 ~/.claude/logs/beads-sync.log        # must say "sync OK"
```

**If the refusal says ID COLLISION, do not run step 4 as written.** One id is holding two different beads: two machines each filed a child of the same parent between syncs and both minted `<parent>.<n>` from their own local counter. Neither wholesale side is a merge here. `--ours` deletes the other machine's bead and `--theirs` deletes yours, and once `dolt_conflicts_resolve` has run the merge base advances, so the loser exists nowhere and no later pull can bring it back. The resolver refuses for exactly this reason.

Read both sides before you touch anything, because the conflict table is the last place the losing bead exists:

```sh
dolt sql -r json -q "SELECT * FROM dolt_conflicts_issues
  WHERE NOT (our_created_at <=> their_created_at)" > /tmp/bd-collision.json
```

The EARLIER `created_at` keeps the id, because that bead is the one other machines and any PR already reference. Re-file the later one under a fresh id with its own text (`bd create`, adding `--parent` if it had one), paste anything it had accumulated onto the new bead, and only then resolve and continue with step 4. Note which id became which in a comment on both, or the next person reading a PR that cites the old id has no way to find the work.

The stale-tracker marker (step 8) is removed by that first clean run. Afterwards check whether beads that were filed on other machines during the partition duplicate local ones, and fold them.

A fork that keeps returning after this is usually a hook that is not the one this repo ships — see the next entry — either here (the reconcile never runs, so the fork the sync creates is never repaired) or on the *other* machine (it is not pushing its Dolt lineage at all). Also check that `bd dolt push` succeeds there and that `sync.remote` in its `.beads/config.yaml` points at this repo.

**GitHub rejects a Dolt transfer with `pack exceeds maximum allowed size (2.00 GiB)`**

This is the host's per-push size limit, not a stale-tip conflict or evidence of
database corruption. A short timeout can hide it while Git computes deltas;
extending that timeout may expose the actual rejection but does not remove the
limit. The sync hook leaves the tracker marked stale and does not pull/retry
this rejection as a history race. Record the complete failure on the incident
bead. Preserve local data and history; do not force-push, delete the Dolt remote
cache, re-import the JSONL export, or run the operator merge recipe below solely
because of this message. Recovery needs a verified, bounded upload path for the
Dolt Git transport, under the existing sync lock. Ordinary Git's
[incremental-push guidance](https://docs.github.com/en/get-started/using-git/troubleshooting-the-2-gb-push-limit)
is not permission to rewrite Dolt-managed refs or manifests.

The opt-in [bounded upload recovery](docs/dolt-bounded-upload.md) preloads only
reachable blobs under temporary refs, preserves the original history, and
leaves final publication to the canonical sync hook. Start with its plan mode;
keep its journal through normal publication and verified cleanup.

**Every push logs `dangling chunk reference` and takes the fallback / bd feels slow**

The store has outgrown bd's hardcoded 30s pre-push fsck budget (upstream gastownhall/beads #4822) — at ~1 GB the scan cannot finish, the timeout's empty output is wrapped as a dangling-chunk error, and every push detours through the hook's direct-`dolt push` fallback. The size is almost all merge garbage, not data (this workspace: 3,978 issues had accumulated 1.2 GB across 19,120 commits). The hook now garbage-collects automatically (`maybe_gc`: over `BEADS_DOLT_GC_THRESHOLD_MB`, at most once per `BEADS_DOLT_GC_MIN_DAYS`, logged to the sync log as `dolt gc: NMB -> MMB`), so a store that keeps regrowing past the threshold within days is the finding — look at what is writing, not just at gc cadence. Run one by hand from the data directory with `dolt sql -q "call dolt_gc()"` (routes to the running sql-server; the dropped connection at the end is how dolt_gc finishes, not an error).

Do not expect gc to end the false positive, though: upstream measured fsck time against the *commit count* (38s cold vs 28.7s warm on one store, all commits reachable, `dolt gc --full` freeing nothing), and this machine's full `dolt fsck` with no budget takes 37s and reports `No problems found`. It is a timeout, not corruption, and the store is fine. Since 2026-09-16 the hook records each rescue in `~/.claude/logs/beads-fsck-false-positive-<ws>.last` and, while that marker is younger than `BEADS_FSCK_REPROBE_HOURS` (24), pushes directly with `dolt push` first instead of spending the doomed 30s on `bd dolt push` — that budget is what pushed the 60s SessionEnd claim-sync past its cap and killed it before its fallback fired. It re-probes daily and removes the marker the moment `bd dolt push` completes clean again. A rescue logs one `dolt push: ... published via direct dolt push` line; `bd-health` counts only `sync FAILED` runs, so those lines never trip it. The real fix is upstream: bd 1.3.0 ships `BEADS_FSCK_TIMEOUT` and classifies the timeout as interrupted rather than corrupt; bumping the Homebrew bd and the workflow's `BD_VERSION` together (they share the DB schema) retires the fallback.

**Upgrading bd 1.1.0 → 1.3.0: every machine moves in one window**

1.3.0 is the release that ends the fsck false positive above: it reads `BEADS_FSCK_TIMEOUT` (the hook already exports 300) and classifies a timed-out pre-push fsck as interrupted instead of as corruption. It also carries 13 main-series schema migrations (v53 → v66) plus 15 clone-local ones, and **a mixed-version team is a stopped team**: a 1.3.0 binary refuses to auto-migrate a shared server, and a 1.1.0 binary refuses a store migrated past what it knows. Every machine here runs its own `dolt sql-server` against its own copy of the store with the one shared git remote, which upstream calls the two-hazard case: the designated-migrator flow, `bd migrate --force` from exactly one machine followed by `bd dolt push`, with every other machine re-cloning.

Rehearsed 2026-09-16 on an isolated scratch copy of this machine's 2.8 GB store: the migration took about 5 minutes, prints nothing unless stderr is a terminal (piped, it looks stuck; it is not), preserved the custom `in_review` status, and accepted dolt 2.3.2. Two traps from the rehearsal: in embedded mode 1.3.0 opens only `.beads/embeddeddolt/` and will silently create an EMPTY store there rather than touch the server-mode `.beads/dolt/` layout, and its auto-import into a fresh database still rejects `in_review` until `status.custom` is set. Machines list: `scripts/bd-setup-report`.

Order matters, and the `BD_VERSION` PR merges **last**:

```sh
# 0. Announce a window (~30 min, and keep the whole thing under 6h: while the
#    gate refuses writes, every session hook logs a failed sync, and the stale
#    marker auto-files a P1 "tracker partitioned" bead after 6h).

# 1. EVERY machine, with the OLD bd: publish, confirm, back up.
sh "$WS/beads/templates/beads-sync.sh" "$WS/beads" --quick      # or let the session hook run
tail -1 ~/.claude/logs/beads-sync.log                          # must be "sync OK"
cd "$WS/beads" && bd export --all -o .beads/backup/pre-1.3.0-$(date +%Y%m%d).jsonl
# Anything not pushed here is lost to step 4's re-clone.

# 2. EVERY machine: install 1.3.0. Reads keep working; writes and
#    bd dolt push/pull are refused by the gate until step 3 - expected.
brew unpin bd && brew upgrade bd && brew pin bd
which -a bd                                                    # exactly one binary
bd version                                                     # 1.3.0

# 3. ONE machine, the designated migrator, from a real terminal (the 28-line
#    counter visibly restarts at 0012 partway through; that is the clone-local
#    series, not a loop - let it finish, ~5 min here):
cd "$WS/beads" && bd migrate --force
bd doctor                                                      # follow any server-restart guidance it prints
bd dolt push                                                   # publishes the migrated schema (BEADS_FSCK_TIMEOUT=300 is exported by the hook; set it here too)

# 4. EVERY OTHER machine:
cd "$WS/beads" && bd dolt pull                                 # if refused as schema-skewed:
bd bootstrap                                                   #   replaces the local database from the migrated remote - safe only because step 1 pushed
bd doctor
bd statuses | grep -q in_review || bd config set status.custom "in_review:wip"

# 5. Merge the BD_VERSION 1.3.0 PR. The nightly bootstraps from the migrated
#    refs/dolt/data; check the next run is green.

# 6. Verify, everywhere: bd-health's version-drift finding is gone, and the
#    sync log shows "bd pre-push fsck completed clean again; bd dolt push is
#    back in front of every push" - the hook removes its own fsck marker on
#    the first clean bd dolt push, so the fallback retires itself.
```

Rollback is a schema-cursor rollback, not a data downgrade: upstream `docs/recovery/accidental-1-2-1-release.md` (worked example v53↔v65; same steps for v66 with the numbers adjusted). Take it before anyone writes on the new schema, or the step-1 exports are the fallback.

Related: **auto-backup is disabled tracker-wide** in the committed `.beads/config.yaml`. It duplicated the Dolt remote + jsonl recovery paths while growing an unpruned `.beads/backup` to 15 GB, and its re-registration step failed on every commit after the server-mode migration. If your machine still carries a large `.beads/backup`, delete the directory.

**`bd-health` says the installed sync hook differs from the template**
Your settings still run a copy of the hook under `~/.claude/hooks/`, and it is not the same as `templates/beads-sync.sh`. Nothing versions a copy, so this cannot be seen any other way — and an old hook fails silently: it keeps syncing, so nothing else looks wrong. A copy predating the fork reconcile does not run `scripts/bd-reconcile-fork`, which means it re-forks the tracker on every sync.

Point the settings at the template in place (step 8), then delete the copy. There is nothing left to drift after that. If the difference is an *uncommitted local edit* to the template, commit it here instead — team rules belong in `templates/`, or everyone's agents drift apart.

**`bd-health` says the sync last succeeded N days ago, or has no successful-sync line**
The `beads-sync.sh` hook has stopped running on this machine — check the SessionStart/SessionEnd wiring in `$WS/.claude/settings.json` (step 8) and that `$WS/beads/templates/beads-sync.sh` is still there. Your bead changes are staying local until it runs. The "no successful-sync line at all" wording means the log has never recorded a clean run, which is only reported once the installed hook is known to be current — an old hook does not write the heartbeat, so for those the silence means nothing and the check stays quiet.

**Logs to check**

```
~/.claude/logs/beads-sync.log        # remote sync
~/.claude/logs/beads-sweep.log       # merged-PR sweep actions
~/.claude/logs/beads-dup-check.log   # duplicate findings
~/.claude/logs/beads-health.log      # tracker health findings
~/.claude/logs/beads-setup-sync.log  # setup distribution checker
```


### Server-side remote work after a sync timeout

A timeout bounds the `bd` or `dolt` client. In server mode the SQL server
may still own a Git push and its SSH transport. The hook now records those
children separately; it never treats client termination as proof of remote
idleness and never stops the SQL server.

`scripts/bd-dolt-remote-children /absolute/path/to/beads` is report-only.
The normal sync hook uses its `--apply` mode under the sync lock. The
tracker's server is the one `dolt sql-server` whose working directory is
`.beads/dolt`, whether bd or the launchd agent started it (the rule
`bd-dolt-server` uses too). A `--socket` naming any other path, or a second
server on the same directory, is unknown ownership. Until 2026-11-05 it also
required the launchd agent's socket, so on a machine where bd starts its own
server every inspection answered "unknown". Only direct Git push
children targeting `refs/dolt/data` and their direct SSH receive-pack children
can receive TERM. The threshold is the larger of `BEADS_DOLT_STEP_TIMEOUT`
(default 300s) and `BEADS_DOLT_PUSH_FALLBACK_TIMEOUT` (900s), plus the kill
grace (20s). A visible bd/dolt remote or SQL client on any tracker suppresses
termination conservatively. PID, start time, parent and server ownership are
rechecked before each signal. Unknown inspection, younger uploads, other
trackers and ordinary source-code pushes are retained. A TERM is logged as a
request; surviving children remain visible. There is no KILL escalation here.

The hook defaults Git SSH to batch mode, a 15s connect timeout and server
keepalives every 30s with three missed replies allowed. An explicitly supplied
`GIT_SSH_COMMAND` is preserved. `scripts/bd-dolt-server install` writes the
same defaults into the launchd service environment. Existing SQL servers do
not inherit a new environment: apply that change during an idle maintenance
window, since `install` restarts the tracker. Do not restart a busy server
merely to make a health report green. Review custom SSH settings before
reinstalling the service.

DNS, route and SSH connect failures get a distinct `beads-tracker-offline-*`
marker and `sync OFFLINE` heartbeat. `bd-health` reports a warning rather than
counting them as failed convergence. Local duplicate checks are still stale.
An offline failure never clears an older partition marker; only a fully clean
sync clears either marker. Mixed errors, authentication failures and timeouts
remain ordinary failures. A laptop's DarkWake is not evidence of a Dolt merge
conflict, and connectivity recovery is not proof that unpublished data synced.
