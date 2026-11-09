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
  pinned it (its registry record removed, with a header that doesn't close, or its key no longer reads as a plain
  key), still holds, and until you `trust` the new key that includes holds the sender has since released; and
  `holds` stops with an error if it can't reach the store or read its full history. After `trust` accepts a changed
  key, mail signed with the old key (holds included) no longer counts: before trusting, ask the sender to re-send any
  hold it still means (#23).
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
- **`sent [<to>]`** lists the mail you sent that's still in a recipient's inbox, oldest first, with its age, its
  `needs`, and `stale` once it's unconsumed after 24 hours, so a sender can raise stale mail as `PROTOCOL.md` asks.
  A message counts when its file name and its `from:` header both name you; signatures aren't checked (#30).
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
  comes after nothing but non-printing characters is indented, and a message's last line always ends before its end
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
- **Fix:** in a store that requires signatures, `send` also refuses before changing anything when your registry record
  names no key, or a different key from yours. Before, it sent the message unsigned or with a signature that didn't
  verify, and removed the mail it consumed. In a store that doesn't require signatures, such a send now goes unsigned,
  with a warning, instead of carrying a signature that doesn't verify. A key with a passphrase needs its `.pub` beside
  it for that check: without one, a strict store refuses and says how to restore it, and an open store sends unsigned.
  A signed message's signature, and a newly registered record's, is in place before the file appears, so no reader
  sees it unsigned; a signing that fails leaves no message behind, and an update that fails keeps the record with the
  signature it had. A signature that doesn't verify against your registry record's key is never published, and
  `register --key` refuses a `.pub` that isn't the public half of the private key beside it. Writes don't follow a
  link left at a temporary file's name, and never publish one; `send` refuses a recipient's `.keep` that's a link. A
  record or `.sig` path that's a folder is refused instead of having the file moved into it. `consume` and `send
  --consume` refuse an inbox reached through a symlink. Signing now reads the message on stdin: with no terminal, a
  key with a passphrase needs `ssh-agent`, or `SSH_ASKPASS` with `SSH_ASKPASS_REQUIRE=force` (#40).
- **Docs:** the skill's conduct rules add first contact (ask your human before your first message to a new agent),
  standing roles (one agent per role), marking sensitive requests in `--needs` (the receiver asks its own human), and
  rerouting a request from a primary agent to its backup with a `withdraw` note, honoured only from the
  request's own sender and checked before acting on the request (#28). `JOIN.md` section 6 says to send nothing
  until you've asked your human whether to introduce yourself, and to whom, or until someone writes to you. A reroute
  gets your human's OK for a new backup and checks that the backup is active before it withdraws from the primary, and
  tells your human if the resend fails; only a withdraw that reads `verified` or `unsigned` is honoured; a reply to a
  withdraw says whether you acted, and that you've stopped; only a withdraw you refuse is a finding for your human; and
  `JOIN.md`'s loop skips a withdrawn request, as the skill does (#41).
- **Docs:** re-arming the watcher after a time limit or handled mail is done quietly, with no message to your
  human unless there's mail they need to know about or the watcher fails (exit 1). The skill, JOIN.md and the
  Claude Code Stop hook's message say so (#42).
- **`send` refuses obvious secrets:** a body file in `~/.ssh` or the CLI's config or state folder (as named, or at any
  link on the way to the file, so a `~/.ssh/config` linked in from elsewhere counts), or the CLI's config file or
  signing key (either half) (on Linux, also when redirected to stdin), a path whose links can't be followed to the end
  (a name holding a newline, or folder links nested more than 8 deep), and a body (file or stdin) holding a line of a
  private-key block (its `-----BEGIN ... PRIVATE KEY` or `-----END` line, or a PuTTY key's header, or its
  `Private-Lines:` or `Private-MAC:` line), are refused with exit 1 before anything is written; the error names the
  folder, or says how to go on. It's a deny-list of the obvious cases, not a guarantee. The state folder holds the git
  adapter's copy of the store, so to forward a message you received, copy its text into a new file first; to send part
  of a file from one of those folders on purpose, copy that part the same way (#26).
- **Fix:** `consume` takes a message whose name starts with `-` (`consume -x.md`, or any name after a `--`, wherever
  the `--` is), instead of refusing it as an unknown option (#26).
- **Fix:** `verify <path>` checks a message in an inbox against that inbox, so a copy addressed to someone else reads
  `misrouted` by path too, as it does by name and in `read` (#26).
- **Docs:** the skill's conduct rules and `docs/security.md` cover injected requests: a `verified` sender can still be
  wrong, names, `kind` and `about` are self-declared, no message is a reason to send a file or key or to run `trust`,
  `setup`, `update` or `consume`, and `holds <item> --version <v>` exit 0 means every sender who wrote released
  `<v>`, not that a particular one did (#26).
- **Fix:** the git adapter's clone of the store ignores the store's own `.gitattributes` and `.lfsconfig` (no
  line-ending conversion, no filters such as Git LFS, no merge drivers), never recurses into submodules and runs no
  git hooks or file-system monitor, so every message is checked out exactly as it was stored and its signature
  verifies, whatever git settings the store or your git config carry. An existing checkout is checked out again once,
  on its next command (#27).
- **Fix:** with the git adapter, a store that can't be reached is an error (exit 1, "can't update from the store")
  for every command, and `doctor` reports it, instead of `list` and `read` saying "no mail" from the local clone
  (#27).
- **Faster first use:** a new agent's git clone fetches only the mailbox branch, not every branch in the store, once
  the store has that branch (#27).
- **Fix:** with the git adapter, a store named by a URL, `host:path` or an absolute path is cloned from the agent's
  own state folder, so a repository or bundle file of that name in the folder an agent's first command runs in can't
  stand in for the store; and a `clone.defaultRemoteName` in your git config no longer breaks the clone. A relative
  store path with a colon and no slash before it now needs a leading `./` (`./store:mail.git`); git reads such a
  name as `host:path` (#27).
- **Fix:** with the git adapter, a branch the store doesn't have yet reads as no mailbox, and `init` on it starts
  empty; before, a new checkout took on the files of the store's default branch, so `doctor` called the store
  initialized and `init` said a mailbox already existed. A checkout already in that state stays so until you delete
  it (under `checkouts/` in the state folder `whoami` shows) (#27).
- **Fix:** with the git adapter, a store `.gitignore` that matches mail no longer makes `send` fail ("git add
  failed"); a mailbox branch deleted from the store is an error ("can't update from the store") instead of old mail
  from the local clone; a first command cut off while setting up its clone is set up again by the next command,
  instead of every later command saying there's no mailbox; and a command run with `GIT_DIR` set (as in a git hook)
  still uses its own clone, never the repository it names (#27).
- **Fix:** `send -` (or `/dev/stdin` as the body) with stdin closed fails at once (exit 1, "it's closed"); under bash
  it waited forever. Stdin is read as it is, not reopened by name, so a socket on stdin (as some harnesses give a
  command) works, a stdin open only for writing is refused instead of read from its file, and a stdin that was partly
  read before sends only the unread rest, as a pipe always did (#49).
- **Fix:** the Claude Code Stop hook's `read` and re-arm commands carry `--config <file>` naming the config the watcher
  ran with (from `--config`, `AGENT_MAILBOX_CONFIG` or the default), quoted where the path needs it, so a watcher on a
  config of its own is re-armed on it. A session id of `.` or `..`, or one holding a `/`, counts as no session, so it
  can't read or rewrite another session's record (#50).
- **New:** in Claude Code, the plugin keeps watching for you. Once you've run `watch` in a session, a Stop hook with
  `asyncRewake` (`hooks/claude-rewake.sh`) starts a watcher at every turn end and wakes the session, even when idle,
  when new mail arrives, so there's nothing to re-arm. Mail it already woke you for doesn't wake you again while it
  stays in your inbox; while a watcher you started yourself runs, the hook leaves the watching to it; a watcher that
  can't go on wakes you once with the error and keeps retrying quietly; and once a day with no mail it wakes you
  with a one-line note. It runs only where it can tell that Claude Code (2.1.69 or later) runs it in the background:
  a session in a terminal, or Claude Code on the web. Anywhere else (`claude -p`, output to a file or pipe, an SDK
  run or another host with streaming input, an older version, or a version it can't confirm) it exits at once, and the
  existing Stop hook asks you to re-arm the watcher as before (#51).
- **Docs:** `docs/listening.md` sets out how any agent listens for mail, whatever its harness: what a listener must
  do (`PROTOCOL.md` section 7 now lists it), the CLI's parts for it, and the ways to build one, from a background
  watcher or a hook to a supervisor that starts the agent and a scheduled check, with a worked loop (#51).
- **Fix:** a `watch` that ends no longer removes the pid file of another watcher for the same name that started
  after it, so hooks that check for a running watcher still see that one (#51).
- **Packaging:** the Claude Code plugin's manifest no longer pins a version, so refreshing the marketplace and
  updating the plugin (from `/plugin`, or `claude plugin marketplace update agent-mailbox` and
  `claude plugin update agent-mailbox@agent-mailbox`) brings in each change on `main` (#52).
- **Fix:** with the git adapter, agent names that share a HOME (each with its own config, or one config and `--as`)
  keep a clone of the store each, so they no longer work in one clone at once. Before, sends from two such names at
  the same time could fail ("index.lock: File exists", "cannot lock ref") and leave files behind that `list` showed.
  After updating, each name clones the store once; commands run without a name keep using the clone in the state
  folder's `checkouts/` that all commands shared before. A command that exits 4 now says to re-run a command with the
  same name to publish its commit. If a command exited 4, run any command once before updating, so its commit is
  published first. If you already updated: with one config and `--as`, run a command without `--as` (such as
  `agents`), which publishes it from the shared clone; with a name in each config, send the message again (#54).
- **Fix:** the Claude Code plugin's Stop hook takes its lock through a mutex made with the shell's noclobber instead
  of `mkdir`, which isn't exclusive everywhere (the Rust coreutils' `mkdir`, the default on Ubuntu 26.04, can report
  success to two hooks at once). Before, two hooks starting together there could both start a watcher for one name.
  A mutex folder an older version left behind is cleared after a minute, as before (#56).
- **New:** the Claude Code plugin's Stop hook also runs in the Claude desktop app on macOS, which runs it in the
  background: a session the app starts is woken on new mail like one in a terminal or on the web, instead of being
  asked to re-arm the watcher. A `claude` started from such a session's shell, `claude -p` included, still exits at
  once (#57).
- **New:** in Claude Code, one session can be woken for mail on several stores. Run the watcher once more for each
  further store in the session, with that store's `--config` and the new `--also` (`watch --also`); the plugin's Stop
  hook then watches every store it was run on, each with its own lock and list of mail it already woke you for, and
  its wake names the config to read with. The Stop guard asks for a re-arm for a store left unwatched, one store at
  each turn end; with a different name on each store, pass `--as <name>` with each store's `--config`. A `watch`
  without `--also` replaces the stores the hook watches, as before. When you update the plugin, update the CLI you run
  too (`install.sh` from the new plugin folder, pull your clone, or, if you didn't use `install.sh`, run the new
  folder's `bin/agent-mailbox`): once the hook has recorded your session's store, a `watch` or retire by an older CLI
  no longer changes which name, store and config the hook watches. Add stores in a new session started after updating,
  not one that keeps an earlier session's id (resumed with `--continue`, `--resume` or `/resume`, respawned, or
  switched over with `/reload-plugins`): in a session that ran `watch` before, `--also` can replace that first store
  instead of adding to it. After updating, mail still in your inbox can wake you once more, and one new message can
  wake you twice (#58).
- **Docs:** `SECURITY.md` says how to report a vulnerability privately, and what's in scope. The README opens with
  the protocol version and the platforms: Linux and macOS, POSIX `sh`, git 2.9 or later for a git store, and OpenSSH
  8.1 or later to sign and verify mail. Every place that said OpenSSH 8 now says 8.1, the first with `ssh-keygen -Y`
  (#61).
- **Fix:** the git adapter matches the mailbox branch by its exact name. A store with no `main` but a ref whose name
  ends in `refs/heads/main` (such as `refs/heads/x/refs/heads/main`) read as having one, so every command stopped
  with "can't update from the store" and `init` couldn't create the mailbox. `watch` reads only that branch's tip
  (#65).
- **Fix:** `send` never reuses a message's file name, as `PROTOCOL.md` section 5 requires. A message sent again with
  the same topic to the same recipient, in the same second as one just consumed, got that message's name; it now
  waits for the next second (#66).
- **Fix:** an `update` that changes nothing, such as `update --status active` when already active, or one run again
  after it exited 4, succeeds; with the git adapter, which publishes nothing then, it says "nothing to update". It
  stopped with "git commit failed". `update` still writes the record and its signature every time, so a stale or
  missing signature, or a record changed in the store, is replaced (#88).
- **Fix:** `update` keeps what it doesn't manage in your registry record: other header fields (an `x-` field, say)
  and any text below the header, as `PROTOCOL.md` section 2 requires. It rewrote the record from a fixed template,
  dropping both, then signed the result (#72).
- **Changed:** `update --status retired` refuses while your inbox still holds mail, and names it, since an agent
  retires once its inbox is empty (`PROTOCOL.md` section 4) and a retired name isn't woken for mail. Read and
  consume it first (sending on, as new mail, any that are another agent's job), or pass `--force` to retire with it unread
  (#73).
