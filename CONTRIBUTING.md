# Contributing

Thanks for helping. agent-mailbox is small on purpose. The protocol is the contract, so changes that touch it get
the most care.

## Ground rules
- **Protocol first.** A change to the file layout, a header, a status or a rule starts as an edit to `PROTOCOL.md`,
  with a line on whether it's a compatible addition or needs a new protocol version (section 10).
- **Portable shell.** The CLI and adapters are POSIX sh. They must run under dash, bash and macOS's `/bin/sh`, and
  use nothing beyond git, OpenSSH and standard Unix tools (awk, sed, find, od). Avoid `local`, arrays, `[[ ]]`,
  `sed -i` without a suffix, and GNU-only flags.
- **Every behaviour has a test.** `test/run.sh` and the [bats-core](https://github.com/bats-core/bats-core) files
  `test/*.bats` drive the real CLI against real stores. A fix comes with a test that fails without it.
- **Nothing waits forever.** A test that waits for something (mail, a file, a watcher, a hook) first checks that what
  it waits for exists, and runs under a bound: `time_cap <seconds> <command>` in `test/run.sh` (it passes the
  command's stdout, then its stderr, so a `2>&1` capture comes out in that order, and a process the command leaves
  running keeps running until the run's exit cleanup), which stops the command and everything it started and fails
  with exit 124, or `BATS_TEST_TIMEOUT` (120 s by default; bats-core 1.13 or later stops the processes under `run`
  too) in bats. `time_cap` stops the command and everything it started; something that escapes it (its parent gone) is
  stopped at the run's end only when its command line names the run's folder. The whole run stops itself, failing,
  after `AGENT_MAILBOX_TEST_LIMIT` seconds (40 minutes by default; a full run takes about 15, 20 on macOS). The run is
  always ended: TERM first (exit 124, with a FAIL line), then KILL a few seconds later if it's still there (exit 137,
  with no line of its own; its folder is removed). A hang then costs one failed check, never an unattended wait.
- **No personal data.** Commits made by the CLI carry the agent's mailbox name, never a person's name or email.
  Keep examples generic (`alice`, `bob`, `acme`).

## Running the tests
```sh
sh test/run.sh                 # every adapter, with your default sh
TEST_SHELL=dash dash test/run.sh git   # the CLI under dash, git adapter only
TEST_SHELL=bash bash test/run.sh       # the CLI under bash
sh test/run.sh --list                  # the ids of the suite's sections
sh test/run.sh --only stop-hook,bats   # just those sections
sh test/run.sh --shard 2/4             # shard 2 of 4, as CI runs it
```
The suite needs git. Its signature tests need `ssh-keygen`, and are skipped without it. Tests are moving, a section at a
time, from `test/run.sh` to bats-core files under `test/` (bats-core 1.4 or later, which runs on bash 3.2 and later:
`brew install bats-core`, or your package manager's `bats`). `test/run.sh` runs them last, and skips them without bats.
To run them alone, `bats test/`, or `TEST_SHELL=dash bats test/` for the CLI under dash: the test files are bash, and
the CLI they drive runs under `TEST_SHELL` (default `sh`). A new test goes in a `.bats` file; its shared setup is in
`test/helpers.bash`.

`test/run.sh` is a list of sections, each opening with its `==` line and run in a folder of its own. Each makes what
it needs itself (its own store, homes and helper files), so any of them runs alone or in any order: `--order <seed>`
shuffles them, to check that none leans on what another did. A shuffled run prints its seed first (`order: seed N`):
the same options with `--order N` run that order again. `--shard i/n` runs shard i of n, the sections split so the
shards take about as long: by the seconds each takes alone, in `test/section-costs`, one `<id> <seconds>` line each.
A new section needs a line there (time `test/run.sh --only <id>`). `sh test/shards-cover.sh` checks that the shards
of 4, and of 3, run every section once between them, and that `test/section-costs` has a well-formed line for each
section, and nothing else; `sh test/shards-cover.sh --logs <whole run's output> <each shard's output>...` checks that
the shards printed the same checks as a whole run.

To find the slow checks, set `TEST_TIMES=<file>` (with any of the options above): each check's own time goes in that
file, one `<ms><tab><section><tab><status><tab><check>` line each, bats tests included, and the run ends by listing
the 15 slowest. A wait that takes much longer than the work it waits for is the place to look.

CI runs the suite on Linux for every pull request, and on Linux and macOS for every push to main, every manual run
(Actions, "test", "Run workflow", on your branch) and every release, in four shards per shell, side by side. A
push to main runs the shards with `--order` and the run's number, so each push tries another order. A manual run and
a release also run the whole suite once per OS, as one shard (`--shard 1/1`). A pull request with the `macos`
label runs macOS too, from its next push. A re-run doesn't pick up the label (it reuses the labels the run started
with): push a commit, or, for a branch you can't push to, close and reopen the pull request. For a change macOS's
tools may treat differently (`find`, `sed`, `ps`, process handling), add the label or start a manual run. A change
only to Markdown files, `docs/` or `LICENSE` runs no tests, and a newer push to a pull request, or a newer manual run
on the same branch, cancels the run it supersedes. The `gate` job reports on every run: it passes at once for a
prose-only change, and otherwise only when every test job (every shard, and each whole run) passed, so it's the
one check a branch rule needs to require. After retargeting a pull request to another base branch, push a commit, or
close and reopen the pull request, so the gate checks the new base (a re-run checks the old one).

`sh test/bench.sh [messages] [senders]` prints rough timings (sends, concurrent senders, `holds`) against a throwaway
local store. It isn't part of the suite; use it when a change could affect speed.

## Releasing
A release is a pull request that sets `VERSION` in `bin/agent-mailbox` and dates the top `CHANGELOG.md` heading
(`## X.Y.Z (YYYY-MM-DD)`). Once it's merged, a maintainer runs Actions, "release", "Run workflow" on main with the
version. The workflow checks that the version, `VERSION` and the heading agree and that the tag is new, runs the tests
on Linux and macOS on that commit, and then waits for a reviewer of the `release` environment to approve. On approval
it tags `vX.Y.Z` on that commit and publishes the GitHub release, with that version's `CHANGELOG.md` section as its
notes. A private repository whose `release` environment requires no reviewer (most plans can't require one there)
runs without one, so there the dispatch itself is the approval; a public repository always needs the reviewer. If the
release step fails after the tag was made, re-running the failed job publishes it.

## Adding an adapter
See `adapters/README.md`. A new adapter passes the whole suite (`sh test/run.sh <name>`), and documents whether it
keeps history.

## Reporting a vulnerability
Don't open an issue for it: see [`SECURITY.md`](SECURITY.md).

## Proposing larger work
What's planned is in the issues labelled `enhancement`, including the Padrino web UI (#90). Comment on one to claim
it, or open an issue to propose a design before building, so two people don't build the same thing.
