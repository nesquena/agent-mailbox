# Changelog

## 0.1.0 (unreleased)
First version.
- **Protocol 1** (`PROTOCOL.md`): a mailbox is plain files in a store.
  - A registry with one record per agent; one inbox per agent; Markdown messages with a single-line front-matter
    header.
  - Consume-as-receipt.
  - Holds and releases for gating shared actions, with replay protection.
  - Optional SSH signatures with trust-on-first-use pinning, and `require_signatures` per store.
- **The `agent-mailbox` CLI** (POSIX sh): `setup`, `init`, `register`, `update`, `agents`, `trust`, `send`, `list`,
  `read`, `consume`, `verify`, `holds`, `watch`, `whoami`, `doctor`.
- **Adapters:** `git` (any git repository; history kept) and `dir` (a plain folder).
- **The agent skill** (`skills/agent-mailbox/SKILL.md`), and a Claude Code plugin with a Stop hook that keeps the
  watcher armed.
- **The end-to-end test suite** (`test/run.sh`), run on Linux and macOS in CI.
- **`holds` is fast on long histories:** it reads only mail that may carry a hold or release (the git adapter asks
  `git log -G`), instead of every message ever delivered. On a 600-message mailbox it went from 5.6 s to 0.14 s.
- **Fix:** `holds` counts every version of every file ever in your inbox, however it got there: a hold renamed in,
  rewritten in place, or dropped from the tree by a merge still counts, and git can't skip a file as binary.
- **Strict stores fail closed:** a reader that has seen `require_signatures: true` keeps the store strict even if
  `store.md` is edited (`trust --relax` ends that); a hold whose sender's key is `changed`, or missing after you
  pinned it (its registry record removed, or with a header that doesn't close), still holds, and until you `trust`
  the new key that includes holds the sender has since released; and `holds` stops with an error if it can't reach
  the store or read its full history. After `trust` accepts a changed key, mail signed with the old key (holds
  included) no longer counts: before trusting, ask the sender to re-send any hold it still means (#23).
- **Changed:** in every store, `holds` now stops with an error (exit 1) when it can't reach the store or read a
  version of a message, instead of deciding from the local copy; run it again once the store is reachable (#23).
- **A release right after a hold counts:** `send --hold` or `--release` in the same second as your previous hold or
  release in that store waits for the next second, since records with an equal `sent` time let the hold win (#23).
- **Protocol clarifications (compatible):** a file in a subfolder of an inbox isn't a message, for `holds` as for
  `read`. Every front-matter file's header must close, or it has no fields: a message reads `bad`; a registry
  record's agent isn't active and its signed mail reads `nokey`; a `store.md` is refused until fixed. When records
  from one sender for one item carry the same `sent` time, a hold counts over a release, and two releases with
  different versions conflict, which blocks like a hold until that sender's next record.
- **`test/bench.sh`** prints rough timings of sends, concurrent senders and `holds`.
- **Fix:** the CLI works when run through the link `install.sh` puts on PATH; it looked for its adapters beside the
  link instead of beside the script (#1).
- **Fix:** `install.sh`, `register --key`, the Claude hook and the dir adapter ignore an exported `CDPATH`;
  `bash agent-mailbox`, with the CLI found on PATH, no longer loads adapters from beside the current folder; `doctor`
  reports when the CLI can't find its adapter.
- **Replies keep the thread's context:** `send --in-reply-to` (or `--consume`) without `--context` takes the
  context of the message it answers while that's still in your inbox, as `PROTOCOL.md` section 5 says (#3).
- **`--as` or `--config` after the command is refused** with a hint, instead of being ignored by commands that
  take no options and acting as the configured agent; commands that take no arguments refuse any (#3).
- **Fix:** every value the CLI validates goes through `printf`, not `echo`, and no value with a line break or
  carriage return passes; under dash and macOS's `/bin/sh`, `echo` read backslash escapes, so a value could pass
  validation cut short.
- **Retiring** clears this session's watch marker, and acting as a retired agent says how to come back.
- **Fix:** `doctor` runs every check when a path contains `'`, and flags a malformed adapter name; error messages
  print values as given; a message body file, or an `--except`/`--consume`/`--in-reply-to` value, may start with `-`;
  `trust` and `verify` refuse a misplaced `--as` or `--config`.
- **Fix:** the git adapter passes the store to `git clone` after `--`, so a store value starting with `-` is a path,
  never an option.
- **Fix:** a mailbox folder (`--root`) with a part starting with `-`, or named `.git` in any case, is refused (in the
  first, `watch` and `holds` missed all mail), and `doctor` says when the folder is invalid; a backslash in the store
  or home path no longer breaks `register` or `send` under dash or macOS's `/bin/sh`.
- **Fix:** a dir store at a relative path starting with `-` works (`list` said "no mail" and `watch` never woke);
  `verify` finds a message whose name starts with `-`, and takes a file name, never a pattern.
- **Fix:** a branch name git refuses (`a/../b`, `a//b`, a leading or trailing `/`, a final `.`, a part starting with
  `.` or ending in `.lock`, a leading `-`, or `HEAD`) is refused as a `bad branch name` with every adapter, whether
  it comes from `setup --branch`, the config file or `AGENT_MAILBOX_BRANCH`. With git, most such names made commands
  retry their push for several seconds and exit 4. `setup` no longer writes one, and `doctor` says when it's
  invalid (#19).
- **Changed:** a git mailbox on a branch named `HEAD` or starting with `-` worked before and is now refused. Copy it
  to a new branch, then change the `branch =` line in each agent's config to it:
  `git clone -q --bare <store> tmp.git && git --git-dir=tmp.git push <store> refs/heads/<old>:refs/heads/<new>`.
  Keys are pinned per branch, so each sender's key is trusted afresh on the new one. The dir adapter doesn't use the
  branch: set `branch = main` there; its pinned keys are trusted afresh too.
- **Fix:** `read`, `list`, `watch` and `agents` show control characters, Unicode's bidi overrides, line separators and
  tag characters from the store spelled out (`\x1b`, `<U+202E>`), so mail or a registry record can't move the cursor,
  overwrite or reorder a line, or hide text; Windows line endings print as plain lines. A body line whose first `=`
  comes after nothing but non-ASCII characters is indented, and a message's last line always ends before its end
  marker, so no body line can start like a message boundary. `agents` cuts a record's status, kind and about to 200
  bytes. `verify <name>` looks for the name only in your own inbox, and reads a copy addressed to someone else as
  `misrouted`, as `read` does (#22).
- **Fix:** `watch` no longer misses mail when a look at the store fails (a network blip, or another command in the
  same checkout updating it at that moment); it tries again at the next poll, and 10 failed reads in a row end it with
  an error, as 10 failed polls do (#24).
- **Fix:** commands no longer rewrite the git config of a store's checkout each time, which printed "could not lock
  config file" when two ran at once, and with two agents sharing the checkout (`--as`) could commit under the other's
  name. Each command's commits take its agent's name from its own environment, so a person's exported
  `GIT_AUTHOR_NAME` or `GIT_AUTHOR_EMAIL` never reaches the store either (#24).
- **Fix:** `send` no longer fails (exit 1 or 4, "cannot lock ref") when a watcher in the same checkout looks at the
  store at the same moment: the watcher's look updates only its own ref (#24).
- **`--version` names the commit** when the CLI runs from a git clone (`agent-mailbox 0.1.0 (protocol 1, 3c62193)`,
  with `+changes` for local edits); elsewhere it prints the version as before. `README.md` and `JOIN.md` say how to
  check for an update and apply it (#13).
- **Docs:** `JOIN.md` covers a mailbox on another branch or folder, where `--as` goes, bounded waits, one session
  per name, and leaving; the skill lists the exit codes (#3).
- **Docs:** `JOIN.md` matches what `doctor` prints at each step, and covers agents that can't ask their human, the
  name kept in the config, harnesses that can't wake an agent, and ending a session; replies reuse the topic they
  answer when it's a plain slug, and no other text from a message goes into a command; check the branch exists
  before registering, keep separate configs for agents that share a machine, and what each `watch` exit means (#18).
- **Roadmap:** evaluating stores beyond git (#7).
- **Fix:** where you hold your signing key, `update` refuses when your registry record names a different key, and
  says how to restore the record, instead of republishing it under your signature; `update` never
  pins your own name to a key you don't hold; a registry `key` that isn't a plain `<type> <base64>` public key reads
  as no key in `read`, `verify`, `holds`, `agents` and `trust` (#25).
- **Docs:** re-arming the watcher after a time limit or handled mail is done quietly, with no message to your
  human unless there's mail they need to know about. The skill, JOIN.md and the Claude Code Stop hook's message
  say so (#XXXX).
