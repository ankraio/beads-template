# beads-template

A production-hardened team setup for [**beads**](https://github.com/gastownhall/beads) (`bd`) — the issue tracker that lives in a Dolt database next to your code instead of in a web UI, so AI coding agents can read and write it as a first-class citizen.

Beads gives you the tracker. This repo is everything we had to build *around* it to run a team of humans and agents on one shared tracker across several machines: the health checks, the merged-PR sweep, the fork reconciler, the setup-distribution checker, and the agent rules that make every teammate's coding agent behave the same way.

It is a **GitHub template**. Click *Use this template*, work through [SETUP.md](SETUP.md), and you have a working shared tracker.

**→ [QUICKSTART.md](QUICKSTART.md)** — one page from zero to `bd ready` with agents wired.
**→ [SETUP.md](SETUP.md)** — the long form: install, wiring, agent rules, daily workflow, health, security, runbooks.

---

## Why this exists

Every piece of automation around a beads tracker has to be **fail-soft** — it runs from editor session hooks and must never block a session. The unavoidable consequence is that **a broken tracker looks exactly like a healthy one.**

Everything in here is a specific, dated answer to a specific way that bit us:

| What went wrong | What now catches it |
|---|---|
| The nightly sweep stopped running on an Actions billing failure. The job never *started*, so no step inside it could report its own death. Eight nights failed unnoticed while the review backlog grew past 360 beads. | `scripts/bd-health` watches the sweep from **outside** Actions — from your laptop's session hooks. A watchdog for a scheduled job cannot live inside that job. |
| Two machines' exports diverged into separate lineages. bd warned on every single write; everyone scrolled past it for days. | `bd-health` diffs the jsonl against the Dolt store, and `scripts/bd-reconcile-fork` heals the ordinary case automatically on every sync. |
| A laptop kept running a two-day-old copy of the sync hook. Nothing versions a file that lives outside every git repo, so the tracker re-forked on every sync for three days while every check stayed green. | `bd-health` `cmp`s the installed hook against the template, and `scripts/bd-setup-sync` does the same for *all* the copied-out files — then publishes a per-machine heartbeat so you can see who else is behind. |
| A merged PR listed its follow-up beads in body prose, and the sweep closed work that had not shipped. | `bd-sweep-merged` only trusts **delivery citations**: the bead id in the PR title, the branch name, or a `Bead:` line. Body prose never closes a bead. |
| A GitHub GraphQL outage made every PR lookup fail. The errors were discarded and the run reported "PRs not all merged" for beads whose PRs *had* merged — indistinguishable from a healthy run. | A failed lookup falls back to REST, retries, and if it still cannot answer is reported as `DEGRADED` and exits 3. **"Could not tell" is never reported as "no".** |
| Two sessions filed the same follow-up, then two agents raced on one change. | `scripts/bd-dup-check` at session start, plus a documented rule that incident-class work claims on GitHub (a draft PR) rather than in the tracker, because sync cannot referee a race it only learns about at session boundaries. |
| A bead closed on a PR that merged six days *before* the work started and named it in passing. | Merged PRs that predate the bead's `started_at` are discounted, reported, and neither close nor block. |

The through-line: **an instrument that cannot observe must never report as though it had.** Every verdict in here is three-valued or better, and every check that can fail says so out loud.

---

## What is in here

| Path | Purpose |
|---|---|
| [QUICKSTART.md](QUICKSTART.md) | One page: install, clone, wire, verify. Start here. |
| [SETUP.md](SETUP.md) | The setup and operations guide, with the runbooks. The one document to keep current. |
| `templates/workspace-CLAUDE.md` | Agent rules, copied to your workspace root as `CLAUDE.md`. **Edit the rules here**, not only in your local copy. |
| `templates/workspace-settings.json` | Workspace `.claude/settings.json`: `BEADS_DIR` plus the session hooks. |
| `templates/beads-sync.sh` | The session-hook sync script, referenced in place by the settings (it relocates itself to a temp copy at start). |
| `scripts/bd-health` | Reports tracker automation that has quietly died. Report-only. |
| `scripts/bd-dup-check` | Reports likely-duplicate beads. Report-only. Run hourly by `bd-hygiene`, no longer at session start. |
| `scripts/bd-dolt-server` | Shared-server kit: run `dolt sql-server` as a supervised launchd agent, optionally network-bound, and point bd at it. |
| `scripts/bd-hygiene` | Hourly hygiene from one host: duplicates, stale beads, oldest in_progress/in_review. Findings go to a log file. |
| `templates/PRIME.md` | Copied to `.beads/PRIME.md`: what `bd prime` injects at session start, the team's rules in ~2 KB instead of bd's 111 KB default. |
| `scripts/bd-sweep-merged` | Closes beads whose delivering PRs have all merged. Dry-run by default. |
| `scripts/bd-reconcile-fork` | Heals an export fork: imports JSONL-only beads into the local Dolt store. Dry-run by default. |
| `scripts/bd-setup-sync` | Is *this* machine running the current setup? Installs what is stale; refuses to overwrite what may be newer. |
| `scripts/bd-setup-report` | Which machines are behind, not-applied, or silent. |
| `scripts/test-bd-*` | Offline test suites — no network, no token, no database. They pin every judgement call above. |
| `.github/workflows/nightly-review-sweep.yml` | Nightly sweep with GitHub-side PR discovery. |
| `.agents/`, `.codex/`, `.claude/` | Agent integration for Claude Code, Codex, and the `beads` skill. |

Everything marked **`EDIT ME`** is meant to be changed. The rest is meant to be kept.

---

## Quick start

```sh
gh repo create <your-org>/beads --private --template ankraio/beads-template --clone
cd beads
# then follow SETUP.md
```

Verify the shipped scripts before you trust them:

```sh
bash -n scripts/bd-*                  # syntax
scripts/test-bd-dup-check             # offline
scripts/test-bd-health                # offline
scripts/test-bd-sweep-merged          # offline
scripts/test-bd-sweep-merged-e2e      # offline: fake bd + fake gh, ~30 scenarios
scripts/test-bd-setup-sync            # offline
```

All six suites run in a few seconds with no network, no GitHub token and no bd database.

The nightly sweep ships **enabled in your copy** (Actions is off on the template
repo itself, which has no tracker to sweep). Before its first run, set the
`BEADS_SWEEP_TOKEN` repo secret and edit `BD_SWEEP_REPOS` in the workflow —
without them it degrades to a loud no-op.

---

## Two rules worth knowing before you touch anything

1. **Cite the bead id in every PR** — on a `Bead: <id>` line in the body (`Beads: <a>, <b>` for several). That citation is the only thing that lets automation close the bead when the PR merges. A mention in body prose does not count. The title and the branch name are fallbacks: a `Bead:` line, when present, is the whole list; without one the title's ids count; with neither, only the id the branch name starts with.
2. **Don't hand-run `bd dolt push` / `bd dolt pull`** if you have the session hooks installed. Concurrent manual syncs forked one tracker into two divergent lineages for five days.

---

## Health

```sh
scripts/bd-health
```

Silent when clean. It is the thing that tells you when the nightly sweep has stopped running (which it cannot detect about itself), when the sync hook has stopped running on this machine, when your installed hook is not the one this repo ships, and when the export and the database have forked into two lineages.

---

## Notes and caveats

- **macOS-first.** The scripts run on bash 3.2 and BSD `stat`/`date`, and fall back to the GNU spellings, so they also work on a Linux CI runner. The `--install-cron` path uses launchd on macOS and crontab elsewhere.
- **The `bd` version pin in the workflow is an example.** Pick a version, pin it everywhere, and bump the laptops and CI together — the Dolt schema is tied to it.
- **Comments are long on purpose.** Each one records the incident that motivated the code, because the next person to "simplify" a check needs to know what it was buying. If you fork this, keep them.

---

Last refreshed from the production setup on 2026-11-06. Built at [Ankra](https://ankra.io) and shared as-is under the [MIT license](LICENSE). Upstream beads: https://github.com/gastownhall/beads
