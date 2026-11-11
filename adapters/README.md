# Adapters

An adapter connects the CLI to one kind of store. The mailbox format (`PROTOCOL.md`) is the same whatever the
adapter, so a mailbox could move from one store to another by copying its files.

| Adapter | Store | History (for `holds`) | Notes |
|---|---|---|---|
| `git` | any git repository you can push to | yes: every commit | The default. Works across machines and clouds. |
| `dir` | a plain folder | no: current files only | One machine, or a shared or synced folder. Good for tests. |

Choose one with `setup --adapter <name>`, or `AGENT_MAILBOX_ADAPTER`.

## The contract
An adapter is a POSIX sh file, `adapters/<name>.sh`, that the CLI sources. It sees these variables: `STORE` (the
configured address), `ROOT` (the mailbox's path inside the store), `BRANCH`, `STATE` (a private directory it may
use), `STORE_ID` (a short hash of the store, root and branch), `ME` (the agent's name, possibly empty) and `AD_INIT`
(set only while `init` publishes its own first commit: the git adapter drops that commit when another agent's init
has taken the folder meanwhile; an adapter without races can ignore it). It can call the CLI's `die`, `warn` and `clean` (which spells out control characters in text it shows). It
defines:

| Function | Must |
|---|---|
| `ad_open` | Set `AD_DIR` to a local directory whose `$ROOT/` subtree mirrors the store, creating it if needed. Cheap when it already exists. An adapter whose `AD_DIR` one command at a time must work in (a clone) takes a lock here, held until the command exits, so commands under one name take turns. |
| `ad_unlock` | Release that lock early (`watch` does, after its first sync, since it then only peeks and polls). A no-op for an adapter without one. |
| `ad_sync` | Bring `AD_DIR` up to date with the store. Publish anything an earlier `ad_commit` left unpublished, and when it did, an adapter that can tell sets `AD_PUBLISHED=1`. |
| `ad_commit <message> <path>...` | Publish exactly these paths, relative to `AD_DIR`, as one atomic change: files that exist are added or updated, files that don't are removed. On a conflict with other writers, retry. Exit 4 when the change is saved locally but couldn't be published, so the next command retries it. When the paths came out as they were, publish nothing, and an adapter that can tell sets `AD_UNCHANGED=1`. |
| `ad_poll` | Print a short token that changes whenever the store changes. Called every watch interval, so it must be cheap (one small round trip). Exit non-zero when the store can't be reached, never print a token for it. |
| `ad_peek <dir>` | List the files under `<dir>` in the store's latest state, one path per line, without changing `AD_DIR`. Exit non-zero when the store can't be reached; a `<dir>` that doesn't exist in a store that does lists nothing. |
| `ad_history <dir> [<ERE>]` | Print `<ref> <path>` for every version of every file ever under `<dir>`, oldest first, including removed ones: each time a file was added, rewritten or retyped. An adapter without history prints the current files, with `-` as the ref. With a pattern, it may leave out an added version with no line matching it, but never a rewritten one. It may list a version once when a later row has the same path, content and `<path>.sig`. Listing more is fine, since the CLI checks each file. If it can't read the history in full, or can't confirm it has the store's latest state, it prints a row `! !` (never just fewer rows), and the CLI's `holds` stops with an error. |
| `ad_show <ref> <path>` | Print a file's content as of `<ref>`; for `-`, its current content. |

The CLI writes every file to a temporary name, then moves it into place, inside `AD_DIR`, before calling `ad_commit`:
a rename, or for a new message a hard link, so that where the file system supports hard links, it never replaces a
message another send published. Reads go through
`AD_DIR` too, so an adapter for a remote service (a database, an HTTP API, an MCP server) can mirror the mailbox to a
local cache directory and translate `ad_commit` into its own writes.

**Limits.** The contract is file-shaped, which fits stores you can mirror. A service with millions of messages would
want a query interface instead (list an inbox, fetch one message) rather than a full mirror. That's a protocol
version 2 question, tracked in [#94](https://github.com/nesquena/agent-mailbox/issues/94).

## Writing a new adapter
1. Copy `dir.sh` as a starting point, and implement the eight functions (`ad_unlock` is a no-op for an adapter
   without a lock).
2. Add your adapter's name to `test/run.sh`'s default list, or run `sh test/run.sh <name>`. The same suite runs
   against every adapter.
3. Document it in the table above, including whether it keeps history.
