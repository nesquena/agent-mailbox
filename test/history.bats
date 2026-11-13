#!/usr/bin/env bats
# Adapters declare whether they keep history (AD_HISTORY, adapters/README.md), and holds warns on stderr when its
# adapter doesn't keep every version, or doesn't say: a consumed or deleted hold or release isn't seen. The verdict
# and exit code stay the same.

load helpers

setup_file() {
  export T; T=$(workdir)
  # a third-party adapter that doesn't set AD_HISTORY: dir.sh without that line, in a folder of adapters of its own
  export LIB="$T/lib"; mkdir -p "$LIB"
  cp "$ROOTDIR/adapters/git.sh" "$ROOTDIR/adapters/dir.sh" "$LIB/"
  grep -v '^AD_HISTORY=' "$ROOTDIR/adapters/dir.sh" > "$LIB/plain.sh"
  if grep -q AD_HISTORY "$LIB/plain.sh"; then echo "plain.sh still sets AD_HISTORY" >&2; return 1; fi
  git init -q --bare "$T/store.git"
  for ad in git dir plain; do
    case $ad in (git) store="$T/store.git" ;; (*) store="$T/store-$ad" ;; esac
    for a in alice bob; do as "$ad-$a" setup --store "$store" --adapter "$ad" --name "$a" >/dev/null; done
    as "$ad-alice" init >/dev/null
    for a in alice bob; do as "$ad-$a" register --kind tester --about "history test" --no-key >/dev/null; done
    # bob holds a#1, then releases v1 of it; b#1 stays held
    echo h | as "$ad-bob" send alice hold-b - --hold "b#1 v1" >/dev/null
    echo h | as "$ad-bob" send alice hold-a - --hold "a#1 v1" >/dev/null
    sleep 1
    echo r | as "$ad-bob" send alice rel-a - --release "a#1 v1" >/dev/null
  done
}

# as <home> <args...>: run the CLI in that agent's own home, with the test's adapters folder
as() { h=$1; shift; HOME="$T/home-$h" AGENT_MAILBOX_LIB="$LIB" "$SH" "$CLI" "$@"; }

# split <command...>: run it, keeping stdout in $out, stderr in $err and the exit code in $rc (bats stops a test at a
# failed command, so the code is caught, not left to stop it)
split() { rc=0; "$@" > "$T/out" 2> "$T/err" || rc=$?; out=$(cat "$T/out"); err=$(cat "$T/err"); }

nowarn() { ! printf '%s\n' "$err" | grep -q 'history' || { printf 'unexpected warning:\n%s\n' "$err" >&2; return 1; }; }
warns() { printf '%s\n' "$err" | grep -Eq "^holds: warning: the $1 adapter $2, so a hold or release that was consumed or deleted isn't seen" ||
  { printf 'no history warning matching /%s/ in stderr:\n%s\n' "$2" "$err" >&2; return 1; }
  ! printf '%s\n' "$out" | grep -q 'history' || { printf 'the warning reached stdout:\n%s\n' "$out" >&2; return 1; }; }
code() { [ "$rc" = "$1" ] || { printf 'exit %s, wanted %s\n%s\n%s\n' "$rc" "$1" "$out" "$err" >&2; return 1; }; }
says() { printf '%s\n' "$out" | grep -Eq -- "$1" || { printf "stdout didn't match /%s/\n%s\n" "$1" "$out" >&2; return 1; }; }

@test "git keeps history: holds doesn't warn" {
  split as git-alice holds
  code 0; says "a#1 v1 bob .* unsigned"; [ -z "$err" ] || { printf 'stderr:\n%s\n' "$err" >&2; return 1; }
}

@test "and a gate check on git doesn't warn of history either" {
  split as git-alice holds "a#1" --version v1
  code 0; says "released by bob"; nowarn
}

@test "a dir store warns that it keeps no history, on stderr, and still lists" {
  split as dir-alice holds
  code 0; says "a#1 v1 bob .* unsigned"; says "b#1 v1 bob"; warns dir "keeps no history"
}

@test "a released version still passes on dir, with the warning" {
  split as dir-alice holds "a#1" --version v1
  code 0; says "released by bob"; warns dir "keeps no history"
}

@test "a held item still refuses on dir, with the warning" {
  split as dir-alice holds "b#1" --version v1
  code 5; says "b#1 is held by bob"; warns dir "keeps no history"
}

@test "an AD_HISTORY in the environment doesn't silence it" {
  split env AD_HISTORY=full HOME="$T/home-dir-alice" AGENT_MAILBOX_LIB="$LIB" "$SH" "$CLI" holds "a#1" --version v1
  code 0; warns dir "keeps no history"
}

@test "an adapter that doesn't set AD_HISTORY warns that it doesn't say" {
  split as plain-alice holds "a#1" --version v1
  code 0; says "released by bob"; warns plain "doesn't say whether it keeps history"
}

@test "and its verdict on a held item is unchanged" {
  split as plain-alice holds "b#1" --version v1
  code 5; says "b#1 is held by bob"; warns plain "doesn't say whether it keeps history"
}

# consuming the release and the hold is what the warning is about: git still sees both, dir sees neither
@test "consumed, git still decides from history, without the warning" {
  for m in $(as git-alice list | grep -e '-bob-hold-a\.md$' -e '-bob-rel-a\.md$'); do as git-alice consume "$(basename "$m")" >/dev/null; done
  split as git-alice holds "a#1" --version v1
  code 0; says "released by bob"; nowarn
}

@test "consumed, dir has nothing recorded, and says why it may not" {
  for m in $(as dir-alice list | grep -e '-bob-hold-a\.md$' -e '-bob-rel-a\.md$'); do as dir-alice consume "$(basename "$m")" >/dev/null; done
  split as dir-alice holds "a#1" --version v1
  code 5; says "nothing recorded for a#1"; warns dir "keeps no history"
}
