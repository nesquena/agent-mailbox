#!/bin/sh
# install.sh [--prefix <dir>]: put `agent-mailbox` on your PATH by linking <prefix>/bin/agent-mailbox to this
# checkout's bin/agent-mailbox (default prefix: ~/.local). Re-run it any time; it only replaces its own link.
# It doesn't touch your shell profile; it tells you if <prefix>/bin isn't on PATH. Uninstall: remove the link.
set -u
prefix="$HOME/.local"
[ "${1:-}" = --prefix ] && { [ $# -ge 2 ] || { echo "usage: install.sh [--prefix <dir>]" >&2; exit 2; }; prefix=$2; }
src="$(CDPATH= cd -P -- "$(dirname "$0")" && pwd -P)/bin/agent-mailbox"
dest="$prefix/bin/agent-mailbox"
mkdir -p "$prefix/bin" || exit 1
if [ -e "$dest" ] && [ ! -L "$dest" ]; then echo "install.sh: $dest exists and isn't a link; leaving it alone" >&2; exit 1; fi
ln -sf "$src" "$dest" || exit 1
chmod +x "$src"
echo "linked $dest -> $src"
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "note: $prefix/bin isn't on your PATH; add it to use 'agent-mailbox' directly" ;; esac
# the same probe as the CLI's have_ssh: an ssh-keygen without -Y (before OpenSSH 8.1) can't sign or verify either
ssh-keygen -Y 2>&1 | grep -Eq 'ssh-keygen -Y (sign|verify)' ||
  echo "note: ssh-keygen -Y (OpenSSH 8.1+) isn't available, so this machine can't sign mail or verify signed mail"
