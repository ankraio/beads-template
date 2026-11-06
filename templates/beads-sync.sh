#!/bin/sh
# Sync a shared beads issue tracker with its GitHub remote.
#
# Referenced in place from SessionStart/SessionEnd as described in SETUP.md
# step 8: it copies itself to a temp file at start, so nothing is installed.
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
if [ -z "$BEADS_REPO" ] && [ "${BEADS_SYNC_LIB:-0}" != 1 ]; then
    # No default on purpose. A hardcoded fallback path silently syncs the
    # wrong tracker on a machine that runs two, and a hook that points at a
    # directory nobody uses fails in the one way nothing here can see.
    echo "beads-sync: pass the path to your beads repo, e.g. beads-sync.sh \"\$HOME/work/myworkspace/beads\"" >&2
    exit 0
fi

# Answers "where is the beads repo, absolutely?" - the one rule, in one place,
# so scripts/test-beads-sync can pin it.
#
# The script cds INTO the repo before syncing, and everything after that
# names the repo by this variable again: the Dolt data directory the push
# fallback globs, the lock name, the stale marker, the gc marker. A relative
# argument ("beads", from an agent running the claim-sync at the workspace
# root) therefore resolved once and then never again - after the cd,
# "beads/.beads/dolt/*/" matched nothing, so the fsck-false-positive fallback
# below found no data directory and silently did not run. In the log that is
# every `... in beads:` run: 9 of 9 dangling-chunk push failures with a
# relative path had no fallback line and ended `sync FAILED (quick)`, while
# the absolute-path runs around them were all rescued. And
# since the quick run IS the P0/P1 claim-sync, the publish that mattered most
# was the one that always failed. `basename "$(dirname beads)"` is "." too,
# so those runs also took a lock and a stale marker of their own.
#   prints the absolute path, or the argument unchanged if it does not exist
#   (the cd below then fails as it always did)
abs_repo_path() {
    if [ -d "$1" ]; then
        (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}
BEADS_REPO=$(abs_repo_path "$BEADS_REPO")

# Pin THIS tracker's database, never an inherited one. A machine can run more
# than one tracker, and a session started from a shell that still carried
# another workspace's BEADS_DOLT_SERVER_SOCKET points bd at that workspace's
# sql-server: on 2026-10-01 `bd init` for a second tracker created its
# database inside the first tracker's server that way. The socket wins over
# BEADS_DIR, so pinning BEADS_DIR alone is not enough. A socket under this
# repo, or none, is kept as is.
#   pin_tracker_env <absolute-repo>: exports BEADS_DIR, and drops or sets
#   BEADS_DOLT_SERVER_SOCKET so it can only name this repo's server
pin_tracker_env() {
    export BEADS_DIR="$1/.beads"
    case "${BEADS_DOLT_SERVER_SOCKET:-}" in
        "" | "$1"/*) ;;
        *) unset BEADS_DOLT_SERVER_SOCKET ;;
    esac
    if [ -S "$BEADS_DIR/dolt.sock" ]; then
        export BEADS_DOLT_SERVER_SOCKET="$BEADS_DIR/dolt.sock"
    fi
    return 0
}
# Sourced as a library with no repo argument there is nothing to pin.
if [ -n "$BEADS_REPO" ]; then
    pin_tracker_env "$BEADS_REPO"
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
OFFLINE_MARKER="$HOME/.claude/logs/beads-tracker-offline-$WS_NAME"

mkdir -p "$HOME/.claude/locks" "$HOME/.claude/logs"

# Run from a private copy of this file. The hook is referenced IN PLACE from
# the beads checkout (SETUP.md step 8) rather than copied to ~/.claude/hooks,
# so nothing can drift - but the git convergence at the end of a run may then
# rewrite the very file being executed, and sh reads a script by byte offset,
# so a file rewritten mid-run executes a mixture of the old and new text. The
# parent waits for the copy and returns its exit code, so the hook's caller
# sees nothing different; the copy removes itself. If the copy cannot be made
# the script runs in place, as it always did.
if [ "${BEADS_SYNC_LIB:-0}" != 1 ] && [ -z "${BEADS_SYNC_RELOCATED:-}" ]; then
    _self_copy=$(mktemp "${TMPDIR:-/tmp}/beads-sync.XXXXXX" 2>/dev/null) || _self_copy=""
    if [ -n "$_self_copy" ] && cp "$0" "$_self_copy" 2>/dev/null; then
        BEADS_SYNC_RELOCATED=1 sh "$_self_copy" "$@"
        _rc=$?
        rm -f "$_self_copy"
        exit $_rc
    fi
    [ -n "$_self_copy" ] && rm -f "$_self_copy" 2>/dev/null
fi

# Reclaim a lock whose owner is gone - by asking whether the owner is still
# alive, not by how long it has held it.
#
# The rule here used to be "drop any lock older than 10 minutes", which
# measures duration, not staleness: a run that legitimately took longer had
# its OWN lock stolen while it was still working, and the next session
# started a second sync underneath it. That is the amplifier that turned one
# wedged step into a machine-wide outage on 2026-08-30 - a `bd dolt pull`
# held the embedded Dolt lock for over three hours, and because every
# SessionStart after the first ten minutes was free to start another sync, 28
# bd processes from every agent session on the box piled up behind it, none
# of which could ever acquire the lock. `bd` was unusable for hours and no
# bead could be filed or synced.
# Answers "may this lock be taken from its owner?" - the one rule, in one
# place, so scripts/test-beads-sync can pin it without running a sync.
#   0 = reclaimable (owner recorded and gone)
#   1 = held        (owner recorded and alive) - never steal it
#   2 = unknown     (no owner recorded; caller falls back to the age rule)
lock_is_reclaimable() {
    _lock_dir="$1"
    _owner=$(cat "$_lock_dir/pid" 2>/dev/null)
    [ -n "$_owner" ] || return 2
    kill -0 "$_owner" 2>/dev/null && return 1
    return 0
}

# Answers "may this Dolt lock holder be killed?" - the one rule, in one place,
# so scripts/test-beads-sync can pin it without an lsof, a kill or a sync.
#
# `timeout -k` guarantees OUR child dies. It can do nothing about a survivor
# from an earlier run that was reparented to PID 1 when its session hook was
# killed, and that is the state that actually wedges the machine: no session
# is waiting on it and nobody will ever collect its exit code. It is also what
# a hand-run `bd dolt pull` leaves behind when the operator's terminal goes
# away, which is how the 2026-08-30 wedge was produced - the holder that
# blocked 13 other sessions had PPID 1.
#
# PPID 1 is the whole test, and it is what makes reaping safe to automate: a
# bd belonging to a live session still has its shell, so a holder someone is
# waiting on is never a candidate. Kept separate from "is it old?" for the
# same reason lock_is_reclaimable is: duration is not evidence of abandonment,
# and a slow sync that gets killed for being slow is the amplifier, not the
# fix.
#   0 = abandoned (orphaned to init; reap it)
#   1 = attached   (a live parent is waiting on it) - never kill it
#   2 = gone       (no such process; nothing to do)
lock_holder_is_abandoned() {
    _ppid=$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')
    [ -n "$_ppid" ] || return 2
    [ "$_ppid" = "1" ] || return 1
    return 0
}

# Answers "is this push failure bd's pre-push fsck crying wolf?" - the one rule,
# in one place, so scripts/test-beads-sync can pin it without a remote.
#
# bd runs `dolt fsck` before every push under a HARDCODED 30s timeout, and when
# the timeout kills it the empty output is wrapped as a dangling-chunk error.
# Any database big enough to take longer than 30s to scan is therefore
# permanently unpushable through bd, while `dolt push` from the data directory
# works perfectly (upstream gastownhall/beads #4822, corroborated by #4258 and
# #5865). This machine hit it at ~982 MB, failing in ~35s, and it is what was
# actually behind the long "non-fast-forward" partition: a push that never
# succeeds leaves the local branch permanently ahead, so every later pull looks
# like the problem.
#
# THE TELL IS THE EMPTY CHUNK REFERENCE. A real finding prints chunk hashes
# after the final colon; the timeout prints nothing. So a message that NAMES
# chunks is genuine corruption and must still stop the sync - that distinction
# is the whole safety of this fallback, and it is why this is a function with
# tests rather than a grep inline.
#   0 = false positive (no chunk named; safe to push directly)
#   1 = not this failure, or a real finding with chunks named
push_fsck_false_positive() {
    printf '%s' "$1" | grep -q 'dangling chunk reference' || return 1
    # A Dolt chunk address is exactly 32 base32 characters (0-9a-v). Look for
    # one as a standalone token anywhere in the message: if fsck named a chunk,
    # this is a real finding and must NOT be treated as a false positive.
    #
    # Anchoring the search to text immediately after the phrase does not work -
    # the words in between ("aborting push to prevent propagating corrupt
    # chunks") are themselves made of base32-range letters, so a
    # skip-the-prose pattern matches them and every real finding reads as a
    # false positive. That is the dangerous direction, and the test below is
    # what caught it.
    printf '%s' "$1" | grep -qE '(^|[^0-9a-v])[0-9a-v]{32}([^0-9a-v]|$)' && return 1
    return 0
}

# Answers "should this run try `bd dolt push` at all, or go straight to the
# direct `dolt push`?" - the one rule, in one place, so scripts/test-beads-sync
# can pin it.
#
# Once the store is past bd's 30s fsck budget, EVERY push is the false
# positive above (261 of 261 in one log window), and each one costs the
# budget itself before the fallback can even start: 30s of fsck that ends in
# no verdict, then the 20-50s direct push. The SessionEnd claim-sync runs
# under Claude Code's hard 60s hook cap, so that arithmetic is what produced
# the runs that logged `dolt push FAILED` and then nothing at all - killed
# between the doomed probe and the push that would have worked.
# And upstream measured why the flap is a flap: fsck time tracks the commit
# count, 38s cold and 28.7s warm on one store, so gc frees nothing and the
# only thing that ever made a push succeed was a warm page cache.
#
# So while the false positive is KNOWN - the marker records the last time the
# fallback rescued one - the run pushes directly first and spends nothing on
# the probe. It is not permanent: the probe is retried once the marker is
# older than BEADS_FSCK_REPROBE_HOURS, and a `bd dolt push` that then
# completes clean (bd's guard finished within budget again, or bd grew a
# real fix: 1.3.0 ships BEADS_FSCK_TIMEOUT) removes the marker and puts bd's
# check back in front of every push. A real finding still stops the sync on
# the probe path, exactly as before; what is skipped in between is a check
# that was structurally unable to finish, not one that was passing.
#   0 = probe (no marker, or it is older than the re-probe window - or the
#       window is 0, which disables the skip)
#   1 = known false positive; push directly
fsck_probe_due() {
    _marker="$1"; _hours="$2"
    [ -f "$_marker" ] || return 0
    [ "${_hours:-0}" -gt 0 ] 2>/dev/null || return 0
    [ -n "$(find "$_marker" -mmin +"$((_hours * 60))" 2>/dev/null)" ] && return 0
    return 1
}

# Strip dolt's CR-animated progress spinner from captured output before it is
# classified or logged. dolt writes "- Pulling...\r\ Pulling...\r| Pulling..."
# even when stdout is not a TTY, so one failed pull used to put a 2,000-column
# spinner wall into the log with the actual error buried at the end of it —
# and the final frame shares its line with the first real output line
# ("\ Pulling...Auto-merging issues"), so whole-line filtering alone misses
# it. Frames become lines (tr), frame prefixes are peeled off mixed lines
# (sed), and what remains is the output a human was looking for.
strip_dolt_noise() {
    printf '%s' "$1" | tr '\r' '\n' |
        sed -E 's#^([-\\|/] [A-Za-z][A-Za-z ]*\.\.\.)+##' |
        grep -v '^[[:space:]]*$'
}

# Answers "did this sync step fail?" from its exit code and output - the one
# rule, in one place, so scripts/test-beads-sync can pin it.
#
# The output grep exists because bd has swallowed exit codes before: the
# July 2026 fork ran on a `bd dolt pull` whose merge conflict exited 0. But
# grepping the whole output at rc=0 overshoots in the other direction - bd
# prints benign per-write warnings ("Warning: auto-backup failed ... already
# exists") that contain the word "failed", and those logged every SUCCESSFUL
# commit as "dolt commit FAILED (rc=0)" and tripped the stale-tracker marker
# for a sync that was fine. At rc=0, Warning-prefixed lines are
# bd editorializing, not the step failing; a swallowed conflict still matches
# because dolt prints "CONFLICT (content)" with no Warning prefix.
#   0 = failure, 1 = success
step_output_is_failure() {
    [ "$1" -ne 0 ] && return 0
    printf '%s\n' "$2" | grep -v '^Warning:' | grep -qiE 'error|conflict|rejected|failed' && return 0
    return 1
}

# Answers "was this push refused because another machine published first?" -
# the retryable rejection, as opposed to fsck findings or auth failures.
# A generic rejection is not evidence of a stale tip: host pack-size limits,
# permissions and receive hooks also reject pushes. Retrying those can spend
# another full transfer budget without addressing the actual failure.
push_is_rejected_nonff() {
    printf '%s' "$1" | grep -qiE 'non-fast-forward|fetch first|tip of your current branch is behind'
}

# --- git convergence of the shared checkout --------------------------------
# The helpers below decide what the convergence at the bottom of this script
# may throw away. They are functions for the same reason the rules above are:
# scripts/test-beads-sync pins them against real scratch git history, and
# scripts/bd-health sources this file to ask the SAME question ("what is
# blocking this checkout?") rather than keeping a second answer that drifts.
#
# Why it matters: a hand-written commit on the shared checkout's main blocks
# the reset, correctly - but it blocked it forever. On 2026-09-04 three
# known-distinct allowlist commits landed on this machine's main, origin moved
# before the hook could push them, and every sync for 25 days logged "not
# resetting" into a file nobody reads. The checkout ended 429 commits behind,
# so the machine ran month-old tracker scripts and never published its export
# or heartbeat, while every check stayed green.

# Subjects of the commits this hook (the jsonl export) and bd-setup-sync (the
# per-machine heartbeat) write on main. Both are regenerated from their source
# on the next run, so a reset that drops them loses nothing. Anything else is
# somebody's work.
EXPORT_SUBJECTS_RE='^chore: (sync issue export|setup heartbeat)$'

# Answers "is this commit's change already on <upstream>?" - the rule that lets
# a hand commit that has since been landed through a PR stop blocking.
#   0 = already upstream: dropping it loses nothing
#   1 = not upstream, or could not tell (never guessed as upstream)
#
# Two of git's own notions of "already applied", either one sufficient:
#   - re-applying it to upstream changes nothing: a clean three-way
#     cherry-pick whose result IS upstream's tree. This is what a squash-merged
#     PR carrying the same change (plus other edits elsewhere) looks like.
#     Needs `git merge-tree --merge-base` (git >= 2.40); older git skips it.
#   - `git cherry`'s rule: some upstream commit has the same patch-id, even if
#     upstream has moved on from it since. Only upstream commits touching this
#     commit's paths are diffed: plain `git cherry` over the 429-commit
#     divergence took 30s, because every export commit diffs the 27 MB jsonl.
# Neither matches an append to a ledger whose neighbours moved (allowlist
# lines): the same line in a different place is a judgement,
# not a git fact, and that case keeps the SETUP.md runbook.
#
# A commit that also touches the jsonl export is somebody's `git commit -a` in
# the shared tree. It is never judged upstream here - and diffing the export
# across hundreds of commits would stall the hook anyway.
commit_is_upstream() {
    _c="$1"; _up="$2"
    _paths=$(git diff-tree --no-commit-id --name-only -r "$_c" 2>/dev/null)
    [ -n "$_paths" ] || return 1
    printf '%s\n' "$_paths" | grep -qE '^\.beads/(issues|interactions)\.jsonl$' && return 1
    _up_tree=$(git rev-parse -q --verify "$_up^{tree}" 2>/dev/null) || return 1
    if _mt=$(git merge-tree --write-tree --merge-base="$_c^" "$_up" "$_c" 2>/dev/null); then
        [ "$(printf '%s\n' "$_mt" | head -1)" = "$_up_tree" ] && return 0
    fi
    _pid=$(git show --format= "$_c" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)
    [ -n "$_pid" ] || return 1
    _base=$(git merge-base "$_c" "$_up" 2>/dev/null) || return 1
    git diff-tree --no-commit-id --name-only -r -z "$_c" 2>/dev/null |
        xargs -0 git log -p --no-merges --format='commit %H' "$_base..$_up" -- 2>/dev/null |
        git patch-id --stable 2>/dev/null | cut -d' ' -f1 | grep -qxF "$_pid"
}

# Answers "which commits would converging main onto <upstream> destroy?"
# Prints one "<short-sha> <subject>" line per commit on HEAD but not on
# <upstream>, oldest first, that is neither an export/heartbeat commit nor
# already upstream (commit_is_upstream). Merges are always listed: a merge can
# carry anybody's conflict resolution, so it is never guessed about.
# Empty output means a reset loses nothing that is not regenerated or already
# on <upstream>.
blocking_commits() {
    _bup="$1"
    _tab=$(printf '\t')
    git log --reverse --format="%H %h %P${_tab}%s" "$_bup..HEAD" 2>/dev/null |
    while IFS="$_tab" read -r _ids _subj; do
        # shellcheck disable=SC2086
        set -- $_ids
        _sha=$1; _short=$2; shift 2
        if [ "$#" -gt 1 ]; then
            printf '%s %s\n' "$_short" "$_subj"
            continue
        fi
        printf '%s\n' "$_subj" | grep -qE "$EXPORT_SUBJECTS_RE" && continue
        commit_is_upstream "$_sha" "$_bup" && continue
        printf '%s %s\n' "$_short" "$_subj"
    done
}

# Filters blocking_commits output (stdin) down to the commits NOT named in
# <acknowledged>, a whitespace-separated list of SHAs or unique prefixes.
# This is how an operator who has checked a commit by hand - its content is on
# origin in another form, or it is obsolete - lets the hook converge without
# anyone running `git reset --hard` in a tree other sessions are using:
#   BEADS_SYNC_DROP_COMMITS="<sha> <sha>" sh templates/beads-sync.sh "$WS/beads"
# A name that does not resolve acknowledges nothing.
unacknowledged_commits() {
    _ack_full=""
    for _a in $1; do
        _f=$(git rev-parse -q --verify "$_a^{commit}" 2>/dev/null) && _ack_full="$_ack_full $_f"
    done
    while read -r _short _rest; do
        [ -n "$_short" ] || continue
        _f=$(git rev-parse -q --verify "$_short^{commit}" 2>/dev/null)
        if [ -n "$_f" ]; then
            case " $_ack_full " in *" $_f "*) continue ;; esac
        fi
        printf '%s %s\n' "$_short" "$_rest"
    done
}

# One line naming up to five commits from a blocking_commits list, for the log
# and for bd-health: "abc1234 subject; def5678 subject; and 3 more".
name_commits() {
    awk 'NF { n++; if (n <= 5) printf "%s%s", (n > 1 ? "; " : ""), $0 }
         END { if (n > 5) printf "; and %d more", n - 5 }'
}

# Prints the records of the working tree's .beads/interactions.jsonl that
# <upstream>'s copy does not have, in file order.
#
# Unlike issues.jsonl, this file is NOT an export: bd appends to it directly
# and the database keeps no copy (the `interactions` table is empty), so a
# `git reset --hard` over an unpushed export commit destroys this machine's
# audit records for good. That reset is the convergence below, and it runs
# whenever a rebase of the export conflicts - on 2026-09-29 one such reset
# would have dropped 570 of them. Keyed by the record id (the
# whole line for a record without one), so it is a union: nothing upstream
# is repeated and nothing local is lost.
interactions_local_only() {
    _if=.beads/interactions.jsonl
    [ -f "$_if" ] || return 0
    _idf=$(mktemp "${TMPDIR:-/tmp}/beads-int-ids.XXXXXX" 2>/dev/null) || return 1
    git show "$1:$_if" 2>/dev/null | awk '
        NF == 0 { next }
        { k = $0; if (match($0, /"id":"[^"]*"/)) k = substr($0, RSTART + 6, RLENGTH - 7); print k }' >"$_idf"
    awk -v idfile="$_idf" '
        BEGIN { while ((getline l < idfile) > 0) seen[l] = 1 }
        NF == 0 { next }
        { k = $0; if (match($0, /"id":"[^"]*"/)) k = substr($0, RSTART + 6, RLENGTH - 7)
          if (!(k in seen)) print }' "$_if"
    _irc=$?
    rm -f "$_idf"
    return $_irc
}

# A connectivity failure is stale data, not evidence of a conflicting lineage.
# Mixed/ambiguous errors stay in the ordinary failure class.
network_unavailable() {
    printf '%s' "$1" | grep -qiE 'ssh: connect to host|Could not resolve host|Could not resolve hostname|Network is unreachable|No route to host' || return 1
    ! printf '%s' "$1" | grep -qiE 'conflict|non-fast-forward|corrupt|TIMED OUT|permission denied|authentication failed'
}

record_sync_failure_kind() {
    network_unavailable "$1" || sync_nonnetwork_failure=1
}

# Only the normal sync owner calls this. Use the LONGER remote budget: a
# 300s bd timeout must never cut short a valid 900s direct upload.
inspect_server_remote_children() {
    _remote_helper="$BEADS_REPO/scripts/bd-dolt-remote-children"
    _remote_note="server-side remote status: unknown; inspector unavailable"
    if [ -f "$_remote_helper" ] && command -v python3 >/dev/null 2>&1 && [ -n "$BD_TIMEOUT_CMD" ]; then
        _remote_age=$BEADS_DOLT_STEP_TIMEOUT
        [ "$BEADS_DOLT_PUSH_FALLBACK_TIMEOUT" -le "$_remote_age" ] || _remote_age=$BEADS_DOLT_PUSH_FALLBACK_TIMEOUT
        _remote_age=$((_remote_age + BEADS_DOLT_STEP_KILL_GRACE))
        _remote_note=$("$BD_TIMEOUT_CMD" -k 2 20 python3 "$_remote_helper" "$BEADS_REPO" --minimum-age "$_remote_age" --apply 2>/dev/null)
        _remote_rc=$?
        [ "$_remote_rc" -eq 0 ] || _remote_note="$_remote_note
server-side remote status: inspection incomplete (rc=$_remote_rc); remote idleness is unconfirmed"
    fi
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_remote_note" >>"$SYNCLOG"
}

# --- Dolt's history on the git remote ---------------------------------------
# Every publish to a git remote adds commits to refs/dolt/data. By default Dolt
# starts over with a parentless commit once that chain is 64 commits long, or as
# soon as a publish drops a table file, which every conjoin does. Git only leaves
# out what a parent edge tells it the remote already has, so a parentless commit
# sends the whole store. Measured 2026-11-04: one changed table file of 10.8 MiB
# was a 2.68 GB upload, which GitHub refuses over 2 GiB and which outlasts the
# 900s push bound either way. At two commits a publish that is about every 32nd
# publish across every machine, and it partitions whichever machine draws it.
#
# These settings turn both off. They go in the database's own .dolt/config.json,
# so they apply to this tracker and no other. The price is that the remote keeps
# its history: SETUP.md "Dolt's history on the git remote".
GIT_REMOTE_HISTORY_SETTINGS='git-remote.max-history-commits=0 git-remote.reset-history-on-prune=false'

# Can this dolt keep history at all? Takes the output of `dolt version`. The
# settings arrived in 2.5.0, and an older dolt stops at 64 whatever it is told.
#   0 = yes, 1 = too old, 2 = could not read the version
dolt_has_history_settings() {
    _dv=$(printf '%s\n' "$1" | sed -n 's/^dolt version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -1)
    [ -n "$_dv" ] || return 2
    _dv_major=${_dv% *}
    _dv_minor=${_dv#* }
    [ "$_dv_major" -gt 2 ] && return 0
    [ "$_dv_major" -eq 2 ] && [ "$_dv_minor" -ge 5 ] && return 0
    return 1
}

# One word for the database directory $1, given bd's server pid file $2:
#   ok            the settings are in place and any running server has read them
#   unset         a setting is missing or holds another value
#   stale-server  the settings are in place, but the running server started
#                 before they were written. A server reads them when it first
#                 opens the remote and keeps them until it stops (measured: a
#                 changed value did nothing until a restart), so it still cuts
#                 history. Both the launchd wrapper and bd rewrite the pid file
#                 when they start a server, which is what makes the file's age
#                 the server's age.
#   old-dolt      this dolt cannot keep history
git_remote_history_verdict() {
    _hdir=$1 _hpid=$2
    dolt_has_history_settings "$(cd "$_hdir" && dolt version 2>/dev/null)"
    [ $? -ne 1 ] || { echo old-dolt; return 0; }
    for _hset in $GIT_REMOTE_HISTORY_SETTINGS; do
        _hgot=$(cd "$_hdir" && dolt config --local --get "${_hset%%=*}" 2>/dev/null)
        [ "$_hgot" = "${_hset#*=}" ] || { echo unset; return 0; }
    done
    _hsrv=$(tr -d '[:space:]' <"$_hpid" 2>/dev/null)
    if [ -n "$_hsrv" ] && kill -0 "$_hsrv" 2>/dev/null && [ "$_hdir/.dolt/config.json" -nt "$_hpid" ]; then
        echo stale-server
    else
        echo ok
    fi
}

# Sourced with BEADS_SYNC_LIB=1, the script stops here: every rule above is
# defined and nothing below runs, so scripts/test-beads-sync can pin them
# offline without syncing anything, and scripts/bd-health can ask
# blocking_commits the same question the convergence below asks.
if [ "${BEADS_SYNC_LIB:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi

if [ -d "$LOCK" ]; then
    lock_is_reclaimable "$LOCK"
    case $? in
        0)  rm -f "$LOCK/pid" 2>/dev/null
            rmdir "$LOCK" 2>/dev/null ;;
        2)  # A lock written by a hook from before this one recorded its
            # owner. Fall back to the old age rule for it, so upgrading does
            # not reclaim a live run's lock on the session that straddles
            # the change.
            find "$LOCK" -maxdepth 0 -type d -mmin +10 -exec rmdir {} \; 2>/dev/null ;;
    esac
fi

# Another sync is already in flight - it will carry our changes too. A
# quick-mode caller is an agent waiting on the answer, so say that instead
# of silently returning.
if ! mkdir "$LOCK" 2>/dev/null; then
    [ "$MODE" = quick ] && echo "beads claim-sync: another sync is in flight - it carries this change; re-run bd find-duplicates when it finishes"
    exit 0
fi
echo $$ >"$LOCK/pid" 2>/dev/null
trap 'rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT

cd "$BEADS_REPO" || exit 0

sync_failed=0
sync_nonnetwork_failure=0

# Every dolt step is bounded. These commands talk to a git remote while
# holding the embedded Dolt lock, so one that never returns is not a slow
# sync - it is a partition: bd blocks for every other session on the machine
# until someone finds the process and kills it by hand. A `bd dolt pull` that
# hung on 2026-08-30 held that lock for over three hours. Bounding the step
# turns "everything is wedged forever" into one logged failure that the next
# session retries, which is the whole point of the fail-soft design.
: "${BEADS_DOLT_STEP_TIMEOUT:=300}"

# bd's pre-push fsck budget. bd 1.1.0 hardcodes 30s and ignores this; bd
# 1.3.0 reads it (upstream #4822), and a full fsck of this store takes ~37s,
# so once every machine is on 1.3.0 this is what lets `bd dolt push` complete
# clean again and retire the direct-push fallback below. Set
# ahead of the upgrade on purpose: harmless before, effective after.
: "${BEADS_FSCK_TIMEOUT:=300}"
export BEADS_FSCK_TIMEOUT

# How long SIGTERM gets before the step is SIGKILLed.
#
# `timeout N` on its own sends only SIGTERM, and a wedged `bd dolt pull` does
# not act on it - so the bound above was unenforceable against the exact
# failure it was written for. Measured 2026-08-30 on the wedged pull itself:
# SIGTERM, then still alive at 5/10/15/20/25/30s; SIGKILL ended it instantly.
# bd installs a SIGTERM handler to flush pending batch commits (`bd dolt pull
# --help`, --dolt-auto-commit: "SIGTERM/SIGHUP flush pending batch commits"),
# and that handler cannot run while the process is stuck in the chunk-fetch
# retry loop, so the signal is accepted and never acted on.
#
# The consequence was worse than a missed bound, because it was silent in the
# wrong direction: timeout(1) gave up at 300s, returned 124, and the log said
# "TIMED OUT ... and was killed while holding the Dolt lock" - true about the
# timeout, false about the kill. The pull kept the lock, so nobody went
# looking for a survivor. One such process held it 42 minutes with 13 bd
# processes from other sessions stacked behind it, the oldest waiting 1h33m.
#
# SIGKILL cannot be trapped, so the lock is always released. The grace period
# is the handler's real chance to flush first.
: "${BEADS_DOLT_STEP_KILL_GRACE:=20}"

# The direct `dolt push` fallback below uploads the whole delta itself and is
# not subject to the per-step bound above - it is the slow path by nature (3m17s
# for a 982 MB store on the machine this was written for). Give it its own,
# much larger bound so a genuinely slow publish is not cut off, while a wedged
# one still cannot run forever.
: "${BEADS_DOLT_PUSH_FALLBACK_TIMEOUT:=900}"
# Direct Git children inherit this; server-side Git needs the same options
# in the launchd environment (scripts/bd-dolt-server), effective on restart.
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=3}"
export GIT_SSH_COMMAND
if command -v timeout >/dev/null 2>&1; then
    BD_TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    BD_TIMEOUT_CMD=gtimeout
else
    BD_TIMEOUT_CMD=""
fi

# Kill every abandoned holder of the Dolt lock. The decision for one pid is
# lock_holder_is_abandoned above; this is only the plumbing that finds them.
#
# The database directory is named after the tracker (acme, ...), so
# glob it rather than naming one workspace - this script is shared, and a
# hardcoded name would silently no-op everywhere else. Both engine layouts are
# globbed: the original glob covered only embeddeddolt/, so the reaper had
# been a silent no-op on every server-mode machine since the server
# migration moved the data to .beads/dolt/.
# No lsof means no way to ask who holds the lock, which is a reason to do
# nothing, never a reason to guess and kill.
#
# In server mode the registered dolt sql-server holds the noms LOCK for as
# long as it runs, and it is parented to launchd/init BY DESIGN - so for that
# one process, PPID 1 is normal operation, not abandonment, and reaping it
# would kill the live server on every sync. It is excluded twice over: by the
# pid bd records in .beads/dolt-server.pid, and by its command line, so a
# server whose pid file is stale is still never shot.
reap_abandoned_lock_holders() {
    command -v lsof >/dev/null 2>&1 || return 0
    _server_pid=$(tr -d '[:space:]' <"$BEADS_REPO/.beads/dolt-server.pid" 2>/dev/null)
    for _lockfile in "$BEADS_REPO"/.beads/dolt/*/.dolt/noms/LOCK \
                     "$BEADS_REPO"/.beads/embeddeddolt/*/.dolt/noms/LOCK; do
        [ -f "$_lockfile" ] || continue
        for _pid in $(lsof -t "$_lockfile" 2>/dev/null); do
            [ -n "$_server_pid" ] && [ "$_pid" = "$_server_pid" ] && continue
            _cmd=$(ps -o command= -p "$_pid" 2>/dev/null | cut -c1-120)
            case "$_cmd" in *"dolt sql-server"*) continue ;; esac
            lock_holder_is_abandoned "$_pid" || continue
            kill -9 "$_pid" 2>/dev/null || continue
            printf '[%s] reaped abandoned Dolt lock holder pid=%s (%s) in %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$_pid" "$_cmd" "$BEADS_REPO" >>"$SYNCLOG"
            echo "NOTE: beads sync reaped an abandoned Dolt lock holder (pid $_pid) that was blocking every bd on this machine"
        done
    done
}

# Run one bounded dolt command and leave its verdict to the caller: sets
# `out` (spinner-stripped) and `rc`. dolt_step is this plus the judgement and
# the logging; attempt_push uses this directly because a push refused on bd's
# fsck false positive is not a failure to log, it is the cue to push directly.
run_dolt_step() {
    inspect_server_remote_children
    if [ -n "$BD_TIMEOUT_CMD" ]; then
        reap_abandoned_lock_holders
        out=$("$BD_TIMEOUT_CMD" -k "$BEADS_DOLT_STEP_KILL_GRACE" "$BEADS_DOLT_STEP_TIMEOUT" "$@" 2>&1)
        rc=$?
        out=$(strip_dolt_noise "$out")
        # timeout(1) reports 124 when SIGTERM expired the step; the shell
        # reports 137 (128+9) when -k had to follow up with SIGKILL. 137 is
        # the normal path for a wedged dolt step, not an anomaly - say which
        # one happened, because "ignored SIGTERM" is the symptom that tells a
        # reader the process was stuck rather than merely slow.
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
            if [ "$rc" -eq 137 ]; then
                _killnote="ignored SIGTERM and was SIGKILLed after ${BEADS_DOLT_STEP_KILL_GRACE}s"
            else
                _killnote="exited on SIGTERM"
            fi
            out="${out}
TIMED OUT after ${BEADS_DOLT_STEP_TIMEOUT}s; the step ${_killnote}; this only bounds the client. Server-side remote work may survive; see the ownership-checked inspection below."
            inspect_server_remote_children
            out="$out
$_remote_note"
        fi
        # Belt and braces: the step is over, so nothing of ours may still hold
        # the lock. Anything that does is abandoned by definition.
        reap_abandoned_lock_holders
    else
        # No timeout(1) on this machine (no coreutils). Run unbounded rather
        # than not syncing at all, and say so, because this is the one path
        # that can still wedge the machine.
        echo "WARNING: beads sync has no timeout(1); dolt steps run unbounded (install coreutils)" >>"$SYNCLOG"
        out=$("$@" 2>&1)
        rc=$?
        out=$(strip_dolt_noise "$out")
    fi
}

# Log a failed step's full output and warn on stdout instead of swallowing
# it; marks the run failed.
log_step_failure() {
    printf '[%s] %s FAILED (rc=%s) in %s:\n%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$rc" "$BEADS_REPO" "$out" >>"$SYNCLOG"
    echo "WARNING: beads $1 failed - tracker may not be syncing (see $SYNCLOG)"
    sync_failed=1
    record_sync_failure_kind "$out"
}

# Run a dolt sync step; on nonzero exit or error-looking output, log the
# full output and warn on stdout instead of swallowing it.
dolt_step() {
    step="$1"; shift
    run_dolt_step "$@"
    if step_output_is_failure "$rc" "$out"; then
        log_step_failure "$step"
        return 1
    fi
    return 0
}

# Resolve a conflicted merge mechanically (the policy: ours as the
# base, THEIR closes re-applied, OUR closes never reopened, counters take
# MAX). Before this existed, a row conflict parked the machine on "operator
# resolution" until a human merged by hand - resolved three times on
# 2026-08-30 alone, and the partition it causes is how two machines each
# fixed the same incident without seeing each other's bead (2026-08-22).
# Schema conflicts and tables the policy does not cover still stop the sync
# for an operator - the resolver refuses them (exit 4) without touching
# anything.
#   0 = merge concluded (possibly with closes journaled for retry - the
#       tracker is consistent and the sync may continue)
#   1 = not resolved; the operator hint has been printed
auto_resolve_conflicts() {
    if [ ! -x "$BEADS_REPO/scripts/bd-resolve-conflicts" ]; then
        echo "HINT: Dolt merge conflict needs an operator merge - follow SETUP.md 'Dolt pull conflict: operator merge'. Until healed, a GitHub open-PR search is the only duplicate check that works."
        return 1
    fi
    if [ -n "$BD_TIMEOUT_CMD" ]; then
        resolve_out=$(BEADS_DIR="$BEADS_REPO/.beads" "$BD_TIMEOUT_CMD" -k "$BEADS_DOLT_STEP_KILL_GRACE" \
            "$BEADS_DOLT_STEP_TIMEOUT" "$BEADS_REPO/scripts/bd-resolve-conflicts" --apply --quiet 2>&1)
    else
        resolve_out=$(BEADS_DIR="$BEADS_REPO/.beads" "$BEADS_REPO/scripts/bd-resolve-conflicts" --apply --quiet 2>&1)
    fi
    resolve_rc=$?
    printf '[%s] auto-resolve (rc=%s) in %s:\n%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$resolve_rc" "$BEADS_REPO" "$resolve_out" >>"$SYNCLOG"
    [ -n "$resolve_out" ] && echo "$resolve_out"
    case "$resolve_rc" in
        0) return 0 ;;
        3) # Merge concluded; some re-applied closes are journaled and retry
           # on the next sync. The store is consistent, so the sync goes on.
           echo "WARNING: auto-resolve concluded the merge but some closes are still journaled - they retry next sync (see $SYNCLOG)"
           return 0 ;;
        4) echo "HINT: Dolt merge conflict needs an operator merge - follow SETUP.md 'Dolt pull conflict: operator merge'. Until healed, a GitHub open-PR search is the only duplicate check that works."
           return 1 ;;
        6) # bd said "conflict" but left a clean working set: in embedded,
           # non-interactive mode bd ABORTS a conflicted merge and restores the
           # working set, so there was nothing to resolve and the lineages are
           # still divergent. Restoring the success flag here logged `sync OK`
           # over a live partition (false-green, review 2026-09-01).
           echo "WARNING: beads pull reported a conflict but the merge was aborted, nothing was resolved and the lineages remain divergent - see SETUP.md 'Dolt pull conflict: operator merge' (see $SYNCLOG)"
           return 1 ;;
        *) echo "WARNING: beads auto-resolve failed (rc=$resolve_rc) - tracker may not be syncing (see $SYNCLOG)"
           return 1 ;;
    esac
}

# An export stages .beads/.~issues.jsonl.<rand> and renames it into place; an
# interrupted export leaves the temp behind forever, and they accumulate as
# untracked litter in git status. A day old means no live export can still be
# holding it.
find "$BEADS_REPO/.beads" -maxdepth 1 -name '.~issues.jsonl.*' -mmin +1440 -exec rm -f {} + 2>/dev/null

# Put the history settings in place before anything can publish. Nothing here
# fails the sync: without them a publish is slow, not wrong.
#
# A server that has not read them is restarted, once, because leaving it means
# its next parentless publish costs far more than the restart does (measured:
# 13s until bd answers again, against a 15-minute upload that then fails). This
# run holds the sync lock, so no other sync is mid-push on this machine, and the
# restart still only happens when the inspector confirms there is no remote work
# on the server. Otherwise the next sync tries again.
history_note() {
    printf '[%s] git remote history: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$SYNCLOG"
}
ensure_git_remote_history() {
    command -v dolt >/dev/null 2>&1 || return 0
    for _hdb in "$BEADS_REPO"/.beads/dolt/*/ "$BEADS_REPO"/.beads/embeddeddolt/*/; do
        [ -d "$_hdb/.dolt" ] || continue
        _hpidf="$BEADS_REPO/.beads/dolt-server.pid"
        _hv=$(git_remote_history_verdict "$_hdb" "$_hpidf")
        if [ "$_hv" = unset ]; then
            for _hs in $GIT_REMOTE_HISTORY_SETTINGS; do
                (cd "$_hdb" && dolt config --local --add "${_hs%%=*}" "${_hs#*=}") >/dev/null 2>&1 ||
                    history_note "could not set ${_hs%%=*} in $_hdb"
            done
            _hv=$(git_remote_history_verdict "$_hdb" "$_hpidf")
            history_note "settings written to $_hdb, now $_hv"
        fi
        case "$_hv" in
            old-dolt)
                history_note "$(cd "$_hdb" && dolt version 2>/dev/null | head -1) cannot keep history; about every 32nd publish re-uploads the whole tracker until it is 2.5.0 or later"
                echo "WARNING: this dolt is older than 2.5.0, so tracker publishes keep re-uploading the whole store. Upgrade it (brew upgrade dolt); see SETUP.md \"Dolt's history on the git remote\"."
                ;;
            stale-server)
                inspect_server_remote_children
                case "$_remote_note" in
                    *'pushes=0 live_remote_client=no'*) ;;
                    # Said on stdout too: a deferral repeats every sync until
                    # something changes, and in the log alone it repeated for
                    # 15 hours on a machine that could not publish.
                    *)  history_note "the running server has not read the settings and remote work may be running, so this is left to the next sync"
                        echo "WARNING: the tracker server has not read the git remote history settings, so publishes can re-upload the whole store. The hook could not confirm that no remote work is running, so it did not restart it ($(printf '%s' "$_remote_note" | tail -1 | sed 's/^server-side remote status: //')). When no push is running, run $BEADS_REPO/scripts/bd-dolt-server restart; see $SYNCLOG."
                        continue ;;
                esac
                if [ ! -x "$BEADS_REPO/scripts/bd-dolt-server" ]; then
                    history_note "the running server has not read the settings and there is no scripts/bd-dolt-server to restart it"
                    continue
                fi
                if [ -n "$BD_TIMEOUT_CMD" ]; then
                    _hout=$("$BD_TIMEOUT_CMD" -k 5 90 "$BEADS_REPO/scripts/bd-dolt-server" restart 2>&1)
                else
                    _hout=$("$BEADS_REPO/scripts/bd-dolt-server" restart 2>&1)
                fi
                _hrc=$?
                history_note "restarted the server so it reads the settings (rc=$_hrc): $_hout"
                [ "$_hrc" -eq 0 ] || echo "WARNING: the tracker server could not be restarted (rc=$_hrc), see $SYNCLOG"
                ;;
        esac
    done
}
ensure_git_remote_history

# The Dolt database is the source of truth; this is the real sync.
dolt_step "dolt commit" bd dolt commit

# A pull that fails on merge conflicts is resolved mechanically where the
# policy covers it (see auto_resolve_conflicts). On success the pull did its
# job - the other lineage's commits are merged in - so the step is not
# re-counted as a failure.
pull_prev_failed=$sync_failed
pull_prev_nonnetwork=$sync_nonnetwork_failure
if ! dolt_step "dolt pull" bd dolt pull; then
    if printf '%s' "$out" | grep -qiE 'conflict'; then
        if auto_resolve_conflicts; then
            sync_failed=$pull_prev_failed
            sync_nonnetwork_failure=$pull_prev_nonnetwork
        fi
    fi
fi

# A pull can only bring in what the other lineage actually pushed to
# refs/dolt/data. Issues it never pushed reach this machine only as jsonl,
# through the git convergence at the bottom of this script - and
# bd-export-jsonl then refuses to overwrite them (correctly: they are the only
# local copy). That refusal freezes the export, so the committed jsonl and the
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
        sync_nonnetwork_failure=1
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

# One push attempt: `bd dolt push`, with the fsck-false-positive fallback.
#
# The fallback is for a known bd defect, not corruption: bd's pre-push
# integrity check runs `dolt fsck` under a HARDCODED 30s timeout, and when
# the timeout kills it the empty output is wrapped as a dangling-chunk error.
# Any database big enough to take longer than 30s to scan therefore becomes
# permanently unpushable through bd, while `dolt push` from the data
# directory works perfectly (upstream gastownhall/beads #4822, corroborated
# by #4258 and #5865). The tell is the EMPTY chunk reference after the final
# colon: a real finding prints chunk hashes there. This machine hit it at
# ~982 MB and roughly 35s to fail - and it is what was actually behind the
# "155 non-fast-forward rejections" partition, because a push that never
# succeeds leaves the local branch permanently ahead. Every pull afterwards
# then looks like the problem. (maybe_gc below was meant as the other half
# of that fix; upstream has since measured that fsck time tracks the commit
# count, not the size, so gc does not end it - see fsck_probe_due.)
#
# Narrowly scoped on purpose - any other push failure is left alone, and a
# dangling-chunk error that NAMES chunks is real corruption that must still
# stop the sync.
#
# A rescued false positive is logged as ONE line and nothing on stdout
# beyond a note, not as a `dolt push FAILED` block followed by a retraction:
# 261 such blocks in one log window, each with a WARNING that the tracker
# "may not be syncing" printed into a session whose tracker was syncing
# fine, is how a log stops being read - and how bd-health's "runs without
# sync OK" finding, which counts something else entirely, lost its audience.
#
# While the false positive is known (fsck_probe_due), the probe is skipped
# and the direct push goes first; see that function for why. FSCK_FP_MARKER
# is touched on every rescue and removed by a `bd dolt push` that completes
# clean, so bd's own check reinstates itself the moment it works again.
#
# Sets push_rejected_nonff=1 when the refusal (from either path) was a
# non-fast-forward - the one push failure that is not a fault but a race,
# and the caller's cue to pull and try once more.
#   0 = published, 1 = not published
: "${BEADS_FSCK_REPROBE_HOURS:=24}"
FSCK_FP_MARKER="$HOME/.claude/logs/beads-fsck-false-positive-$WS_NAME.last"
attempt_push() {
    push_rejected_nonff=0
    out=""; fb_out=""; fb_dir=""; _probed=0
    if fsck_probe_due "$FSCK_FP_MARKER" "$BEADS_FSCK_REPROBE_HOURS"; then
        _probed=1
        run_dolt_step bd dolt push
        if ! step_output_is_failure "$rc" "$out"; then
            # bd's guard completed within its budget and passed. It is
            # trustworthy again, so put it back in front of every push.
            if [ -f "$FSCK_FP_MARKER" ]; then
                rm -f "$FSCK_FP_MARKER"
                printf '[%s] dolt push: bd pre-push fsck completed clean again; bd dolt push is back in front of every push in %s\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "$BEADS_REPO" >>"$SYNCLOG"
            fi
            return 0
        fi
        if ! push_fsck_false_positive "$out"; then
            log_step_failure "dolt push"
            push_is_rejected_nonff "$out" && push_rejected_nonff=1
            return 1
        fi
        _why="bd pre-push fsck false positive, no chunk named (upstream #4822)"
    else
        _why="bd pre-push fsck known false positive since $(date -r "$FSCK_FP_MARKER" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'), probe skipped (re-probed every ${BEADS_FSCK_REPROBE_HOURS}h)"
    fi
    if direct_dolt_push; then
        # The marker's mtime is the last PROBE that confirmed the false
        # positive, so it is touched only on the probe path. Touching it on
        # every rescue would reset the re-probe clock on every sync and the
        # probe would never run again - the skip would be permanent.
        [ "$_probed" -eq 1 ] && touch "$FSCK_FP_MARKER" 2>/dev/null
        printf '[%s] dolt push: %s; published via direct `dolt push` in %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$_why" "$fb_dir" >>"$SYNCLOG"
        [ "$_probed" -eq 1 ] && echo "NOTE: bd dolt push reported a dangling chunk reference with no chunk named - a known bd pre-push fsck timeout, not corruption. Pushed directly with dolt instead; the tracker is published."
        return 0
    fi
    # Not published. The probe's own output (if there was one) is context
    # for the direct push's failure, so it is logged with it.
    [ -n "$out" ] && printf '[%s] dolt push FAILED (rc=%s) in %s:\n%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" "$BEADS_REPO" "$out" >>"$SYNCLOG"
    printf '[%s] dolt push fallback FAILED (rc=%s) in %s:\n%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${fb_rc:-?}" "${fb_dir:-$BEADS_REPO}" "$fb_out" >>"$SYNCLOG"
    echo "WARNING: the direct dolt push failed - this machine is not publishing (see $SYNCLOG)"
    sync_failed=1
    record_sync_failure_kind "$fb_out"
    if push_is_rejected_nonff "$out" || push_is_rejected_nonff "$fb_out"; then
        push_rejected_nonff=1
    fi
    return 1
}

# The direct `dolt push origin main` from the data directory - the publish
# that works when bd's pre-push fsck cannot finish. Sets fb_out, fb_rc and
# fb_dir. Every way of not pushing leaves a reason in fb_out, including "no
# data directory found": the loop used to `continue` past a glob that
# matched nothing and return with an empty fb_out, which is exactly how the
# relative-path runs failed without a trace (see abs_repo_path).
#   0 = published ("Everything up-to-date" counts), 1 = not published
direct_dolt_push() {
    inspect_server_remote_children
    fb_out=""; fb_rc=1; fb_dir=""
    if ! command -v dolt >/dev/null 2>&1; then
        fb_out="dolt is not installed; the direct push needs the dolt CLI"
        return 1
    fi
    for _dbdir in "$BEADS_REPO"/.beads/dolt/*/ "$BEADS_REPO"/.beads/embeddeddolt/*/; do
        [ -d "$_dbdir/.dolt" ] || continue
        fb_dir="$_dbdir"
        if [ -n "$BD_TIMEOUT_CMD" ]; then
            fb_out=$(cd "$_dbdir" && "$BD_TIMEOUT_CMD" -k "$BEADS_DOLT_STEP_KILL_GRACE" \
                "$BEADS_DOLT_PUSH_FALLBACK_TIMEOUT" dolt push origin main 2>&1)
        else
            fb_out=$(cd "$_dbdir" && dolt push origin main 2>&1)
        fi
        fb_rc=$?
        fb_out=$(strip_dolt_noise "$fb_out")
        if [ "$fb_rc" -eq 124 ] || [ "$fb_rc" -eq 137 ]; then
            inspect_server_remote_children
            fb_out="$fb_out
TIMED OUT after ${BEADS_DOLT_PUSH_FALLBACK_TIMEOUT}s; client termination does not prove remote idleness.
$_remote_note"
        fi
        [ "$fb_rc" -eq 0 ] && return 0
        return 1
    done
    fb_out="no Dolt data directory under $BEADS_REPO/.beads (looked in dolt/*/ and embeddeddolt/*/)"
    return 1
}

# Remember what the sync looked like BEFORE the push, so a recovered push
# restores that state rather than declaring the whole run clean - an earlier
# failed pull is still a failed pull.
push_prev_failed=$sync_failed
push_prev_nonnetwork=$sync_nonnetwork_failure
if ! attempt_push && [ "$push_rejected_nonff" -eq 1 ]; then
    # Another machine published between our pull and our push. That was the
    # single largest failure class in the log (80 rejections in one trimmed
    # window, three machines racing at session boundaries), and each one
    # used to fail the whole sync and park the delta until the NEXT session.
    # It is a race, not a fault: pull the newer lineage (resolving row
    # conflicts if the merge has any) and push once more. Once only - a
    # second rejection means we keep losing the race, and the next session
    # is the retry.
    echo "NOTE: dolt push was rejected non-fast-forward - another machine published first; pulling and retrying the push once"
    retry_ok=1
    if ! dolt_step "dolt pull (push retry)" bd dolt pull; then
        if printf '%s' "$out" | grep -qiE 'conflict'; then
            auto_resolve_conflicts || retry_ok=0
        else
            retry_ok=0
        fi
    fi
    if [ "$retry_ok" -eq 1 ] && attempt_push; then
        sync_failed=$push_prev_failed
        sync_nonnetwork_failure=$push_prev_nonnetwork
    fi
fi

# Maintain the stale-tracker marker (see its comment at the top). Created
# only if absent so the mtime stays the partition's start, not its latest
# retry; removed on the first clean sync.
if [ "$sync_failed" -eq 0 ]; then
    rm -f "$STALE_MARKER" "$OFFLINE_MARKER"
elif [ "$sync_nonnetwork_failure" -eq 0 ]; then
    # Never erase an older unresolved partition just because today's failure
    # is offline. A successful sync is the only evidence that clears either.
    if [ ! -f "$OFFLINE_MARKER" ]; then
        printf 'offline since %s - tracker data remains stale; see %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SYNCLOG" >"$OFFLINE_MARKER"
    fi
    echo "WARNING: beads sync is offline; duplicate checks remain stale until a clean sync"
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
elif [ "$sync_nonnetwork_failure" -eq 0 ]; then
    printf '[%s] sync OFFLINE (%s) in %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$BEADS_REPO" >>"$SYNCLOG"
else
    # One run-level line per FAILED run too. The per-step FAILED lines above
    # include retries that the same run then recovered from (a non-ff push
    # that pulled and pushed clean, an fsck false positive the fallback
    # absorbed), so counting them read a healthy tracker as broken: bd-health
    # reported 79 "failures" over two days in which 158 runs ended OK and
    # about 13 did not. bd-health now counts these lines, one per run.
    printf '[%s] sync FAILED (%s) in %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$BEADS_REPO" >>"$SYNCLOG"
fi
if [ "$(wc -l <"$SYNCLOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -1000 "$SYNCLOG" >"$SYNCLOG.tmp" 2>/dev/null && mv "$SYNCLOG.tmp" "$SYNCLOG"
fi

# Quick mode ends here: the jsonl export and its git convergence are
# session-boundary work, and the claim it exists to publish is already on
# the Dolt remote (or the marker above says why not).
[ "$MODE" = quick ] && exit 0

# Garbage-collect the store when it outgrows the threshold, at most once per
# BEADS_DOLT_GC_MIN_DAYS. This is not housekeeping for its own sake: bd's
# pre-push fsck has a hardcoded 30s budget, and the moment the store outgrows
# what fsck can scan in 30s (~1 GB here), EVERY push takes the
# dangling-chunk false-positive path above - the fallback saves the sync,
# but the root cause is a store that is mostly merge garbage (this
# workspace: 3,978 issues, 19,120 commits, 1.2 GB, most of it unreferenced).
# `call dolt_gc()` routes to the running sql-server in server mode (which
# drops client connections when it finishes - harmless here, the sync's dolt
# work is done) and runs directly in embedded mode. Runs after the push so a
# slow gc can never delay publishing a claim, and bounded like every other
# dolt step because an unbounded stall while holding the lock is a
# partition, not a slow gc.
: "${BEADS_DOLT_GC_THRESHOLD_MB:=512}"
: "${BEADS_DOLT_GC_MIN_DAYS:=7}"
: "${BEADS_DOLT_GC_TIMEOUT:=900}"
maybe_gc() {
    command -v dolt >/dev/null 2>&1 || return 0
    _marker="$HOME/.claude/logs/beads-gc-$WS_NAME.last"
    [ -f "$_marker" ] && [ -n "$(find "$_marker" -mtime -"$BEADS_DOLT_GC_MIN_DAYS" 2>/dev/null)" ] && return 0
    for _dbdir in "$BEADS_REPO"/.beads/dolt/*/ "$BEADS_REPO"/.beads/embeddeddolt/*/; do
        [ -d "$_dbdir/.dolt" ] || continue
        _size_mb=$(du -sm "$_dbdir" 2>/dev/null | awk '{print $1}')
        [ "${_size_mb:-0}" -gt "$BEADS_DOLT_GC_THRESHOLD_MB" ] || continue
        if [ -n "$BD_TIMEOUT_CMD" ]; then
            _gc_out=$(cd "$_dbdir" && "$BD_TIMEOUT_CMD" -k "$BEADS_DOLT_STEP_KILL_GRACE" \
                "$BEADS_DOLT_GC_TIMEOUT" dolt sql -q "call dolt_gc()" 2>&1)
        else
            _gc_out=$(cd "$_dbdir" && dolt sql -q "call dolt_gc()" 2>&1)
        fi
        _gc_rc=$?
        _size_after=$(du -sm "$_dbdir" 2>/dev/null | awk '{print $1}')
        # dolt_gc ends by dropping the session it ran on, so in server mode
        # the CLI can report a connection error for a gc that succeeded -
        # the size answer is the truthful one. Only an unshrunk store with a
        # nonzero exit counts as a failure.
        if [ "$_gc_rc" -eq 0 ] || [ "${_size_after:-$_size_mb}" -lt "$_size_mb" ]; then
            printf '[%s] dolt gc: %sMB -> %sMB (rc=%s) in %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$_size_mb" "${_size_after:-?}" "$_gc_rc" "$_dbdir" >>"$SYNCLOG"
            touch "$_marker" 2>/dev/null
        else
            printf '[%s] dolt gc FAILED (rc=%s, still %sMB) in %s:\n%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$_gc_rc" "${_size_after:-?}" "$_dbdir" "$_gc_out" >>"$SYNCLOG"
            echo "WARNING: dolt gc failed - the store stays at ${_size_mb}MB and pushes keep taking the fsck-fallback path (see $SYNCLOG)"
        fi
        break
    done
}
maybe_gc

# Keep the passive jsonl export committed so the repo stays clean and the
# GitHub view of issues stays fresh. The export is regenerated from the DB,
# so on git divergence we converge to origin/main rather than fight it.
# Remove everything below to opt out of auto git commits.
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] || exit 0

# This is the one place a machine rewrites the file: bd's per-write export is off
# (.beads/config.yaml), because it cost every write a full scan of
# the tracker. Here it runs once, inside the sync lock, after the pull and the
# reconcile, so it cannot race itself and sees what this run brought in. Bounded
# like every other step that reads the database. A failure costs one stale export,
# so it is logged and the git convergence below still runs.
if [ -x "$BEADS_REPO/scripts/bd-export-jsonl" ]; then
    if [ -n "$BD_TIMEOUT_CMD" ]; then
        export_out=$(BEADS_DIR="$BEADS_REPO/.beads" "$BD_TIMEOUT_CMD" -k "$BEADS_DOLT_STEP_KILL_GRACE" \
            "$BEADS_DOLT_STEP_TIMEOUT" "$BEADS_REPO/scripts/bd-export-jsonl" 2>&1)
    else
        export_out=$(BEADS_DIR="$BEADS_REPO/.beads" "$BEADS_REPO/scripts/bd-export-jsonl" 2>&1)
    fi
    export_rc=$?
    if [ "$export_rc" -ne 0 ]; then
        printf '[%s] jsonl export (rc=%s) in %s:\n%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$export_rc" "$BEADS_REPO" "$export_out" >>"$SYNCLOG"
        echo "WARNING: beads jsonl export did not run, the committed export stays as it was (see $SYNCLOG)"
    fi
fi

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
if ! git fetch -q origin main >/dev/null 2>&1; then
    # Offline, or GitHub is down. origin/main is stale, so every judgement
    # below would be made against the wrong base, and the `reset --hard` at
    # the end would discard the export commit made a moment ago. Keep it;
    # the next run pushes it.
    printf '[%s] push rejected and git fetch failed (offline?) in %s; export kept locally, not resetting.\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$BEADS_REPO" >>"$SYNCLOG"
    exit 0
fi
# `chore: setup heartbeat` is ours too (bd-setup-sync publishes one file per
# machine under .beads-setup/heartbeats/). Leaving it out of EXPORT_SUBJECTS_RE
# would make every heartbeat look like hand-written work on main, so the reset
# below would refuse to run and the machine would warn about "unpushed
# hand-written commits" on every session until someone investigated.
#
# What still blocks is named, in the log AND on stdout, with the runbook. The
# old line said only "N non-export commit(s) ... not resetting" and "resolve by
# hand": nothing said which commits, what the fix was, or that the checkout
# had stopped converging, so it was logged 73 times over 25 days and nobody
# acted. A commit whose change is already on origin - typically
# because it was since landed through a PR - no longer blocks at all
# (commit_is_upstream), and one an operator has checked by hand can be named
# in BEADS_SYNC_DROP_COMMITS.
blocking=$(blocking_commits origin/main)
if [ -n "$blocking" ] && [ -n "${BEADS_SYNC_DROP_COMMITS:-}" ]; then
    blocking=$(printf '%s\n' "$blocking" | unacknowledged_commits "$BEADS_SYNC_DROP_COMMITS")
fi
if [ -n "$blocking" ]; then
    n_blocking=$(printf '%s\n' "$blocking" | grep -c .)
    named=$(printf '%s\n' "$blocking" | name_commits)
    printf '[%s] push rejected with %s non-export commit(s) on main in %s; not resetting. Blocking: %s. Land each through a PR (or confirm origin has it), then SETUP.md "Sync hook will not converge: hand-written commits on main".\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$n_blocking" "$BEADS_REPO" "$named" >>"$SYNCLOG"
    echo "WARNING: beads checkout $BEADS_REPO is not converging: main has $n_blocking hand-written commit(s) that are not on origin/main ($named) and has diverged, so this machine keeps running its current tracker scripts and stops publishing its jsonl export until they are landed through a PR or dropped - see SETUP.md \"Sync hook will not converge: hand-written commits on main\" (log: $SYNCLOG)"
    exit 0
fi

# The check above asks whether we would discard someone's COMMITS. It never
# asked whether we would discard their UNCOMMITTED work, and `git reset --hard`
# destroys that just as thoroughly - with no reflog entry and no trace.
#
# This is not hypothetical. `.beads/metadata.json` is TRACKED (only the
# database directories are gitignored) and it carries `dolt_mode`, so the
# machine that migrates to the Dolt sql-server has a modified tracked file
# until everyone else migrates too. `git pull --rebase` refuses to run with
# unstaged changes, which sent the old code straight to `reset --hard` - and
# that would have reverted dolt_mode to "embedded" while the database sat in
# .beads/dolt, pointing bd at a directory that no longer exists. The sync hook
# would have broken the tracker it exists to protect.
#
# So converge only when the working tree holds nothing but our own exports.
# Anything else is someone's work: say so and stop. A paused convergence is
# visible (bd-health reports the fork) and recoverable; a silent `reset --hard`
# over a local edit is neither.
# Heartbeats are excluded alongside the exports: bd-setup-sync owns
# .beads-setup/heartbeats/<machine>.json and commits it on its own cadence,
# and its uncommitted in-between state blocked this convergence 22 times in
# one trimmed log window ("not resetting" on a file no human ever edits).
dirty=$(git diff --name-only -- . \
    ':(exclude).beads/issues.jsonl' ':(exclude).beads/interactions.jsonl' \
    ':(exclude).beads-setup/heartbeats' 2>/dev/null)
if [ -n "$dirty" ]; then
    printf '[%s] push rejected and the working tree has uncommitted changes outside the export (%s) in %s; not resetting.\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "$dirty" | tr '\n' ' ')" "$BEADS_REPO" >>"$SYNCLOG"
    echo "WARNING: beads repo has uncommitted local changes and main has diverged - the jsonl export is NOT converging until you commit or revert them (see $SYNCLOG)"
    exit 0
fi

# The reset that converges main onto origin, carrying this machine's
# interaction records across it (see interactions_local_only: bd appends that
# file directly and nothing regenerates it, unlike issues.jsonl). The
# re-appended records leave the working tree dirty in the export only, so the
# next run commits and pushes them with its export commit.
converge_by_reset() {
    _keep=$(mktemp "${TMPDIR:-/tmp}/beads-int-keep.XXXXXX" 2>/dev/null) || _keep=""
    if [ -n "$_keep" ]; then
        interactions_local_only origin/main >"$_keep" 2>/dev/null || : >"$_keep"
    fi
    git reset -q --hard origin/main >/dev/null 2>&1
    if [ -n "$_keep" ] && [ -s "$_keep" ]; then
        _if=.beads/interactions.jsonl
        [ -s "$_if" ] && [ -n "$(tail -c1 "$_if")" ] && echo >>"$_if"
        cat "$_keep" >>"$_if"
        printf '[%s] git convergence in %s: reset to origin/main and re-appended %s local-only interaction record(s) the reset would have dropped; they publish with the next export commit.\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$BEADS_REPO" "$(grep -c . "$_keep")" >>"$SYNCLOG"
    fi
    [ -n "$_keep" ] && rm -f "$_keep"
}

# Non-export commits still above origin/main at this point are all either
# already upstream or acknowledged by an operator. They are dropped, never
# replayed: a rebase would re-apply an acknowledged commit and push it
# straight to origin/main, which is exactly the unreviewed hand commit this
# is cleaning up. The previous main is kept as a branch, so dropping is
# always recoverable without the reflog. Merges count whatever their subject,
# as in blocking_commits: a rebase would linearise one and replay its side.
dropped=$({
    git log --no-merges --format='%h %s' origin/main..HEAD 2>/dev/null |
        grep -vE "^[0-9a-f]+ ${EXPORT_SUBJECTS_RE#^}"
    git log --merges --format='%h %s' origin/main..HEAD 2>/dev/null
})
if [ -n "$dropped" ]; then
    backup="backup/beads-sync-$(date '+%Y%m%d-%H%M%S')-$(git rev-parse --short HEAD 2>/dev/null)"
    git branch "$backup" HEAD >/dev/null 2>&1 || backup="(branch not created; reflog only)"
    printf '[%s] git convergence in %s: dropping %s non-export commit(s) already on origin/main or listed in BEADS_SYNC_DROP_COMMITS (%s); previous main kept as %s.\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$BEADS_REPO" "$(printf '%s\n' "$dropped" | grep -c .)" \
        "$(printf '%s\n' "$dropped" | name_commits)" "$backup" >>"$SYNCLOG"
    converge_by_reset
elif ! git pull --rebase -q origin main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1
    converge_by_reset
fi
git push -q origin main >/dev/null 2>&1

exit 0
