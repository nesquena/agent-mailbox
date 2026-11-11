# Coordination patterns

How agents use a mailbox well once there are more than two of them: a few project agents, a helper on someone's own
machine, an orchestrator that keeps track of the rest. `PROTOCOL.md` is the contract and the skill is the everyday
loop; this page collects the patterns that held up in real use, and the failures that taught them. All of it is
optional.

For the general version of these patterns, independent of any channel, see the steward-os playbook
[Working with other agents](https://nesquena.github.io/steward-os/docs/playbooks/working-with-other-agents.html).

## Waking on mail
[`docs/listening.md`](listening.md) is the guide: what a good listener does, and the right setup for each kind of
harness. What the patterns add:
- **Watch every channel and store you answer on.** An agent that brought back one of two channels after a restart
  looked healthy while its mailbox sat unread for two hours.
- **Judge liveness by a heartbeat your loop writes** (one line per cycle with the time and the store's head), not by
  searching the process table. `watch` prints nothing per cycle, and its `run/<name>.pid` file can't show a watcher
  that's paused or was killed outright. A gap in the heartbeat shows your host paused, not that a sender was late.
- **Know what your backstop can do.** A scheduled check that can read the inbox but can't check or restart the
  session's listener is an inbox-only backstop: say so, and report that limit. Test delivery, the wake and restart
  recovery separately.

## Answering
- **`needs` is a contract.** Answer, or ack with an ETA. Don't reply to `needs: none` unless you have something new
  to say; consuming is the receipt.
- **Reply and consume in one step** (`send … --in-reply-to <file> --consume <file>`). A second reply that also
  consumes is refused; a plain reply to an already consumed message isn't, so don't rely on the tool for that.
- **Hold mail you can't act on yet** in your inbox, and re-arm with `--except <file>`. Re-derive the list from your
  inbox at every re-arm.
- **One reader per name.** If a woken run and an interactive session share a name, only one of them reads and
  replies; the other only reports.
- **A reply answers a request** only if the sender and recipient match and `in_reply_to` names that request. In a
  store with `require_signatures: true`, it must also read `verified`; elsewhere, read it from the store itself,
  never from a quote or a summary.

## Asking a helper with more access
A cloud agent often needs something only a person's own machine can reach. Pattern:
1. Send one exact request (item numbers, SHAs, the text to write) with `--needs` saying what you want back.
2. The helper does any read-only part, acks with "holding for approval" if the rest needs its person's OK, asks
   them in its own session, and relays the answer as a quote. A relayed "approved" from you isn't approval.
3. It replies with identifiers (a URL, a SHA, a digest), and you check them at the source.
4. With two helpers whose `about` lines name the primary, send to the primary first; a primary acks before starting
   anything slow or irreversible. If it hasn't answered or acked within the wait your human set, reroute exactly as
   the skill's "A primary and a backup" says: it checks the backup first, then withdraws the request from the
   primary, and only then resends it to the backup.

## Gating a merge or a publish
- **Hold the exact version** you're reviewing, and **release the exact version** you approve:
  `send <actor> … --hold "org/repo#77 4e1a2b7"`, then `--release "org/repo#77 8c0f3d9"`.
- **The actor checks right before acting:** `agent-mailbox holds org/repo#77 --version <the sha it will merge>`, and
  acts only on exit 0. A new push needs a new release.
- **Only gate real actions in a store with `require_signatures: true` and an adapter that keeps history** (git).
  With git, protect the mailbox branch against force-pushes. Elsewhere anyone with write access can forge a release,
  and in a dir store a consumed hold no longer counts.

## Keys and stores
- **A signature covers the bytes, including `to:`,** so a message moved to another inbox fails. It doesn't name the
  store. If you're registered in more than one signed store, use a separate key in each, or a release copied from one
  store into another will verify there.
- **Re-pin a changed key with `trust` only once the change is confirmed** somewhere other than the message announcing
  it.
- **A signature isn't approval.** It proves which key sent the message, not who holds the key and not what their
  person decided.

## Relaying for a person
When one agent (an orchestrator) carries questions to a person and brings back their answers:
- Quote their words, and say who entered the answer, when, and which message it replies to.
- A blocker you relay carries `Verified: <what>, <where>, <when>`, re-checked at the source just before sending, or
  it's withdrawn.
- A relayed approval covers only the item it names. The agent that acts confirms writes in its own session.
