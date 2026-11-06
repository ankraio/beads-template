# Beads quickstart

One page from zero to a working tracker and agents that use it the way the team does. Every step has a longer form in [SETUP.md](SETUP.md); read that when something here does not go as written.

```sh
WS="$HOME/work/acme"      # your workspace root (not a git repo)
```

1. **Install bd 1.1.0, pinned, and dolt.** Follow SETUP.md step 1 (checksum-verified tarball, or `brew install beads && brew pin beads`). `bd version` must print 1.1.0; a different version drifts the shared schema.
2. **Clone the tracker into the workspace.**
   ```sh
   cd "$WS" && git clone git@github.com:<your-org>/beads.git && ln -s beads/.beads .beads
   ```
3. **Point bd at it, per workspace, never globally.**
   ```sh
   echo 'export BEADS_DIR='"$WS"'/beads/.beads' >> "$WS/.envrc" && direnv allow "$WS"
   ```
4. **Bootstrap the database and check it.**
   ```sh
   cd "$WS/beads" && bd bootstrap --yes && bd status && bd statuses   # 4,000+ issues, in_review listed
   bd dolt status                                                     # must say server, not embedded
   ```
5. **Give your agents the team rules.** The rules file is a symlink, so it can never be stale; the settings file is generated once from the template. Credentials never go in `settings.json`; put them in `settings.local.json`.
   ```sh
   ln -sfn beads/templates/workspace-CLAUDE.md "$WS/CLAUDE.md"
   mkdir -p "$WS/.claude"
   sed "s#/ABSOLUTE/PATH/TO/WORKSPACE#$WS#g" "$WS/beads/templates/workspace-settings.json" > "$WS/.claude/settings.json"
   ```
6. **Verify.** Start a fresh session in `$WS`, or run the checks directly:
   ```sh
   cd "$WS/beads" && bd prime | wc -c          # about 2,200 bytes, not 111,000
   scripts/bd-health                            # silent when clean
   scripts/bd-setup-sync "$WS/beads"            # "Beads setup is current"
   ```
7. **One machine only, the always-on one:** `scripts/bd-hygiene --install-launchd` (hourly duplicates, stale beads, oldest in_progress/in_review). Everyone else skips this.

## Every day

```sh
bd ready                          # find work          bd show <id>
bd update <id> --claim            # claim it           bd find-duplicates   # once, after claiming
# work in a worktree under .worktrees/, never in a shared checkout
# open the PR with a `Bead: <id>` body line (`Beads: <a>, <b>` for several) - it is the
# whole list; the title, then the branch's LEADING id, only count when there is none
bd comment <id> "PR: https://github.com/<your-org>/<repo>/pull/<n>"
bd update <id> --status=in_review # automation closes it when the PR merges
```

## Never

`bd dolt push` or `bd dolt pull` by hand (the hooks own sync). `bd edit` (opens an editor, hangs agents). `bd init --force` (destructive; repair is `bd bootstrap`). Hand-editing `.beads/issues.jsonl` (it is an export).

## When something is wrong

`scripts/bd-health` says what. `~/.claude/logs/beads-sync.log` says why. SETUP.md "Troubleshooting" has the runbook for each message.
