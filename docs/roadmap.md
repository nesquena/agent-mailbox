# Roadmap

What exists today is the protocol (`PROTOCOL.md`), the CLI, the git and directory adapters, the agent skill and
the Claude Code plugin. Everything below is planned, not built. Each item becomes an issue before work starts, so
contributors can claim it.

## Web UI and admin panel (Padrino)
A small [Padrino](https://padrinorb.com) application for the humans running a mailbox. It reads and writes the
same store, through the same protocol, so the CLI and the UI never disagree.

**For reviewing mail**
- Every inbox, with threads assembled from `in_reply_to` and grouped by `context`.
- The signature status of every message (`verified`, `unsigned`, `bad`, `changed`), with `bad` and `changed`
  surfaced prominently.
- Open `needs` and stale mail: unconsumed after 24 hours, or a `needs` with no reply.
- Holds and releases per item: who holds what, and at which version.
- Search across messages, and the full history of consumed mail where the adapter keeps it.

**For configuring agents**
- The registry as a table: kind, about, where each agent runs, how fast it watches, its key fingerprint, and when
  it was last active.
- Approving a newly registered agent, for stores that want approval before an agent can receive mail. This is
  planned as a `pending` status, and needs a protocol addition.
- Retiring an agent, and rotating or revoking its key. A revoked key's past mail stays readable, and is marked.
- Store settings: `require_signatures`, the title, and who administers the mailbox.

**For a human in the conversation**
- Sending and replying as a human agent, with `kind: human`, signed with the human's own key, so a person can join
  a thread the same way an agent does.

**Shape**
- A Padrino app in this repository, under `web/`. It reads the store through a Ruby implementation of the adapter
  contract (git first).
- It runs locally, or on a small server with its own checkout of the store. The store stays the single source of
  truth, and the app keeps no message database of its own.
- It verifies signatures with the same rules as the CLI (`ssh-keygen -Y`, or a Ruby library), and the shared test
  suite runs against both.
- Authentication for the admin panel comes from the host: a GitHub OAuth login, restricted to the people with
  access to the store.

## Protocol and CLI
- **Registry approvals:** a `pending` status, so a store can require an admin to approve a new agent.
- **Signed consumes:** a consume receipt that proves the recipient read the message, for stores that need one.
- **Stores beyond git** ([#7](https://github.com/nesquena/agent-mailbox/issues/7)): measure where git stops being
  enough, then decide what to add next. The order under discussion:
  1. an optional push "doorbell" (a webhook, say) that wakes watchers while git stays the source of truth; polling
     stays the baseline;
  2. a non-git store (a small service, or a broker that keeps history, such as NATS JetStream) only for a concrete
     need: sub-second exchanges at volume, hundreds of concurrent writers, or per-recipient confidentiality.
- **More adapters:**
  - an HTTP adapter that talks to the web UI's API;
  - a database adapter (SQLite or Postgres) for large mailboxes;
  - an MCP server, so agents without a shell can join.
- **Query-shaped adapters:** protocol version 2 may let an adapter answer "list this inbox" and "fetch this
  message" without mirroring the whole store.
- **Packaging:** a Homebrew formula, and published skill packages for other agent runtimes, as they settle on
  formats.

## Not planned
- **End-to-end encryption.** The store's access control is the boundary; see `docs/security.md`. A future version
  could add it per message if there's a concrete need.
- **Real-time chat.** This is mail, with latency measured in a poll interval, by design.
