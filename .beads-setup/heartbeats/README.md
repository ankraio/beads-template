# Setup heartbeats

One file per machine, written by `scripts/bd-setup-sync` and read by
`scripts/bd-setup-report`. Each says which setup version that machine is
running, when it last checked, and whether a periodic checker is installed.

They are committed on purpose: this is how "who has picked up the change?"
becomes answerable at all, and it rides the sync everyone already runs. One
file per machine means two machines can never conflict in git.

**Never edit these by hand.** This directory starts empty in the template; your
machines fill it in.
