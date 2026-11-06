# Recovering an oversized Dolt Git upload

GitHub limits an individual receive pack to 2 GiB. Dolt can accumulate more
than that between successful publications, even though each table-file blob
is small enough. Repeating the push, increasing its timeout, and retrying it
as a non-fast-forward race do not solve this failure.

The recovery must preserve the existing Dolt history and let Dolt perform the
final publication. It must never import the passive JSONL export, reset a
database, rewrite a manifest, force-update `refs/dolt/data`, or delete a cache.

An offline experiment with a 1 MiB receive limit reproduced the failure.
Publishing temporary references directly to the intended blobs, each under
that limit, allowed an ordinary push of the exact original commit afterward.
The final commit, tree and history matched, the temporary refs were removed,
and `git fsck` passed. A helper chain of commits did **not** reliably exclude
the uploaded blobs from the final pack; it is not the recovery mechanism.

Production recovery requires all of these boundaries:

- Run under the existing workspace sync lock, with an explicit recovery
  request. Ordinary hooks must not start an unbounded transfer automatically.
- Bind the plan to the failed cache source ref, its commit, the tracker
  remote, and the observed destination tip. Refuse ambiguous or changed input.
- Upload only blobs reachable from that source, in batches bounded by their
  uncompressed size. Refuse individually oversized objects.
- Give every temporary ref a private recovery namespace and record exact
  ref-to-object mappings in an atomic, permission-restricted journal before
  the first write. Never overwrite an unexpected existing ref.
- Resume idempotently after a disconnect. A partial upload does not count as
  a successful sync and must not clear the stale-tracker marker.
- Let the existing Dolt publication path perform its normal conflict checks.
  Remove only this recovery's unchanged refs after publication succeeds.
- Bound commands and total work. Keep errors useful without logging database
  contents, credentials, or credential-bearing remote URLs.

The synthetic proof is evidence for the transport technique, not a completed
live recovery. The tracker incident remains open until normal publication and
subsequent synchronization succeed.

## Operator sequence

`scripts/bd-recover-git-upload` requires Python 3.9+ and Git. The default
planning operation writes a private journal and makes no remote changes.
Read the failed push's source ref from the canonical sync log; do not guess
which of the cache's Dolt refs failed. Use the matching cache `repo.git`.

```sh
scripts/bd-recover-git-upload plan \
  --repo /absolute/workspace/beads \
  --cache /absolute/workspace/beads/.beads/dolt/acme/.dolt/git-remote-cache/HASH/repo.git \
  --source-ref refs/dolt/blobstore/origin/dolt/data/FAILED-UUID \
  --journal /private/scratch/recovery.json
scripts/bd-recover-git-upload upload --journal /private/scratch/recovery.json --apply
```

All operations acquire the same workspace lock as the sync hook. They refuse
an occupied lock, a mismatched fetch or push remote, source/destination drift,
changed temporary refs, or a journal that does not match reachable objects.
Each Git command has a 180-second timeout, the recovery has a one-hour budget,
and each batch contains at most 64 MiB of uncompressed blob data and 64 refs.
The journal is written atomically and fsynced before upload; it contains object
IDs and sizes, never table contents or remote credentials.

After upload, run the **canonical tracked** `templates/beads-sync.sh` claim-sync
for the existing incident. The tool never invokes `dolt push`, updates the data
ref, or clears the stale-tracker marker itself. A normal sync may still need to
reconcile another machine's writes. If it fails, keep the journal and report the
actual error. Repeating `upload` resumes accepted batches; changed source or
destination requires a new plan, retaining the old journal for later cleanup.

After normal publication succeeds:

```sh
scripts/bd-recover-git-upload cleanup --journal /private/scratch/recovery.json --apply
```

Cleanup verifies every planned blob is reachable from the currently published
history, or proves an exact native replacement publication as described below.
If the remote tip is not available locally, it defers cleanup; the next
normal sync can bring it in. Deletions use per-ref compare-and-delete leases and
atomic batches, exclusively for the journal's private temporary refs. An
unexpected replacement fails without deleting it. No lease ever targets the
Dolt data ref or a code branch. Keep the journal until cleanup succeeds; a
successful cleanup may be repeated safely. A retained temporary ref is extra
storage, not evidence of a successful tracker sync.

Run `scripts/test-bd-recover-git-upload` for the offline receive-limit,
interruption, drift, tampering, concurrency and exact-history regressions. It
uses disposable local repositories and never reads or writes the live tracker.
The existing offline-suite discovery runs it in CI automatically.

## Native root snapshots

Dolt 2.4.2 can create a parentless Git transport commit when pruning tables or
reaching its wrapper-history limit. This is separate from Dolt's database
history inside the table files. The recovery does not change those settings
or add parents. It accepts such a source only when the paired
`refs/dolt/remotes/origin/dolt/data/UUID` records exactly the observed remote
base, and rechecks that binding before upload. Arbitrary divergent histories
remain refusals. Final publication is still Dolt's own compare-and-swap; the
recovery tool never advances the data ref.

The observed tracker uses 50 MiB table parts. The 64 MiB raw-data batch ceiling
accommodates one such part while remaining far below GitHub's 2 GiB pack limit.
Larger individual objects remain explicit refusals.

## Replacement snapshots during reconciliation

A normal Dolt sync can replace table files while reconciling incoming changes.
The first live recovery uploaded 273 blobs; normal publication and a subsequent
sync succeeded, but two original blobs were absent from the published Git
wrapper history. Cleanup correctly retained the recovery refs under its current
all-blobs-reachable rule.

For a planned native root snapshot, cleanup also accepts a replacement only
when the current native cache source ref and its paired remote-tracking ref
both equal the exact observed published data tip, and that tip differs from
the plan's original base. This binds cleanup to the same cache's successful
native publication, including tables it replaced during reconciliation.

Missing or mismatched cache refs, an unchanged remote base, an unknown remote
tip, and ordinary divergent histories remain refusals. Cleanup still leases
every private ref against its expected object and never modifies the data ref.
A successful upload alone remains insufficient to authorize cleanup; normal
Dolt synchronization must publish first. This proof establishes transport
publication, not a substitute for database integrity or backup verification.
