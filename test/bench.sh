#!/bin/sh
# test/bench.sh [messages=200] [senders=10]: rough timings of the git adapter against a throwaway local store, so the
# limits discussed in issue #7 (stores beyond git) stay measured, not guessed. Not part of the test suite.
# Prints one line per measurement. Times are wall-clock seconds from a local bare repository, so they show the
# CLI's own cost; a hosted store adds a network round trip (about 0.5 s on GitHub) per sync or push.
set -u
N="${1:-200}" C="${2:-10}"
case "$N$C" in ''|*[!0-9]*) echo "usage: test/bench.sh [messages] [senders]" >&2; exit 2 ;; esac
ROOTDIR=$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)
CLI="$ROOTDIR/bin/agent-mailbox"
unset XDG_CONFIG_HOME XDG_STATE_HOME AGENT_MAILBOX_CONFIG AGENT_MAILBOX_STATE AGENT_MAILBOX_NAME AGENT_MAILBOX_STORE \
  AGENT_MAILBOX_ADAPTER AGENT_MAILBOX_ROOT AGENT_MAILBOX_BRANCH AGENT_MAILBOX_KEY AGENT_MAILBOX_SESSION CLAUDE_CODE_SESSION_ID
W=$(mktemp -d "${TMPDIR:-/tmp}/agent-mailbox-bench.XXXXXX")
trap 'rm -rf "$W"' EXIT
as() { a=$1; shift; HOME="$W/home-$a" sh "$CLI" "$@"; }
now() { date +%s.%N 2>/dev/null | grep -v N || date +%s; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

git init -q --bare "$W/store.git"
as rx setup --store "$W/store.git" --name rx >/dev/null; as rx init >/dev/null
as rx register --kind t --about bench --no-key >/dev/null
i=1; while [ "$i" -le "$C" ]; do
  as "s$i" setup --store "$W/store.git" --name "s$i" >/dev/null; as "s$i" register --kind t --about bench --no-key >/dev/null
  i=$((i+1)); done

t0=$(now); echo m | as s1 send rx one - >/dev/null 2>&1; t1=$(now)
echo "one send: $(secs "$t0" "$t1") s"

t0=$(now); i=1; while [ "$i" -le "$N" ]; do echo m | as s1 send rx "seq-$i" - >/dev/null 2>&1; i=$((i+1)); done; t1=$(now)
echo "$N sequential sends: $(secs "$t0" "$t1") s"

t0=$(now); i=1; while [ "$i" -le "$C" ]; do ( echo m | as "s$i" send rx "conc-$i" - >/dev/null 2>&1 ) & i=$((i+1)); done; wait; t1=$(now)
got=$(as rx list 2>/dev/null | grep -c 'conc-')
echo "$C concurrent senders: $got/$C delivered in $(secs "$t0" "$t1") s"

echo h | as s1 send rx gate - --hold "bench#1 v1" >/dev/null 2>&1
t0=$(now); as rx holds "bench#1" --version v1 >/dev/null 2>&1; t1=$(now)
echo "holds over $((N + C + 2)) delivered messages: $(secs "$t0" "$t1") s"
