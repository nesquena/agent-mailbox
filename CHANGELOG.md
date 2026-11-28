# Changelog

## Unreleased

- **A local ref in the CLI's clone named like `HEAD` or `REBASE_HEAD` (such as `refs/heads/HEAD`, or `refs/heads/head` on
  a case-insensitive filesystem) no longer stands in for the clone's current commit or the commit a stopped rebase was
  replaying.** Recovering from a conflicted rebase now also works on git older than 2.17, and a command whose clone has
  no readable current commit stops with exit 4 instead of retrying its push.
- **When a store's mailbox branch is rewound (force-pushed), an existing clone drops the commits the store's branch no
  longer has instead of pushing them back, including when the rewind lands between a command's sync and its push (but
  not when a command is killed while it syncs).** Unpublished commits the clone made on top are still rebased onto the
  store's new tip and published (or set aside under `refs/agent-mailbox/stuck/` if they conflict), and the command
  prints `"the store's branch was rewound; <N> commit(s) the store's branch no longer has were dropped from this copy,
  not republished"`. A send whose store branch is deleted between its sync and its push now stops with exit 4 instead of
  re-creating the branch. For admins: force-pushing the branch, or restoring the store from an older backup, now undoes
  every change made after the point you restore to: mail sent, messages consumed (they reappear), and `register` or
  `update` changes. Fetch first and push with `--force-with-lease=refs/heads/<branch>:<the tip you checked>`, then ask
  agents to send that mail again, consume again what reappears, and re-run `register` or `update`.
- **A mailbox clone now uses only the store's exact mailbox branch, so no other ref in the store can stand in for it,
  even before the branch exists.** A new copy keeps only the mailbox branch, its tracking ref, and the CLI's own refs
  (peek, history, and set-aside stuck refs). An existing copy loses only tags and refs named like `HEAD` (including
  `origin/HEAD`), and keeps any branch of yours. Each update from the store now makes one extra network round trip to
  check the branch tip before fetching. If a fetch still does not match the store's mailbox branch tip, the command
  stops with `"fetched commit (...) did not match refs/heads/<branch> (...)"` and names any colliding store ref to
  remove; for `holds`, a fetch mismatch stops with `"can't read this store's full, latest history"`, and for `watch`, it
  counts as a failed read. Before the mailbox branch first exists, if a store ref collides with `refs/heads/<branch>`,
  the command stops at once with exit 4 and names the colliding ref(s) to remove from the store (a branch deleted
  mid-command isn't covered by that pre-check). When git reports `"matches more than one"` on push, the command likewise
  stops at once with exit 4 and names any colliding ref(s) to remove, or shows git's message if no collider is found.

## 0.1.4 (2026-11-27)

Arguments that name one message now refuse whitespace, so a value holding several paths can't be cut down to its last;
the git adapter keeps tags out of mailbox clones and refers to the store's branch by its full name, and `holds` sees a
message and its signature committed separately; more commands stop, saying so, on files they can't read; and the Claude
Code plugin starts its watcher on `SessionStart` too. Check the message-name and `send --consume` entries if a script
passes paths under folders with spaces, or several names in one argument, or an empty name to `--consume` or an empty or
non-message name to `--in-reply-to`, and the `doctor` entry if a script reads its output.

- **The git adapter no longer fetches tags into a mailbox clone (`--no-tags` on fetches,
  `remote.origin.tagOpt=--no-tags`, and any tags in the clone are removed on open, including those a fresh clone
  fetched), and refers to the store's branch only by its full remote-tracking name (`refs/remotes/origin/<branch>`),
  checked by exact match.** A tag in the store, or a store whose default branch is named `origin/<branch>` or
  `refs/remotes/origin/<branch>`, can't change which commit the clone uses, and git 2.9 still works.
- **`holds` with the git adapter lists a message when a commit (or a merge's diff against a parent) adds, changes or
  retypes `<msg>.md.sig` without changing `<msg>.md`**, so a message and its signature committed separately give `holds`
  the same verdict as `read` and `verify`. When inbox history contains such a `.sig` commit and the object lookup fails
  or stops short, `holds` now stops with its "can't read this store's full, latest history" error instead of going on.
- **`holds` normalises `./` segments in `--root`** (such as `--root ./mailbox`) before matching inbox paths, so records
  under those roots are no longer skipped.
- **Claude Code plugin: the rewake hook stopped as it starts holds up the next one only in a far narrower window.** A
  stop just after it took its short mutex, before its traps were set, left the mutex, so every hook starting in the next
  minute or so stepped aside and the session waited for a re-arm; its traps are now set before it takes the mutex, so
  only a stop in the moment it takes or releases the mutex can still leave it, and a stop once its traps are set ends
  the hook with exit 0 rather than 143. A stopped hook also no longer takes the mutex a second time as it exits, which
  could make a hook starting at that moment step aside. And its watchdog's deadline file is named by the hook's process,
  so a deadline an earlier run's watchdog wrote, even one landing just after a new run started, is never taken as the
  new run reaching its daily limit.
- **Message-name arguments now refuse whitespace (spaces, tabs, line breaks) before taking a basename**, in `consume`,
  `send --consume`, `send --in-reply-to`, `reply`, `verify` (by name), `read` (`<file>` and `--except`), and
  `watch --except`. Before, one argument holding several paths (such as `"$(agent-mailbox list)"` or space-separated
  paths) narrowed to its last path's basename and silently dropped the rest; pass each file as its own argument
  (`consume <file>...`, or repeat `--consume` / `--except` once per message). Outside `verify` on an existing file on
  disk, a single path whose folders hold whitespace (such as an absolute path under `/Users/Jo Smith/...`) is now
  refused too: pass the message by name (or a store-relative path without whitespace, such as
  `mailbox/inbox/<you>/<name>`). `send --in-reply-to` now accepts only `none` or a message file name (or a path to one
  without whitespace), refusing an empty value or any other non-message name where before it took any basename;
  `read --except` and `watch --except` still ignore a non-message name without whitespace.
- **`send --consume` refuses a pattern, an empty name, or several bare names in one value**, before anything is sent.
  Before, a pattern such as `'*.md'` could match a file in the current folder and consume the inbox message of that
  name, an empty name was ignored, and bare names separated by spaces or line breaks were each consumed. Give
  `--consume` once for each message. `send --consume` and `consume` now remove a message's `.md` first and its `.sig`
  only after, so a message that can't be removed keeps its signature.
- **A watcher stopped right as it starts no longer leaves its pid files behind.** `watch` wrote its pid files before it
  set the traps that remove them, so a TERM or INT in between (a harness ending it at once) left stale files. The traps
  now come first.
- **A watcher ended by HUP (its terminal closing) exits 130 and removes its pid files**, as for TERM and INT; it ended
  with HUP's own status (129), and under dash left them. And a command stopped the moment it takes the git adapter's
  lock, or the plugin's rewake hook stopped the moment it starts, no longer leaves that lock or its pid file for the
  next one to clear. A command stopped while it waits for that lock ends with status 130 (it was 143 for TERM), as it
  does once it holds it.
- **Claude Code plugin: the watcher hook now starts on `SessionStart` as well as `Stop`.** A resumed or restarted
  session that already ran `watch` begins listening for mail right away, instead of waiting until its first turn ends;
  sessions that haven't run `watch` still do nothing. Update the plugin (`claude plugin marketplace update
  agent-mailbox` and `claude plugin update agent-mailbox@agent-mailbox`); new and resumed sessions pick it up.
- **An inbox, record, message or signature that can't be read stops the command, saying so, in more places.** With the
  mailbox's inbox folder not searchable, `watch` said "no mail" and `holds` "nothing recorded"; both now stop at once.
  A sender's registry record that can't be read (or whose folder can't be searched, or a link there whose target can't
  be reached) read as having no key, so a store requiring signatures dropped that sender's hold if you hadn't pinned
  its key, and `holds` could say "released"; it now stops, and so does `read`, which showed that sender's mail as
  `[nokey]`. `verify` of a message or signature it can't read said "bad" (exit 6); it now says it can't read it and
  exits 1, as other errors do: 6 still means read and not verified. `reply` of such a message now says it can't read
  it (it stopped before, saying its header wasn't plain), and `sent` stops, saying it can't read a message of yours
  (exit 1), where it left that message out. `verify` of a message whose sender's record can't be read exits 1 too
  (it said `nokey`, exit 6), and `reply` to one says it can't read the record (it said the message doesn't verify,
  `nokey`).
- **One rule for an agent's record: anything at its path that isn't a file that can be read, and isn't known to be
  absent, stops the command, saying so.** A folder or a FIFO there read as an agent with no key; a record that can't be
  read read as a retired agent: `send` to that agent said it "isn't an active agent", `watch` as it said "(you) is
  retired", `agents` showed it as `(!name)` and `agents --names` left it out, and `trust` said it "has no registered
  key". `read` stopping on such a record says how to read the rest (consume the message, or `--except`).
  `update` and `register` follow it too: with your own record unreadable, `update` rewrote it with its fields blank,
  dropping its key and body, and now stops before writing anything. `agents` stops when the records folder can't be
  listed (where it printed an empty list) and checks every record file before printing, so `agents --names` never
  prints a list cut short by an unreadable record file or dangling link; in `agents` and `agents --names` only, a
  non-file entry at `<name>.md` (a folder, a FIFO, or a link to either) is skipped with a warning on stderr so the rest
  still list, while every single-agent command (`send`, `verify`, `trust`, `watch`, `update`, `register`, `doctor`)
  stops on it. `doctor` says once when your record isn't a file or can't be read.
- **More commands stop, saying so, when the mailbox's inbox folder can't be searched, written, or isn't a folder:**
  `consume`, `send --consume` and `verify` by name stop when `mailbox/inbox` can't be searched (they said "not in your
  inbox" or "no such message"). A file or dangling link at `mailbox/inbox/<you>` stops `list`, `read` and `watch` with
  "isn't a folder", where they said no mail. `consume` and `send --consume` stop before acting when your inbox folder
  can't be written (e.g. read-only), and fail if removing a message (or its `.sig`) leaves the file behind (reporting
  what was already sent or consumed on in-place adapters such as `dir`, or that nothing was sent on staged ones such
  as `git`), where before `consume` reported "consumed" and `send --consume` sent without consuming. `watch` looks at
  the inbox at every tick, so one that becomes unsearchable mid-watch stops it at once, even when no inbox holds a
  message (it ran to its limit and said "no mail").
- **`holds` with an adapter that keeps no history (dir) passes over a message consumed while it reads**, as `read`
  does; it stopped, saying it couldn't read the store's history.
- **An agent with no inbox folder has no mail again where the mailbox's inbox folder can be searched but not listed.**
  0.1.3 stopped there ("can't list"); the folder's absence is known, so it's no mail, as before. A folder that can't be
  searched still stops the command.
- **`doctor` says when the Claude Code plugin's Stop guard can't run, and whether a watcher is up.** Inside Claude Code
  it warns when `jq` isn't on its shell's PATH: the plugin's Stop guard needs it, and without it lets every turn end
  with no watcher running, silently (the other hook doesn't need it). Outside Claude Code it says nothing about `jq`,
  which the CLI itself never uses. It also says whether a watcher for the name is running on the store (with its pid),
  and warns when this session ran `watch` for the name and none is running now, giving the re-arm command the Stop
  guard gives (with the `--config` this session watched the store with, and `--also` when the session watches several
  stores), and adding when the plugin's hook declined to start one at the last turn end. On a turn the plugin's hook
  woke, when it starts the next watcher at the turn's end, that's an `info` line instead of a warning. These lines
  never make `doctor` fail. The watcher lines that aren't warnings (a watcher running, none running, or the hook
  starting one) are a new first word, `info`, printed alongside `ok`, `busy`, `warn` and `FAIL`: a script that reads
  doctor's output by its first word should expect it.
- **`list` and `read`: sender, topic and age, filters, and stale mail.** `list --long` shows each message's sender,
  topic, age and `needs`, and marks it `stale` once it has waited over 24 hours, with the same age rule as `sent`, so
  the recipient can raise stale mail too (`PROTOCOL.md` section 5). Its values come from the header, unverified, with
  control characters spelled out; a sender or topic that isn't a plain name shows `?`, a file name that isn't
  `<stamp>-<from>-<topic>.md` for its header is marked `name mismatch` (`read` says what the name should be), and a
  header that isn't plain is marked `header not plain (see read)`. `--from`, `--topic` and `--context` on `list` and
  `read` keep only mail whose unverified header has that value, and `read <file>...` reads just the messages named,
  refusing any that isn't in your inbox. A message that can't be read stops `list --long` and a filtered `list` or
  `read`, as it stops `read`, rather than being left out. Plain `list` prints exactly what it did before.
- **`update` and `trust` with a key whose pin is unchanged no longer stop on a read-only pins folder.** There's
  nothing to write, so the pin is left as it is; before, both stopped with "can't record ...'s key".
- **Under a file size limit, a write to the CLI's own files or signing that fails prints only the CLI's own message.**
  The shell's "File size limit exceeded" no longer comes first (git's own writes in the git adapter still print git's
  or the shell's line); and under bash, what couldn't be written (a key's fingerprint, a lock line) is no longer
  printed to the terminal.
- **The git adapter now clears stale git lock files older than a minute** (outside `.git/objects/`, such as `HEAD.lock`,
  branch locks, `REBASE_HEAD.lock` and a stalled watcher's `peek.lock`) left by an earlier command killed mid-git
  (`SIGXFSZ`, `SIGKILL`, or a crash), so the next command recovers instead of failing until the lock file is removed by
  hand; fresh locks are left alone (`index.lock`, as before, is cleared at once). Git's automatic housekeeping (`gc`,
  `maintenance`) now runs before the command returns (`autoDetach=false`, so a commit's housekeeping warnings print on
  the command's own stderr) rather than detaching past the adapter's lock, and `watch`'s peeks run with automatic
  housekeeping off.
- **`holds` with the dir adapter no longer says "as of -"** when it names a file it can't read.

## 0.1.3 (2026-11-19)

Commands that can't write or read a file they need now stop, saying why, where they used to say "verified", "bad",
"pinned", "no mail" or "released"; a git command no longer fails while others take turns on the lock; and CI runs the
tests in shards. If you wrote an adapter of your own, see the `holds` entry: `ad_show` must exit 1 only when a file
isn't there.

- **Commands that can't write a file they need now stop at once, saying why.** A lock write that fails on a full disk
  stops with "can't write the lock … (is the disk full?)", rather than waiting out the lock wait (two minutes by
  default) and blaming "another agent-mailbox command (pid unknown)". A strict store's pin that can't be recorded stops
  the command with a message, where bash carried on without it; and `init` on a folder it can't write stops with a
  message, where bash reported it initialized without the `.keep` files. Under dash, the pin and init ended with the
  shell's own error. A key pin that can't be recorded now stops `verify`, `read`, `reply`, `holds`, `register`,
  `update` and `trust` too, where they said "verified" or "pinned" (or `reply` sent and consumed, `holds` decided, or
  `register` and `update` reported the record) and recorded nothing, so a later key swap would have gone unseen; and a
  pin write that fails leaves the pin as it was. `trust` and `update` need room for a new copy of the pin, so on a full
  disk they refuse where they used to rewrite the pin in place. And `verify`, `read`, `reply` and `holds` stop when they
  can't write the list of keys a signature is checked against, where good signatures read bad.
- **A copy into the state folder that fails is no longer read as a verdict about the mail.** `read` and `holds` copy
  each message and its signature into the state folder before checking them. On a full disk, a read-only state folder
  or a file size limit, `holds` read a signed hold as unsigned, which a store requiring signatures drops, so it could
  report "released"; `read` showed signed mail as unsigned, or skipped every message and said "no mail". Both now stop,
  saying the state folder can't be written. `read` also stops at a message or signature in the store that it can't
  read, where it skipped the message or showed it as unsigned: `consume` it, or pass `--except`, to read the rest. A
  folder or a link at a key's pin path is refused: a folder there took no pin and `verify` said verified, and a link was
  followed, so a pin kept as a link now stops every check until it's a plain file. `trust --relax` says so
  when it can't lift the pin.
- **`holds` no longer reads a signature it can't read as no signature.** With the dir adapter, a hold's `.sig` that was
  there but couldn't be read (its permissions) read as unsigned, so a store requiring signatures dropped the hold and
  `holds` could report "released"; it now stops, saying which file it can't read. Adapters: `ad_show` exits 1 only
  when the file isn't there in that version, and 2 when it's there and can't be read (adapters/README.md). An adapter
  of your own must exit 1, and only 1, when the file isn't there: any other failure now stops `holds`.
- **An inbox folder, or the mailbox's inbox folder, that can't be listed stops `list`, `read`, `sent` and a retiring
  `update`, saying so.** `list` and `read` said "no mail", `sent` left that inbox out, and `update --status retired`
  retired as if the inbox were empty.
- **Without `sha256sum` or `shasum`, commands that open a store stop, saying so.** The store's id, a hash, names its
  key pins, the git adapter's copy and its locks in the state folder; without one every store shared them, and a key
  pin left empty by an older version matched any key.
- **`send` no longer refuses every body under dash or busybox where ~/.ssh (or the config or state folder) can't be
  read back**, as in a macOS sandbox that hides it: the folder is checked as named. Where it can still be listed, a
  file a link kept in it leads to is now refused under every shell (under bash it used to be sent).
  `register --key` with a key in such a folder says so rather than recording a wrong path; the plugin's hooks and
  `install.sh` no longer take an unreadable path for `/`; and `watch` records a session's config as named. Two changes
  there fail closed: under dash or busybox, a body whose own folder's path can't be read back is now refused, as bash
  already did; and under dash or busybox a CLI installed in such a folder now says "can't find the folder this script
  is in" instead of looking for its adapters at `/`.
- **git: a command no longer fails with "can't create the lock" while others are taking turns.** When another
  command's lock came and went between its two tries, a command took that for a lock it couldn't make, and stopped. It
  now stops only when no file can be made in the lock's folder, and otherwise waits its turn. It finds that out by
  making one rather than asking `test -w`, which says yes where a sandbox or a disk with no free inodes refuses one,
  so there a stale lock it can't remove now stops it at once, saying so, instead of waiting out the lock wait and
  blaming the dead holder.
- **docs/listening.md has two more worked examples.** Codex: a worker detects new mail with a bounded `watch`, and a
  scheduled check is what wakes an idle session in the tested setup, with what isn't yet established there. A Grok Bot
  (approach 3): a GitHub Action on the store's repository calls a routine's webhook when mail lands in the bot's
  inbox. Each is written from a working setup. The skill points to them. docs/listening.md, JOIN.md and the skill now
  give a foreground `watch` a timeout that covers one interval and the lock wait `watch` may spend first (700 s, say,
  for `watch 10 540`).
- **`reply` says what a refused message's file name should be.** For a message whose file name doesn't match its
  header, `reply` now says "its file name doesn't name it as from <from> about <topic>", as `read` does, rather than
  guessing whether the sender or the topic is off (names may hold '-', so which part is off can't always be told).
- **Claude Code plugin: the rewake hook works, or declines safely, where a sandbox blocks `ps` and the shared temp
  folder.** Watching several stores, it made its temporary folder with `mktemp -d` and no template; on macOS that
  ignores TMPDIR, so inside a sandbox that gives the hook its own TMPDIR it ended without watching. It now makes it
  under TMPDIR (or, when TMPDIR names a folder that isn't there, in the system's temporary folder). Where it can't
  read Claude Code's arguments at all (macOS won't start `ps`, a setuid program, inside a sandbox), it declines as it
  does when it can't tell, rather than missing a `claude -p` and waiting at every turn end.
- **`read` and `holds` say what's actually wrong.** For a message whose file name doesn't match its header, and whose
  topic is a valid name, `read` now says what the name should be ("its file name doesn't name it as from <from> about
  <topic>"), rather than saying the file name doesn't name the sender, which was wrong when only the topic differed.
  `holds` says a record blocks because its `sent:` time or its `hold:` or `release:` line doesn't parse, rather than
  calling that header not plain.
- **CI runs the tests in four shards per shell**, side by side, so a pull request's tests on Linux take about a third
  as long.
  `test/run.sh --list`, `--only <id>` and `--shard i/n` run part of the suite, and `test/shards-cover.sh` checks that
  the shards run every section once (`CONTRIBUTING.md`); with no options `test/run.sh` runs it all, as before. Each
  section runs in a folder of its own. A push to main runs the shards in a shuffled order (`--order`, its seed printed
  first); a manual run and a release also run the whole suite once per OS.
- **CI: pull requests run the tests on Linux only**, and every push to main (except a prose-only one, which runs
  no tests), manual run and release runs Linux and macOS. A pull request with the `macos` label runs macOS too
  (`CONTRIBUTING.md`).

## 0.1.2 (2026-11-12)

Registry records can say who an agent works for, where it runs and its groups, and `agents` filters by them;
`reply` answers a message and consumes it in one command; and fixes to `holds`, `setup` and the git adapter. `agents`'
table has new columns: see the first entry if a script reads it.

- **Registry records can say who an agent works for, where it runs and its groups.** Optional `human`, `env` and
  `groups` fields (`register` and `update` take `--human`, `--env` and `--groups`; `setup --human` sets a default).
  `agents` shows them, and filters by them with `--human`, `--env` and `--group`; `--names` prints just the matching
  active names, yours too when you match, for sending to each. `agents`' table gained HUMAN, ENV and GROUPS columns
  before ABOUT, so a script that cut ABOUT by position must change: use `--names` for names. They're each agent's own
  claims about itself, which the CLI doesn't check: any store writer can edit a record, and an agent's next `update`
  signs what its record then holds, so make no trust decision from them.
- **git: a leftover commit that conflicts with the store no longer blocks every later command.** A message an earlier
  command couldn't publish, whose file name the store meanwhile took for another message (two senders whose name and
  topic join to one name, in one second), is now moved to a new name and published, saying so. Any other leftover that
  conflicts is set aside under `refs/agent-mailbox/stuck/<n>` in the clone, with a warning, and the clone goes on from
  the store: what it held isn't published, so send that mail again, or for an `update` or `register`, run the command
  again. This needs git 2.17 or later; with an older git, such a leftover fails every command as before. A `send`
  whose file name is already taken in that second now waits for the next second once, instead of failing.
- **`setup` says when your pinned keys stay behind.** Pinned keys belong to the store settings as written, so new
  settings start with none, even for the same mailbox spelled another way (a trailing `/`, ssh instead of https).
  Re-running `setup` with a different store, root or branch now says so. For the same mailbox, keep its address as
  first written.
- **`reply <file> <body>` answers a message and consumes it in one command.** It sends to the message's sender, on its
  topic, with `in_reply_to` naming it and its context kept, and removes it from your inbox in the same change, as
  `send … --in-reply-to <file> --consume <file>` does. `--keep` leaves it in your inbox, and `--needs`, `--context`,
  `--hold` and `--release` pass through to `send`. It refuses a message that isn't in your inbox, one whose `from:`
  header and file name name different senders or whose `topic:` isn't the one its file name names (or whose header
  isn't plain), and one that reads `bad`, `changed` or
  `misrouted`, so consuming it can't remove the sign of tampering unseen. In a store that requires signatures it
  refuses anything that doesn't verify; elsewhere it answers an `unsigned` or `nokey` message, and says so.
- **`holds` warns when the adapter keeps no history.** An adapter now declares whether it does, by setting
  `AD_HISTORY` when it's sourced: `full` for git, `current` for dir (`adapters/README.md`). With any value but `full`,
  or none (a third-party adapter that doesn't say), `holds` prints a warning on stderr that a hold or release that was
  consumed or deleted isn't seen. Its verdict and exit code don't change.
- **`holds` blocks on a hold or release it can't fully parse, instead of skipping it.** A record whose `sent` isn't in
  the one form (say, with a fraction of a second), or whose item has more after it, was skipped, so the sender's older
  release could decide. It's now read like a record whose header isn't plain: it blocks that item until the sender's
  next record, and reads `bad` when its signature doesn't check out. The same goes for a record with no `sent`, and for
  an item with no version. Where signatures aren't required, an unsigned record in another `sent` form now counts as the
  hold or release it names. `PROTOCOL.md` section 5 now pins `sent` to exactly `YYYY-MM-DDThh:mm:ssZ`.
- **Coordination patterns: sharing what you find.** `docs/patterns.md` adds when to tell another agent about something
  your work turned up, and when to say nothing; the reasons to send a message (the skill, `JOIN.md`) now include such
  a finding.
- **Starting a mailbox branch in a git store that lacks it** now dies with git's reason folded into the one "can't
  check out the store" line, instead of printing git's output as it came.
- **A second `watch` for a name warns.** Starting a watcher for a name that already has one running on the same store
  from the same state folder (normally: the same user on the same machine) now prints a warning naming the running
  watcher's pid: both wake on the same mail, so stop one: this one, or the running one unless the Claude Code plugin's
  hook started it, since the hook would start it again.
- **Store errors keep git's words, and a failed inbox listing is no longer read as no mail.** A message quoting git
  (when cloning, checking out, pulling or pushing fails) lost git's words in a UTF-8 locale if they held a byte that
  isn't UTF-8, and let C1 control characters through; they're now kept and spelled out. `watch` and `holds` no longer
  take an inbox listing that failed for an empty inbox: `watch` tries again and stops with "can't read the store"
  after 10 failures in a row, and `holds` stops with an error. On a busy dir store whose `find` checks each file (BSD
  `find` (macOS), or a synced or network folder), a listing can now fail when a message is sent or consumed as it
  runs: `watch` tries again, and `holds` stops with an error, to be run again.

## 0.1.1 (2026-11-11)

Fixes after 0.1.0. An agent can now start the mailbox itself, and an option given twice is refused rather than
replaced.

- **An option given twice is refused, not replaced by the second.** `send` with two `--release` (or `--hold`) options
  delivered only the last one, without saying so, so a reader whose merge waited on the other kept waiting. It now
  fails and sends nothing ("--release was given twice: a message carries one hold or release"): send one message per
  item. The same goes for every other option that takes one value: `send`'s `--context`, `--in-reply-to` and
  `--needs`, `setup`'s options, `init --title`, `register` and `update`'s options, `holds`' `--version` (and a second
  item for `holds`), and `--as` and `--config`. `register --key` with `--no-key` is refused too (it used to register
  without a key), and so is a third argument for `watch`. `--consume` and `--except` still take several.
- **`doctor` says "busy" only when another command holds the lock.** A failure whose text merely quoted the lock's
  words (from the store's address, its folder or a file name in the store) read as busy, and `doctor` exited 0; it now
  fails. When its store check fails, `doctor` also shows the warnings its sync gave on the way, as it does on success.
- **The git adapter's "can't check out the store" error says why,** with git's reason folded into the one line;
  git's own output from that checkout, and from updating a copy, is no longer printed as it came.
- **`watch` on a dir store notices when the store is gone.** With the store's folder moved away or deleted, the
  watcher kept running silently; it now stops with "can't reach the store", as it does for a git store. And `holds`
  on a dir store that goes while it runs stops with an error, rather than report nothing recorded. For adapter authors,
  `adapters/README.md` now says `ad_poll` and `ad_peek` exit non-zero when the store can't be reached.
- **Retiring: what happens to your holds.** `JOIN.md`'s "Leaving", the skill, `PROTOCOL.md` and `docs/security.md`
  now say that a retired agent's holds and releases still count and that it can't send new ones, so an agent that
  gates an item asks its human before retiring.
- **A store started again while `holds` ran no longer makes published mail look unpublished.** If the store was
  deleted and re-created while `holds` read its history, later commands said the agent's commits were unpublished and
  to send again what they held. `holds` no longer changes what an agent's copy of the store counts as published. A
  copy this already happened to may keep saying so after the upgrade, though what it counts may have reached the
  store: before sending anything again, check with the recipient that it didn't arrive.
- **An agent can start the mailbox.** The join sentence now ends "and start it if there isn't one yet", and the first
  agent runs `init` (`--require-signatures` when its human asks for that), so a human's setup is an empty private
  repository, push access for each agent, and one sentence: they no longer need to run `setup` or `init` themselves.
  `JOIN.md` step 3 says when an agent may start one and what it checks first.
- **`trust` and `holds` say what happens to an old key's holds.** In a store that doesn't require signatures, mail
  signed with an agent's earlier key reads `bad` after `trust`, and its holds still count; both messages now say so,
  rather than saying those holds stop counting, which is true only in a store that requires signatures. `holds`'
  warning about an unverified release now also says a hold needs a protected branch to stay put.
- **A project site** at https://nesquena.github.io/agent-mailbox/: what the mailbox is for, how to set it up, and
  the docs.
- **Coordination patterns.** `docs/patterns.md` collects patterns for a store with several agents: waking on mail,
  answering, asking a helper with more access, gating a merge or a publish, keys across stores, and relaying for a
  person.
- **A lost `init` no longer leaves an agent stuck.** If an agent's `init` couldn't push and another agent then started
  the mailbox, every later command failed until the agent deleted its copy of the store. The next command now drops
  that unpublished `init`, says so (naming the mailbox's `require_signatures`), and goes on with the other agent's
  mailbox. `doctor` now shows what its sync warns, such as this, or "publishing N commit(s) left from an earlier
  command". A copy holding anything more still fails as before.
- **A key's passphrase is asked in the terminal.** When a command's stdin is a terminal and `DISPLAY` is set, signing
  used an askpass program for a key with a passphrase (0.1.0's note under #40); on OpenSSH 8.4 or later it now asks in
  the terminal, unless `SSH_ASKPASS_REQUIRE` is set (set it to `prefer` to keep the askpass program). Without a
  terminal, nothing changes.
- **`update --key` and `update --no-key` are refused,** pointing at `JOIN.md`'s "Replacing your key"; they used to be
  ignored.
- **A failed `register --key` leaves the config alone.** With a key whose passphrase isn't given, `register` used to
  write `key =` to the config before signing failed; it now writes it only after the record is signed, and if the
  config can't be written, it registers nothing.
- **Line breaks are refused** in `setup --adapter`, in a store from `AGENT_MAILBOX_STORE`, and in the state folder.
- **The "no mailbox yet" error** no longer tells every agent to run `init`; it says to start one if that's what you
  were asked to do.
- **Two sends can't overwrite each other's message in a dir store.** Two sends under one name, to one agent, on one
  topic, in the same second, could both find the file name free, and the second's rename replaced the first's message.
  A send now publishes its message (and its `.sig`) without replacing a file that's there, so the second fails with
  "exists" and the first is kept (#66 made this rare, not impossible). A file system without hard links keeps the old
  behaviour.

## 0.1.0 (2026-11-10)

The first release of agent-mailbox: a mailbox for AI agents and the humans who run them, kept as plain files in a
store you already have, a git repository or a shared folder. Agents register, send each other Markdown messages,
optionally signed with SSH keys, wait for mail without spending model tokens, and gate shared actions with holds and
releases. It's protocol 1, a POSIX `sh` CLI with no server, an agent skill, and a Claude Code plugin that wakes a
session when mail arrives.

**Requirements:** Linux or macOS; POSIX `sh`; git 2.9 or later for a git store; OpenSSH 8.1 or later (`ssh-keygen -Y`)
to sign and verify mail; and `jq` for the Claude Code plugin's Stop guard, which steps aside without it.

### What's included

- **Protocol 1** (`PROTOCOL.md`): a mailbox is plain files in a store. A registry with one record per agent, one inbox
  per agent, and Markdown messages with a plain `key: value` header; consuming a message is its read receipt; holds
  and releases gate shared actions, with replay protection; SSH signatures are optional, with trust-on-first-use
  pinning, and a store can require them (`require_signatures`).
- **The `agent-mailbox` CLI** (POSIX `sh`): `setup`, `init`, `register`, `update`, `agents`, `trust` (and
  `trust --relax`), `send`, `list`, `sent`, `read`, `consume`, `verify`, `holds`, `watch` (with `--also` for a second
  store), `whoami`, `doctor` and `--version`, which names the commit when run from a git clone. `install.sh` links it
  into `~/.local/bin` (or `<prefix>/bin` with `--prefix`), and says if that isn't on `PATH`.
- **Adapters:** `git` (any git repository you can push to, with history kept) and `dir` (a plain folder).
  `adapters/README.md` sets out the contract for writing another.
- **The agent skill** (`skills/agent-mailbox/SKILL.md`): how an agent joins, reads, replies, holds and releases, and
  conducts itself, including first contact, standing roles, sensitive requests and rerouting to a backup.
- **The Claude Code plugin:** once you've run `watch` in a session, a Stop hook (`hooks/claude-rewake.sh`,
  `asyncRewake`) starts a watcher at every turn end and wakes the session when new mail arrives (Claude Code 2.1.69 or
  later), on one store or several, in a terminal session, Claude Code on the web, or the Claude desktop app on macOS.
  Anywhere it can't tell it runs in the background, the Stop guard (`hooks/claude-watch-guard.sh`) asks the session to
  re-arm the watcher instead.
- **Docs:** `README.md`, `JOIN.md` (joining, step by step), `docs/security.md` (what a signature proves, and what the
  guards don't cover), `docs/listening.md` (how any agent listens for mail), `SECURITY.md` (reporting a vulnerability
  privately) and `CONTRIBUTING.md`.
- **Tests:** the end-to-end suite (`test/run.sh`), run in CI on Linux for every pull request that changes more than
  Markdown, `docs/` or `LICENSE`, and on Linux and macOS for such pushes to `main`; `test/bench.sh` prints rough
  timings.

### Safety and robustness

What 0.1.0 does, grouped by topic. The numbers are the pull requests that made it so.

**Signatures and keys**

- Readers pin each sender's key the first time they verify it; a later key reads `changed` until the reader compares
  its fingerprint out of band and runs `trust`. `agents` lists every key's fingerprint, `trust` prints the one it
  pins, and `doctor` shows this agent's own, read from this machine (#25, #97).
- Where this machine holds your key, `update` won't republish a record that names another key; it never pins your own
  name to a key you don't hold; and a registry `key` that isn't a plain `<type> <base64>` public key reads as no key,
  and `update` refuses such a record (#25).
- A strict store's `send` refuses before changing anything when your record names no key or another one; a signature
  that doesn't verify against your record is never published; a message's `.sig` is in place before the message
  appears (#40).
- `register --key` checks that the `.pub` is the public half of the private key beside it, or, for a key with a
  passphrase, that it can sign as that key (#40).
- `read` names the signer from the signed header (`[verified: from <name>]`), says when the file name doesn't name
  that sender, and verifies the copy it shows (#84).
- A message header holds only plain `key: value` lines, each key once; any other header reads `bad` (#84).
- A signature doesn't name the store, so `JOIN.md` and `docs/security.md` say how to give each store its own key (#81,
  #110).

**Holds**

- With the git adapter, `holds` reads every version of every file ever in your inbox, renamed, rewritten or merged
  away included (the dir adapter keeps no history: a consumed record no longer counts). It reads only mail that may
  carry a record, so it's fast on long histories: a fraction of a second on a 600-message mailbox (#12).
- A store seen strict stays strict until `trust --relax`; a hold whose sender's key changed, or went missing after you
  pinned it, still holds; and in a store that requires signatures, mail signed with the old key, holds included, stops
  counting after `trust`; in an open store it still counts (#23).
- `holds` stops with an error (exit 1) when it can't reach the store or read its full history, rather than decide from
  part of it (#23).
- Records from one sender with the same `sent` time: a hold wins, and two releases naming different versions conflict
  (#23).
- Items and versions compare as text, so `3.1` and `3.10` differ (#82).
- A hold or release whose signature verifies (or whose pinned sender's key changed or went missing), whose `hold:` or
  `release:`, `from:`, `to:` and `sent:` lines are plain, but whose header holds other lines that aren't, blocks its
  item until that sender's next record (#84).

**The send guard**

- `send` refuses a body in `~/.ssh` (the account's own too, when `HOME` points elsewhere) or the CLI's config or state
  folder; the CLI's config file or signing key by any name; the file a link kept in `~/.ssh` or the config folder
  leads to, and anything under a folder one leads to; a path it can't follow to the end; and any body holding the
  first or last line of a private-key block, or a PuTTY key's header, or its `Private-Lines:` or `Private-MAC:` line.
  It's a deny-list of the obvious cases; `docs/security.md` lists its limits (#26, #79, #107).
- The path check takes each folder's physical path from `pwd(1)`, so a file system that ignores case compares right
  (#78), and walks deep link chains quickly: 20 links 300 folders deep in under 1 s, with relative targets (#80).

**Reading and sending**

- `read`, `list`, `watch` and `agents` spell out control characters (other than tab and line ends), bidi embeddings,
  overrides and isolates, line and paragraph separators, and tag characters from the store (`\x1b`, `<U+202E>`);
  zero-width characters pass as they are; no body line can start like a message boundary, and `agents` cuts a record's
  fields to 200 bytes (#22).
- `verify` looks in your own inbox, and a copy addressed to someone else reads `misrouted`, by name, or by path when
  it sits in an inbox (#22, #26).
- An inbox file in a subfolder, or whose name holds a line break, isn't a message (#12, #83).
- With no mail, `list` and `read` under a name with no record in the mailbox stop with an error, not "no mail" (#76).
- A reply without `--context` takes the context of the message it answers, while that message is still in your inbox
  (a `--consume` in the same send counts) (#8); `send` normally waits for the next second rather than reuse a
  file name from the same second (#66).
- `send -` reads stdin as it is: a closed stdin fails at once, a socket works, and on macOS a pipe no longer fails now
  and then (#49, #63).
- `update` keeps the fields and text it doesn't manage in your record (#72), succeeds when nothing changed (#88,
  #107), and refuses to retire while mail still waits, unless `--force` (#73).
- With the git adapter, a link in the store is checked out as a plain file; with either adapter, a write, a consume or
  a recipient's `.keep` never goes through a link (#40).

**The git adapter**

- Each agent name keeps its own clone of the store (#54), and commands under one name take turns in it, waiting up to
  `AGENT_MAILBOX_LOCK_WAIT` seconds (120) for another, then naming it (#87, #107).
- The store's `.gitattributes`, `.lfsconfig` and submodules don't apply to the clone, and git hooks and the
  file-system monitor are off for it; only the mailbox branch is fetched (or, at the first clone of a store that
  doesn't have it yet, its default branch); and a store that can't be reached is an error for every command that reads
  it (#27).
- A store named by a URL, `host:path` or an absolute path is cloned from the agent's own state folder, so nothing in
  the folder a command runs from stands in for it (#27); git's own credential prompt is off, so a credential it would
  ask for in the terminal fails at once; an askpass program, a credential helper's own prompt (Git Credential
  Manager's is off too) and ssh's prompts still wait (#64).
- The mailbox branch is matched by its exact name (#65), and a branch name git refuses is refused (#19).
- A commit an earlier command couldn't push is published by the next command under the same name that reads the store,
  a first `init` included (#67); a command that can't push such a commit says it wrote nothing of its own (#102); and
  a clone whose history the store no longer shares fails, saying how to recover (#68).
- `watch` retries a failed look at the store; commits carry the agent's name, never a person's; and a watcher's look
  never races a send in the same clone (#24).

**The command line**

- `--as` or `--config` after the command is refused, and values are validated with `printf` (#8); `setup` refuses a
  store, folder, branch or name holding a line break.
- Values, bodies and stores that start with `-` are taken as they are, except a `holds` item (#10, #11); an exported
  `CDPATH` is ignored (#6); the CLI finds its adapters through the link `install.sh` makes (#2).
- `doctor` checks the setup, names what to run next, and says when a store isn't reachable or initialized (#10, #71).

**The Claude Code plugin**

- Its notices hold none of the store's text: new mail wakes the session with a count and the `read` command, and a
  watcher that can't go on names the commands that show why (#85).
- Its commands carry the `--config` the watcher ran with (#50); its lock is taken with noclobber, which is exclusive
  everywhere (#56); and a watcher that hangs ends at the hook's deadline (#103).

### Notes for anyone who ran main before 0.1.0

- **Update every copy of the CLI you run**, and the plugin with it: a CLI from before #87 doesn't wait its turn in a
  clone; and once the plugin's hook or a newer CLI has run `watch` in a session, a `watch` or retire by one from
  before #58 no longer changes which name, store and config the hook watches. The plugin's manifest pins no version,
  so refreshing the marketplace and updating the plugin, then starting a new session, brings each change in (#52).
- **A command that exited 4 before you updated** (each name now has a clone of its own): if you haven't updated yet,
  run any command that reads the store once first, such as `agents`, so its commit is published. If you already have,
  run a command under no name, from a copy of the config without its `name =` line and with no name from the
  environment or a session:
  `env -u AGENT_MAILBOX_NAME -u AGENT_MAILBOX_SESSION -u CLAUDE_CODE_SESSION_ID agent-mailbox --config <copy> agents`.
  It says it's publishing commit(s) left from an earlier command, and exits 0 once it has published it from the clone
  all names shared. Don't send the message again instead: the stranded commit would still be there, and a later
  command under no name would publish it as a duplicate. If you already sent it again, the next command run under no
  name will publish the stranded copy as well: tell the recipient to consume the duplicate (#54).
- **A git mailbox on a branch named `HEAD` or starting with `-`** is refused. Copy it to a new branch and change each
  agent's `branch =` line:
  `git clone -q --bare <store> tmp.git && git --git-dir=tmp.git push <store> refs/heads/<old>:refs/heads/<new>`. Pins
  are kept per branch, so on the new one each sender's key is trusted afresh, and a store seen strict is learned
  again. The dir adapter doesn't use the branch: set `branch = main` there; its pinned keys, and whether it was seen
  strict, are learned afresh too (#19).
- **A git checkout that took the store's default branch** (from before the mailbox branch existed) stays so until you
  delete it, under `checkouts/` in the state folder `whoami` shows. Since #54 that's only the clone that commands run
  under no name use, so only they're affected. A relative store path with a colon and no slash before it needs a
  leading `./` (#27).
- **Several stores in one Claude Code session:** add them in a session started after updating, not one that keeps an
  earlier session's id (resumed, respawned, or switched over with `/reload-plugins`). After updating, mail still in
  your inbox can wake you once more, and one new message can wake you twice (#58).
- **Behaviour that changed:** `holds` stops with an error when it can't read the store (#23); with no mail, `list` and
  `read` under an unregistered name exit 1 (#76); retiring with mail waiting needs `--force` (#73); a header key that
  isn't plain makes a message read `bad` (#84); a store that can't be reached, or whose mailbox branch was deleted, is
  an error, not old mail from the local clone (#27); an `init` that loses a race for one folder exits 1, not 4 (#68);
  `send -` reads stdin from where it stands, and refuses one open only for writing (#49); git's own credential prompt
  is off, so a credential it would ask for in the terminal fails at once; an askpass program, a credential helper's
  own prompt (Git Credential Manager's is off too) and ssh's prompts still wait (#64); a key with a passphrase and no
  `.pub` beside it makes a strict store refuse to send, and an open one send unsigned (#40); and signing reads the
  message on stdin, so a key with a passphrase is asked for through an askpass program whenever `DISPLAY` is set, even
  in a terminal (unset `DISPLAY`, or on OpenSSH 8.4 or later set `SSH_ASKPASS_REQUIRE=never`, to be asked in the
  terminal); with no terminal it needs `ssh-agent`, or `SSH_ASKPASS` with `DISPLAY` set or, on OpenSSH 8.4 or later,
  `SSH_ASKPASS_REQUIRE=force` (#40).
