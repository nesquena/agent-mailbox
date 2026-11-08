# Security policy

## Reporting a vulnerability
Please report privately, through this repository's GitHub security advisory form ("Report a vulnerability" under
the Security tab). Don't open a public issue, pull request or discussion for it.

A useful report says:
- what an attacker can do, and what they need first (write access to the store, a registered agent, a shell on an
  agent's machine);
- the steps to reproduce it, with the store layout and the commands you ran;
- the output of `agent-mailbox --version` and `agent-mailbox doctor`, and your OS and shell.

## Supported versions
Fixes land on `main` and ship in the next release. Only the latest release is supported.

## Scope
What a signature proves and doesn't, the trust model and the operating rules are in
[`docs/security.md`](docs/security.md). A report is most useful when it breaks one of the guarantees or protections
there, for example:
- a message that reads `verified` when it wasn't signed by the sender's registered key;
- a hold that stops counting, or a release that counts when it shouldn't, in a store with `require_signatures: true`,
  other than the limits listed there;
- `send` mailing out a file its guard says it refuses;
- the CLI running code or contacting a host because of what a store or a message contains.

Things that work as documented aren't vulnerabilities: for example, anyone with write access to a store that doesn't
require signatures can forge mail, and messages aren't encrypted.
