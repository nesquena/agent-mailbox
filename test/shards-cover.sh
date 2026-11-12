#!/bin/sh
# test/shards-cover.sh [n...]: checks that test/run.sh's shards, for each n (4 and 3 by default), run every section of
# the suite exactly once between them: the ids `--shard i/n --list` prints for i = 1..n, taken together, are the ids
# `--list` prints, as a multiset. It's sound because a run picks its sections in the one place --list prints them from;
# a --list run runs all of run.sh but the sections and the loop that runs them, so the checks it prints none of are
# all inside the sections; and each section makes what it needs itself (`--only` and `--order` test that). It also
# checks that every section, and nothing else, has a time in test/section-costs. Run it with TEST_SHELL as for run.sh.
# test/shards-cover.sh --logs <unsharded run's output> <shard's output>...: compares the checks the runs printed, as a
# multiset, instead.
set -u
ROOTDIR=$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)
SH="${TEST_SHELL:-sh}"
NL='
'
bad=0
fail() { bad=1; echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'; }
# (a multiset's difference, each line with its count: "-" what the first has more of, "+" the second)
differ() { printf '%s\n' "$1" | sort | uniq -c > "$T/a"; printf '%s\n' "$2" | sort | uniq -c > "$T/b"
  diff "$T/a" "$T/b" | sed -n 's/^< */- /p; s/^> */+ /p'; }
T=$(mktemp -d "${TMPDIR:-/tmp}/shards-cover.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

if [ "${1:-}" = --logs ]; then
  [ $# -ge 3 ] || { echo "usage: test/shards-cover.sh --logs <unsharded output> <shard output>..." >&2; exit 64; }
  checks() { awk '/^  (ok   |FAIL |skip )/ { print substr($0, 3) }' "$@"; }
  one=$(checks "$2"); shift 2; all=$(checks "$@")
  [ -n "$one" ] || fail "the unsharded output has no checks"
  d=$(differ "$one" "$all"); [ -z "$d" ] || fail "the shards' checks differ from the unsharded run's" "$d"
  [ $bad = 0 ] && echo "ok   the shards printed the unsharded run's $(printf '%s\n' "$one" | wc -l | tr -d ' ') checks, each as often"
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
  d=$(differ "$full" "${all%?}")
  [ -z "$d" ] && echo "ok   $n shards run each of the $(printf '%s\n' "$full" | wc -l | tr -d ' ') sections once" ||
    fail "$n shards don't run each section once" "$d"
done
costs=$(awk 'NF && $1 !~ /^#/ { print $1 }' "$ROOTDIR/test/section-costs")
d=$(differ "$full" "$costs")
[ -z "$d" ] && echo "ok   test/section-costs has a time for each section, and nothing else" ||
  fail "test/section-costs doesn't match the sections (-: no time, +: no such section)" "$d"
exit $bad
