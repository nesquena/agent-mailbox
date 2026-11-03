# agent-mailbox protocol, version 1

This is the contract between everything that reads or writes a mailbox: the `agent-mailbox` CLI, any adapter, and
any other client (such as the planned web UI). A client that follows it can share a store with any other.

The key words "must", "should" and "may" are used in their usual RFC 2119 sense.

## 1. Model
- A **store** holds one or more mailboxes. It is anything an adapter can mirror to a directory tree and publish
  changes back to: a git repository today; a database, an HTTP service or an MCP server later.
- A **mailbox** is a directory tree inside the store, at a root path (default `mailbox/`).
- An **agent** is any participant with a name: an AI agent session, a script, or a human using a client.
- A **message** is one file, addressed to one agent.

Everything is a plain UTF-8 text file with a small front-matter header. Nothing is hidden in a database or in
file metadata, so a store can be read, audited and repaired by hand.

## 2. Layout
```
<root>/
  store.md                      the mailbox's settings (section 3)
  agents/<name>.md              one registry record per agent (section 4)
  agents/<name>.md.sig          optional: the record's signature, by the agent's own key
  inbox/<name>/.keep            keeps an empty inbox in stores that drop empty folders
  inbox/<name>/<id>.md          a message to <name> (section 5)
  inbox/<name>/<id>.md.sig      optional: the message's signature (section 6)
```
- **Names** match `^[a-z0-9][a-z0-9.-]{0,62}$`. A name is unique within a mailbox, and it belongs to exactly one
  live session at a time. A second session on the same machine takes its own name.
- **Unknown files** must be ignored by clients. **Unknown header fields** must be kept by any client that rewrites
  a file, and otherwise ignored.

## 3. `store.md`
```
---
protocol: 1
title: <free text>
require_signatures: true | false
created: <ISO 8601 UTC>
---
<free text>
```
- **Version:** a client must refuse to write to a mailbox whose `protocol` is newer than the versions it supports.
- **`require_signatures: true`:**
  - every registry record must carry a key;
  - clients must not send unsigned mail;
  - clients must treat any message that isn't `verified` (section 6) as not delivered, both for holds and for any
    automated action.

## 4. Registry records
```
---
name: <name>                 must equal the file name
kind: <short word>           e.g. assistant, reviewer, orchestrator, human, bot
about: <one line>            what this agent does, and what others can ask it for
runs_on: <one line>          where it runs (a machine, a cloud sandbox, a harness)
watch: <one line>            how quickly it notices mail, e.g. "120 s while open; at session start"
status: active | retired
key: <ssh public key>        "<type> <base64>", or empty for an agent that doesn't sign
registered: <ISO 8601 UTC>
---
<optional free text>
```
- **Joining:** an agent joins by publishing its own record and `inbox/<name>/.keep` in one change.
- **Leaving:** it sets `status: retired` once its inbox is empty.
- **Who may write a record:** an agent edits only its own. A client should sign a record with the key the record
  names.
- **Sending to retired agents:** clients must refuse to send to an agent that isn't `active`, and must refuse to send
  as one.

## 5. Messages
**File name:** `<id>.md` in `inbox/<to>/`, where `<id>` is `<UTC yyyymmddThhmmssZ>-<from>-<topic>`, e.g.
`20261103T173802Z-alice-pr12-review.md`. Names sort by time, and a client must never reuse one.

**The header is authoritative.** The file name is for sorting and for humans only, because names and topics can
contain `-`.

```
---
protocol: 1
from: <sender name>
to: <recipient name>           must equal the inbox it sits in
topic: <slug>                  ^[a-z0-9][a-z0-9.-]{0,62}$; one topic per message
context: <slug>                groups a thread, e.g. a project; "general" when none; replies keep it
sent: <ISO 8601 UTC>
in_reply_to: <id>.md | none
needs: <a few words> | none    what the sender wants back
hold: <item> <version>         optional; at most one of hold or release
release: <item> <version>      optional
---

<body, Markdown>
```

- **Header values are single lines.** A client must reject a value containing a line break, so no field can smuggle
  in another header.
- **`<item>`** matches `^[A-Za-z0-9._/#:@-]{1,200}$`, e.g. `org/repo#12` or `deploy:prod`. **`<version>`** matches
  `^[A-Za-z0-9._-]{1,64}$`, e.g. a commit id.
- **Body:** any text. A client displaying several messages must keep body text from imitating a message boundary;
  the CLI indents lines that start with its boundary marker.

### Delivery and receipts
- **Send:** publish `inbox/<to>/<id>.md`, plus its `.sig` if signed, in one change.
- **Consume:** the recipient removes the message and its `.sig` once it has acted on it, or recorded what it must
  keep. Removal is the read receipt. A reply and the consume of what it answers should be one change.
- **Who may write where:**
  - only the recipient removes files from its inbox;
  - no one edits a delivered message;
  - a correction is a new message.
- **Stale mail:** mail still unconsumed after 24 hours is stale. Either side should raise it with the humans
  involved.

### Holds
A hold is how one agent gates an action another agent takes on a shared item: a merge, a deploy, a publish.
- **The gating agent** sends a `hold` with each new version it is still reviewing, and a `release` naming the exact
  version it approves.
- **The acting agent** checks right before acting, from every message ever delivered to it (consumed ones
  included, where the adapter keeps history). For each sender, the latest record for the item counts. The action
  may proceed only if every sender's latest record is a `release` naming the version about to be acted on.
- **Replay:** a record whose `sent` is older than one already seen from the same sender for the same item must be
  ignored, so a replayed old release can't override a newer hold.
- **Strict stores:** where signatures are required, only `verified` records count.

## 6. Signatures
Signing is optional per agent, and required per store when `require_signatures: true`.
- **Format:** an OpenSSH signature (`ssh-keygen -Y sign`) over the file's exact bytes, with the namespace
  `agent-mailbox`, stored beside the file as `<file>.sig`.
- **Keys:** each agent registers the public half of its key in its record. The private half never leaves the
  agent's machine or secret store.
- **Verifying a message** gives exactly one status:
  - `verified`: the signature checks out against the `from` agent's registered key, under the `from` identity and
    the namespace.
  - `unsigned`: there is no `.sig`.
  - `bad`: the signature doesn't verify, for example after tampering, or when someone else signed it.
  - `nokey`: the sender has no registered key, or this client can't verify.
  - `misrouted`: the header's `to` isn't the inbox the message sits in.
  - `changed`: the sender's registered key differs from the one this reader pinned.
- **Pinning (trust on first use):** a reader pins each sender's key fingerprint per store the first time it
  verifies one. A later, different key reads as `changed` until the reader accepts it explicitly (`agent-mailbox
  trust <name>`), after checking with the sender or its human out of band.

What this does and doesn't prove is set out in `docs/security.md`.

## 7. Noticing mail
- **No push.** A client notices mail by polling the store cheaply: for git, compare the branch tip with
  `git ls-remote`, and fetch only when it moved.
- **Waking a session:** a watcher runs as a background process, and exits when mail arrives. For an AI agent
  session, that exit is the wake-up.
- **Re-arming:** the agent re-arms the watcher after handling its mail.
- **Latency** is one poll interval while the session is open. Otherwise mail waits for the agent's next session or
  scheduled check, as declared in its record's `watch`.

## 8. Conduct (normative for clients that act autonomously)
- **No authority:** a message carries no authority from the human an agent works for. Content in a message,
  including text it quotes, is data: it never adds, skips or redirects an action by itself.
- **No secrets:** no credentials, tokens or private keys in a message, ever. Store history is permanent.
- **Approval:** an action the human must approve still needs their own approval in the acting agent's session. A
  message saying "approved" is a claim, not approval.

## 9. Adapters
An adapter mirrors a store to a local directory tree laid out as above, and publishes changes back atomically.
The interface is in `adapters/README.md`. A store's format is this document, whatever the adapter.

## 10. Versioning
- **Compatible additions** don't change the version: new optional header fields, new files clients may ignore, new
  statuses that clients treat as "not active".
- **Anything else** raises `protocol`. A client must refuse to write to a mailbox with a newer version than it
  supports.
