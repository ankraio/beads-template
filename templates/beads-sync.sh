#!/bin/sh
# Sync a shared beads issue tracker with its GitHub remote.
#
# Install: cp templates/beads-sync.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/beads-sync.sh
# Wire it into SessionStart/SessionEnd as described in SETUP.md step 8.
#
# Runs from Claude Code session hooks; must never block or fail the session,
# so every step is fail-soft and the whole run is lock-guarded against
# concurrent sessions syncing at the same time.
#
# Fail-soft is NOT fail-silent: a swallowed `bd dolt pull` merge conflict
# forked the tracker into two divergent lineages for 5 days in July
# 2026 (every pull aborted, every push was rejected non-fast-forward, and
# no one saw either). Dolt sync failures are logged to
# ~/.claude/logs/beads-sync.log and echoed to stdout so SessionStart
# surfaces them in the session context. Successful runs log an OK
# heartbeat to the same file, so a hook that has stopped running is
# distinguishable from one that has nothing to complain about.
#
# Usage: beads-sync.sh [beads-repo-dir] [--quick]
#   Pass the path to the beads repo -- REQUIRED. Each workspace passes its
#   own, which is what lets one machine run more than one tracker.
#
#   --quick is the claim-sync: commit + pull + reconcile + push only, no
#   merged-PR sweep and no git jsonl export. Agents run it right after
#   `bd create` / `bd update --claim` on a P0/P1 so the claim crosses
#   machines in seconds instead of at session end - the session-boundary
#   cadence is why two machines once shipped two fixes for the same incident
#   on the same afternoon without ever seeing each other's bead. Re-run
#   `bd find-duplicates` after it returns.

MODE=full
BEADS_REPO=""
for arg in "$@"; do
    case "$arg" in
        --quick) MODE=quick ;;
        *) BEADS_REPO="$arg" ;;
    esac
done
if [ -z "$BEADS_REPO" ]; then
    # No default on purpose. A hardcoded fallback path silently syncs the
    # wrong tracker on a machine that runs two, and a hook that points at a
    # directory nobody uses fails in the one way nothing here can see.
    echo "beads-sync: pass the path to your beads repo, e.g. beads-sync.sh \"\$HOME/work/myworkspace/beads\"" >&2
    exit 0
fi
WS_NAME=$(basename "$(dirname "$BEADS_REPO")")
LOCK="$HOME/.claude/locks/beads-sync-$WS_NAME.lock"
SYNCLOG="$HOME/.claude/logs/beads-sync.log"

# While this file exists, the local tracker is partitioned from the remote
# and every bd-side duplicate check (bd-dup-check, bd find-duplicates,
# grepping bd list) is blind to other machines - in BOTH directions. It is
# written on sync failure and removed on the first clean sync; it keeps its
# first-failure timestamp so its age measures the partition, not the latest
# retry. bd-dup-check and the agent workflow rules read it.
STALE_MARKER="$HOME/.claude/logs/beads-tracker-stale-$WS_NAME"

mkdir -p "$HOME/.claude/locks" "$HOME/.claude/logs"

# Drop a stale lock left by a crashed run (older than 10 minutes).
find "$LOCK" -maxdepth 0 -type d -mmin +10 -exec rmdir {} \; 2>/dev/null

# Another sync is already in flight - it will carry our changes too. A
# quick-mode caller is an agent waiting on the answer, so say that instead
# of silently returning.
if ! mkdir "$LOCK" 2>/dev/null; then
    [ "$MODE" = quick ] && echo "beads claim-sync: another sync is in flight - it carries this change; re-run bd find-duplicates when it finishes"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

cd "$BEADS_REPO" || exit 0

sync_failed=0

# Run a dolt sync step; on nonzero exit or error-looking output, log the
# full output and warn on stdout instead of swallowing it.
dolt_step() {
    step="$1"; shift
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qiE 'error|conflict|rejected|failed'; then
        printf '[%s] %s FAILED (rc=%s) in %s:\n%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$step" "$rc" "$BEADS_REPO" "$out" >>"$SYNCLOG"
        echo "WARNING: beads $step failed - tracker may not be syncing (see $SYNCLOG)"
        # This one never heals on its own: every later pull aborts the same
        # way and every push stays rejected behind it, silently partitioning
        # the machine (2026-08-22: two machines each fixed the same cluster
        # incident because neither could see the other's bead).
        if printf '%s' "$out" | grep -qi 'operator resolution'; then
            echo "HINT: Dolt merge conflict needs an operator merge - follow SETUP.md 'Dolt pull conflict: operator merge'. Until healed, a GitHub open-PR search is the only duplicate check that works."
        fi
        sync_failed=1
        return 1
    fi
    return 0
}

# The Dolt database is the source of truth; this is the real sync.
dolt_step "dolt commit" bd dolt commit
dolt_step "dolt pull"   bd dolt pull

# A pull can only bring in what the other lineage actually pushed to
# refs/dolt/data. Issues it never pushed reach this machine only as jsonl,
# through the git convergence at the bottom of this script - and bd then
# refuses to auto-export over them (correctly: they are the only local copy).
# That refusal freezes the export permanently, so the committed jsonl and the
# GitHub issue view stop tracking reality until a human reconciles by hand.
# Healed 2026-08-17, 2026-08-18 and 2026-08-19
#; back within a day every time, because the mechanism that
# produces it runs on every sync and the repair ran once. Merging those
# records in here is the same repair, on the same schedule as the cause, so a
# fork now costs one session instead of a day. Union merge only: it imports
# ids the database does not have, and never rewrites one it does.
if [ -x "$BEADS_REPO/scripts/bd-reconcile-fork" ]; then
    reconcile_out=$(BEADS_DIR="$BEADS_REPO/.beads" \
        "$BEADS_REPO/scripts/bd-reconcile-fork" --apply --quiet 2>&1)
    reconcile_rc=$?
    if [ -n "$reconcile_out" ]; then
        printf '[%s] reconcile-fork (rc=%s) in %s:\n%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$reconcile_rc" "$BEADS_REPO" "$reconcile_out" >>"$SYNCLOG"
        echo "$reconcile_out"
    fi
    if [ "$reconcile_rc" -ne 0 ]; then
        echo "WARNING: beads fork reconcile did not finish - the export is still blocked (see $SYNCLOG)"
        sync_failed=1
    fi
fi

# Record what beads setup this machine is running, and publish it.
#
# The rules, the hooks and this script itself are distributed by COPYING them
# out of templates/ to places no git repo can see, so nothing versions the
# installed copies and a machine running last month's rules is invisible
# (this cost one team three days of hand-healing exactly that way). The check is
# cheap — three hashes and three compares — and this is the one place that
# runs on every machine that is doing anything at all.
#
# Its own heartbeat commit is pushed from inside bd-setup-sync, not here, and
# `chore: setup heartbeat` is whitelisted below so it never reads as
# hand-written work on main. Findings print; --quiet keeps it to those.
# Failure is never fatal: this is bookkeeping, not the sync.
if [ "$MODE" = full ] && [ -x "$BEADS_REPO/scripts/bd-setup-sync" ]; then
    setup_out=$("$BEADS_REPO/scripts/bd-setup-sync" "$BEADS_REPO" --quiet 2>&1)
    setup_rc=$?
    if [ -n "$setup_out" ]; then
        printf '[%s] setup-sync (rc=%s) in %s:\n%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$setup_rc" "$BEADS_REPO" "$setup_out" \
            >>"$HOME/.claude/logs/beads-setup-sync.log"
        echo "$setup_out"
    fi
fi

# Close beads whose citing PRs merged while no session was watching
# (the classic zombie: session ends at PR-open, merge lands later).
# The sweep only closes a bead when a merged PR cites the bead id back,
# so context mentions of other PRs can never close unfinished work.
# Quick mode skips it: the sweep does GitHub lookups and the claim-sync
# needs to return in seconds.
if [ "$MODE" = full ] && [ -x "$BEADS_REPO/scripts/bd-sweep-merged" ]; then
    BEADS_DIR="$BEADS_REPO/.beads" "$BEADS_REPO/scripts/bd-sweep-merged" --apply --quiet \
        >>"$HOME/.claude/logs/beads-sweep.log" 2>&1
    sweep_rc=$?
    # Exit 3: GitHub would not resolve some PR states, so those beads stayed
    # open on an unknown state. Silent here would mean a degraded sweep looks
    # exactly like a clean one - the bug this exit code exists to fix.
    if [ "$sweep_rc" -eq 3 ]; then
        echo "WARNING: beads sweep ran degraded - GitHub PR lookups did not resolve (see $HOME/.claude/logs/beads-sweep.log)"
    fi
    # Exit 5: an in_review bead records a PR that delivers a DIFFERENT bead.
    # Surfaced here because the sweep's own output goes to the log file, and
    # this is the one finding nothing else will ever revisit: the bead looks
    # referenced, so a reader skims past it, and the nightly --search-citing
    # pass asks GitHub which PRs cite the bead and is told none.
    if [ "$sweep_rc" -eq 5 ]; then
        echo "WARNING: beads sweep found in_review bead(s) whose recorded PR delivers a different bead - they can never auto-close (see $HOME/.claude/logs/beads-sweep.log)"
    fi
    dolt_step "dolt commit" bd dolt commit
fi

dolt_step "dolt push" bd dolt push

# Maintain the stale-tracker marker (see its comment at the top). Created
# only if absent so the mtime stays the partition's start, not its latest
# retry; removed on the first clean sync.
if [ "$sync_failed" -eq 0 ]; then
    rm -f "$STALE_MARKER"
else
    if [ ! -f "$STALE_MARKER" ]; then
        printf 'partitioned since %s - see %s and SETUP.md "Dolt pull conflict: operator merge"\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SYNCLOG" >"$STALE_MARKER"
    fi
    # A partition older than 6h has outlived every session hook that could
    # have healed it in passing; file ONE machine-scoped bead so it becomes
    # work instead of a log line. The hostname in the title keeps machines
    # from twinning each other, the grep keeps this machine from twinning
    # itself, and bd writes locally even while partitioned - the bead syncs
    # out with the eventual heal and is actionable locally right away.
    if [ -n "$(find "$STALE_MARKER" -mmin +360 2>/dev/null)" ]; then
        host="$(hostname -s 2>/dev/null || echo unknown-host)"
        if ! bd list --limit 500 2>/dev/null | grep -q "tracker partitioned on $host"; then
            bd create --type=bug --priority=1 \
                --title "beads: tracker partitioned on $host - Dolt sync failing for over 6h, operator merge needed" \
                --description "Every sync on $host has failed for over 6 hours (log: $SYNCLOG, marker: $STALE_MARKER). Until healed this machine can neither see other machines' beads nor publish its own, so duplicate checks are blind both ways - claim work only after a GitHub open-PR search. Heal it with SETUP.md 'Dolt pull conflict: operator merge' (also: bd memories dolt-conflict-operator-merge)." \
                >/dev/null 2>&1
        fi
    fi
fi

# Heartbeat. Logging only failures means an ABSENT log reads exactly like a
# healthy one, so "the sync has not run on this machine in a week" was
# invisible to every watcher we have. One OK line per clean
# run lets bd-health answer "when did this last work?" as well as "what
# broke?"; the log is trimmed below because it now grows per session.
# bd-health greps 'sync OK' and reads the bracketed timestamp, so the mode
# tag stays after those.
if [ "$sync_failed" -eq 0 ]; then
    printf '[%s] sync OK (%s) in %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$BEADS_REPO" >>"$SYNCLOG"
fi
if [ "$(wc -l <"$SYNCLOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -1000 "$SYNCLOG" >"$SYNCLOG.tmp" 2>/dev/null && mv "$SYNCLOG.tmp" "$SYNCLOG"
fi

# Quick mode ends here: the jsonl export and its git convergence are
# session-boundary work, and the claim it exists to publish is already on
# the Dolt remote (or the marker above says why not).
[ "$MODE" = quick ] && exit 0

# Keep the passive jsonl export committed so the repo stays clean and the
# GitHub view of issues stays fresh. The export is regenerated from the DB,
# so on git divergence we converge to origin/main rather than fight it.
# Remove everything below to opt out of auto git commits.
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] || exit 0

if ! git diff --quiet -- .beads/issues.jsonl .beads/interactions.jsonl 2>/dev/null; then
    git add .beads/issues.jsonl .beads/interactions.jsonl 2>/dev/null
    git commit -q -m "chore: sync issue export" >/dev/null 2>&1
fi

if git push -q origin main >/dev/null 2>&1; then
    exit 0
fi

# Push rejected. Rebasing on origin/main is safe; hard-resetting onto it is
# only safe for OUR OWN export commits. Anyone who edits scripts/ or the
# docs in this repo commits to main too, and a blind `reset --hard` would
# destroy that work with no trace. Check what we would be discarding first.
git fetch -q origin main >/dev/null 2>&1
# `chore: setup heartbeat` is ours too (bd-setup-sync publishes one file per
# machine under .beads-setup/heartbeats/). Leaving it out of this whitelist
# would make every heartbeat look like hand-written work on main, so the reset
# below would refuse to run and the machine would warn about "unpushed
# hand-written commits" on every session until someone investigated.
handwritten=$(git log origin/main..HEAD --format=%s 2>/dev/null |
    grep -cvE '^chore: (sync issue export|setup heartbeat)$')

if [ "${handwritten:-0}" -gt 0 ]; then
    printf '[%s] push rejected with %s non-export commit(s) on main in %s; not resetting.\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$handwritten" "$BEADS_REPO" >>"$SYNCLOG"
    echo "WARNING: beads repo has unpushed hand-written commits and main has diverged - resolve by hand (see $SYNCLOG)"
    exit 0
fi

if ! git pull --rebase -q origin main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    git reset --hard origin/main >/dev/null 2>&1
fi
git push -q origin main >/dev/null 2>&1

exit 0
