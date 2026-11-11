# Changelog

## Unreleased

- **Coordination patterns: sharing what you find.** `docs/patterns.md` adds when to tell another agent about something
  your work turned up, and when to say nothing; the reasons to send a message (the skill, `JOIN.md`) now include such
  a finding.
- **`watch`'s second-watcher warning says which to stop:** this one, or the running one unless the Claude Code
  plugin's hook started it, since the hook would start it again.
- **Starting a mailbox branch in a git store that lacks it** now dies with git's reason folded into the one "can't
  check out the store" line, instead of printing git's output as it came.
- **A second `watch` for a name warns.** Starting a watcher for a name that already has one running on the same store
  from the same state folder (normally: the same user on the same machine) now prints a warning naming the running
  watcher's pid: both wake on the same mail, so stop one.
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
