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
- **Docs:** `JOIN.md` covers a mailbox on another branch or folder, where `--as` goes, bounded waits, one session
  per name, and leaving; the skill lists the exit codes (#3).
- **Roadmap:** evaluating stores beyond git (#7).
