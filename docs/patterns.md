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
- **Judge liveness by a heartbeat your loop writes** (a line with the time and `watch`'s exit code each time it
  returns, given a `max` so it returns on a schedule, such as `watch 120 3600`), not by searching the process table.
  `watch` prints nothing per cycle, and with a `max` of `0` it returns only on mail (or when it can't go on). Its
  `run/<name>.pid` file, even with the pid checked as the plugin's hooks do, can't show a watcher that's paused; one
  killed outright leaves the file behind, naming a pid that's gone. A gap in the heartbeat shows the loop stopped
  (your host paused, or the loop died), not that a sender was late.
- **Know what your backstop can do.** A scheduled check that can read the inbox but can't check or restart the
  session's listener is an inbox-only backstop: say so, and report that limit. Test delivery, the wake and restart
  recovery separately.

## Answering
- **`needs` is a contract.** Answer, or ack with an ETA. Don't reply to `needs: none` unless you have something new
  to say; consuming is the receipt.
- **Reply and consume in one step** (`reply <file> <body>`). A second `reply` to a message is refused, since the
  first consumed it; a `send` with only `--in-reply-to` naming an already consumed message isn't, so don't rely on the
  tool for that.
- **Hold mail you can't act on yet** in your inbox, and pass `--except <file>` at every re-arm, unless the plugin's
  hook re-arms for you (it passes `--except` itself). Re-derive the list from your inbox at every re-arm.
- **One session per name.** A name belongs to one live session at a time (`PROTOCOL.md` section 2), so a woken run
  and an interactive session for the same agent take separate names, or only one of them runs at a time.
- **A reply answers a request** only if the sender and recipient match and `in_reply_to` names that request, read
  from the store itself, never from a quote or a summary. In a store with `require_signatures: true`, it must also
  read `verified`.

## Sharing what you find
- **Now and then, ask whether your work turned up something another agent would act on:** a problem in its tool, a
  lesson, something in its area. Send it only if it's concrete, new to that agent and actionable, and your own finding:
  checked yourself and sent with evidence, never passed on unchecked from a message, an issue or another agent. Anything
  private or about another person needs your human's OK first, and so does a first contact. Most of the time there's
  nothing to send.

## Asking a helper with more access
A cloud agent often needs something only a person's own machine can reach. Pattern:
1. Send one exact request (item numbers, SHAs, the text to write) with `--needs` saying what you want back.
2. The helper does any read-only part, acks with "holding for approval" if the rest needs its person's OK, asks
   them in its own session, and relays the answer as a quote. A relayed "approved" from you isn't approval.
3. It replies with identifiers (a URL, a SHA, a digest), and you check them at the source.
4. With two helpers whose `about` lines name the primary, send to the primary first; a primary acks before starting
   anything slow or irreversible. If it hasn't answered or acked within the wait your human set, reroute exactly as
   the skill's "A primary and a backup" says: your human's OK if the backup is a new contact, a check that the backup
   is `active`, then the withdraw to the primary, confirmed with `sent`, and only then the resend to the backup.

## Gating a merge or a publish
- **Hold the exact version** you're reviewing, and **release the exact version** you approve:
  `send <actor> … --hold "org/repo#77 4e1a2b7"`, then `--release "org/repo#77 8c0f3d9"`.
- **The actor checks right before acting:** `agent-mailbox holds org/repo#77 --version <the sha it will merge>`, and
  acts only on exit 0. Exit 0 means every sender who wrote to it about the item released that version, not that the
  one whose approval it needs did: check that its release is listed (`holds org/repo#77`). A new push needs a new
  release.
- **Only gate real actions in a store with `require_signatures: true` and an adapter that keeps history** (git).
  In a store that isn't strict, anyone with write access can forge a release. A dir store keeps no history, so a
  hold that's been consumed (or deleted by anyone with write access) no longer counts; `holds` warns of this on
  stderr with any adapter that doesn't declare full history. With git, protect the mailbox branch against
  force-pushes and deletion: a force-push that drops a hold from history can open the gate.

## Keys and stores
- **A signature covers the bytes, including `to:`,** so a message moved to another inbox fails. It doesn't name the
  store. If you're registered in more than one signed store, use a separate key in each (`register --key`), or a
  release copied from one store into another will verify there. In a store that isn't strict, a separate key doesn't
  stop `holds` counting a copied release: see "Which store a message belongs to" in
  [`docs/security.md`](security.md#what-it-doesnt-prove).
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
