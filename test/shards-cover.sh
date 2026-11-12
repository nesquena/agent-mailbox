#!/bin/sh
# test/shards-cover.sh [n...]: checks that test/run.sh's shards, for each n (4 and 3 by default), run every section of
# the suite exactly once between them: the ids `--shard i/n --list` prints for i = 1..n, taken together, are the ids
# `--list` prints, as a multiset. It's sound because a run picks its sections in the one place --list prints them from;
# a --list run runs all of run.sh but the sections and the loop that runs them, so the checks it prints none of are
# all inside the sections; and a section's checks don't depend on what else ran (see run.sh's first lines; `--only`
# and `--order` test it). It also checks that test/section-costs holds a time for every section, and nothing else.
# Run it with TEST_SHELL as for run.sh.
# test/shards-cover.sh --logs <unsharded run's output> <shard's output>...: compares the checks the runs printed, as a
# multiset, instead.
set -u
ROOTDIR=$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)
SH="${TEST_SHELL:-sh}"
NL='
'
bad=0
fail() { bad=1; echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'; }
# same <ok text> <FAIL text> <lines> <lines>: ok when the two are equal as multisets, else FAIL with the difference,
# each line with its count: "-" what the first has more of, "+" the second
same() { printf '%s\n' "$3" | sort | uniq -c > "$T/a"; printf '%s\n' "$4" | sort | uniq -c > "$T/b"
  d=$(diff "$T/a" "$T/b" | sed -n 's/^< */- /p; s/^> */+ /p')
  if [ -z "$d" ]; then echo "ok   $1"; else fail "$2" "$d"; fi; }
count() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
T=$(mktemp -d "${TMPDIR:-/tmp}/shards-cover.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

if [ "${1:-}" = --logs ]; then
  [ $# -ge 3 ] || { echo "usage: test/shards-cover.sh --logs <unsharded output> <shard output>..." >&2; exit 64; }
  checks() { awk '/^  (ok   |FAIL |skip )/ { print substr($0, 3) }' "$@"; }
  one=$(checks "$2"); shift 2; all=$(checks "$@")
  if [ -n "$one" ]; then same "the shards printed the unsharded run's $(count "$one") checks, each as often" \
    "the shards' checks differ from the unsharded run's" "$one" "$all"
  else fail "the unsharded output has no checks"; fi
  exit $bad
fi

list() { "$SH" "$ROOTDIR/test/run.sh" --list "$@" 2>&1 || echo "(test/run.sh --list $* exited $?)"; }
full=$(list)
bogus=$(printf '%s\n' "$full" | grep -v '^[a-z0-9][a-z0-9-]*$')
[ -z "$bogus" ] || fail "test/run.sh --list printed more than section ids" "$bogus"
[ -n "$full" ] || fail "test/run.sh --list printed no sections"
[ $# -gt 0 ] || set -- 4 3
for n in "$@"; do
  all="" i=1
  while [ "$i" -le "$n" ]; do s=$(list --shard "$i/$n"); all="$all${s:+$s$NL}"; i=$((i + 1)); done
  same "$n shards run each of the $(count "$full") sections once" "$n shards don't run each section once" "$full" "${all%?}"
done
# (a time is a line "<id> <whole seconds>", the rule run.sh reads them by; any other line but a blank or # one is wrong)
f="$ROOTDIR/test/section-costs"
odd=$(awk 'NF && !/^#/ && !/^[a-z0-9][a-z0-9-]* [0-9]+$/' "$f")
[ -z "$odd" ] || fail "test/section-costs has lines that aren't \"<id> <seconds>\"" "$odd"
same "test/section-costs has a time for each section, and nothing else" \
  "test/section-costs doesn't match the sections (-: no time, +: no such section)" "$full" \
  "$(awk '/^[a-z0-9][a-z0-9-]* [0-9]+$/ { print $1 }' "$f")"
exit $bad
