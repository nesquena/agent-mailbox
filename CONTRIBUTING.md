# Contributing

Thanks for helping. agent-mailbox is small on purpose. The protocol is the contract, so changes that touch it get
the most care.

## Ground rules
- **Protocol first.** A change to the file layout, a header, a status or a rule starts as an edit to `PROTOCOL.md`,
  with a line on whether it's a compatible addition or needs a new protocol version (section 10).
- **Portable shell.** The CLI and adapters are POSIX sh. They must run under dash, bash and macOS's `/bin/sh`, and
  use nothing beyond git, OpenSSH and standard Unix tools (awk, sed, find, od). Avoid `local`, arrays, `[[ ]]`,
  `sed -i` without a suffix, and GNU-only flags.
- **Every behaviour has a test.** `test/run.sh` drives the real CLI against real stores. A fix comes with a test that
  fails without it.
- **No personal data.** Commits made by the CLI carry the agent's mailbox name, never a person's name or email.
  Keep examples generic (`alice`, `bob`, `acme`).

## Running the tests
```sh
sh test/run.sh                 # every adapter, with your default sh
TEST_SHELL=dash dash test/run.sh git   # the CLI under dash, git adapter only
TEST_SHELL=bash bash test/run.sh       # the CLI under bash
```
The suite needs git. Its signature tests need `ssh-keygen`, and are skipped without it. CI runs it on Linux for
every pull request, and on Linux and macOS for every push to main and for manual runs (Actions, "test", "Run
workflow", on your branch), which is worth doing before review when a change touches shell portability. A change only
to Markdown files, `docs/` or `LICENSE` runs no tests, and a newer push to a pull request, or a newer manual run on the
same branch, cancels the run it supersedes. The `gate` job reports on every run: it passes at once for a prose-only
change, and otherwise only when every test job passed, so it's the one check a branch rule needs to require. After retargeting a pull request to another base branch, push a
commit or re-run the workflow, so the gate checks the new base.

`sh test/bench.sh [messages] [senders]` prints rough timings (sends, concurrent senders, `holds`) against a throwaway
local store. It isn't part of the suite; use it when a change could affect speed.

## Adding an adapter
See `adapters/README.md`. A new adapter passes the whole suite (`sh test/run.sh <name>`), and documents whether it
keeps history.

## Reporting a vulnerability
Don't open an issue for it: see [`SECURITY.md`](SECURITY.md).

## Proposing larger work
What's planned is in the issues labelled `enhancement`, including the Padrino web UI (#90). Comment on one to claim
it, or open an issue to propose a design before building, so two people don't build the same thing.
