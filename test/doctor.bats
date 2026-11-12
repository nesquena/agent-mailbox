#!/usr/bin/env bats
# doctor and the Claude Code plugin: it says whether jq, which the plugin's Stop guard needs, is there (inside Claude
# Code only), and whether a watcher for the name runs on this store, warning when this session's has stopped. None of
# these lines changes doctor's exit status.

load helpers

setup_file() {
  # the tests share one store and one state folder, and start watchers: never run them side by side
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  export T; T=$(workdir)
  export HOME="$T/home"; mkdir -p "$HOME"
  "$SH" "$CLI" setup --store "$T/store" --adapter dir --name alice >/dev/null
  "$SH" "$CLI" init >/dev/null
  "$SH" "$CLI" register --kind assistant --about "test agent" --no-key >/dev/null
  export STATE="$HOME/.local/state/agent-mailbox"
  export SID; SID=$(printf '%s' "$T/store|mailbox|main" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)
  # a PATH without jq: a link to every other command on PATH (the first of each name)
  mkdir -p "$T/nojq"
  local d f IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] && [ ! -d "$f" ] || continue
      case "${f##*/}" in (jq) continue ;; esac
      [ -e "$T/nojq/${f##*/}" ] || ln -s "$f" "$T/nojq/${f##*/}" 2>/dev/null || true
    done
  done
}

# doctor <env...>: run doctor with these variables set
doctor() { run env "$@" "$(command -v "$SH")" "$CLI" doctor; }
# has <grep -E pattern>, lacks <pattern>: a line of doctor's output does, or none does
has() { printf '%s\n' "$output" | grep -Eq -- "$1" || { printf "no line matches /%s/\n%s\n" "$1" "$output" >&2; return 1; }; }
lacks() { ! printf '%s\n' "$output" | grep -Eq -- "$1" || { printf "a line matches /%s/\n%s\n" "$1" "$output" >&2; return 1; }; }

@test "outside Claude Code, doctor says nothing about jq, and passes" {
  doctor
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  lacks 'jq'
}

@test "outside Claude Code, without jq, doctor still says nothing about it" {
  doctor PATH="$T/nojq"
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  lacks 'jq'
}

@test "inside Claude Code, doctor says jq is there" {
  command -v jq >/dev/null 2>&1 || skip "jq isn't installed"
  doctor CLAUDE_CODE_SESSION_ID=s1
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has "^ok   jq is installed \(the Claude Code plugin's Stop guard needs it\)$"
}

@test "inside Claude Code, without jq, doctor warns that the Stop guard is off, and still passes" {
  doctor CLAUDE_CODE_SESSION_ID=s1 PATH="$T/nojq"
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has "^warn jq isn't installed: the Claude Code plugin's Stop guard needs it"
  lacks '^ok   jq'
}

@test "with no watcher, doctor says so, as information" {
  doctor
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has '^info no watcher for alice is running on this store$'
  lacks '^warn (no watcher|the Claude Code)'
}

@test "a stale pid file (a dead pid) isn't a watcher" {
  mkdir -p "$STATE/run"; echo "999999 alice $SID" > "$STATE/run/alice@$SID.pid"; cp "$STATE/run/alice@$SID.pid" "$STATE/run/alice.pid"
  doctor
  rm -f "$STATE/run/alice@$SID.pid" "$STATE/run/alice.pid"
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has '^info no watcher for alice is running on this store$'
}

@test "with a watcher running, doctor names its pid" {
  "$SH" "$CLI" watch 1 30 >/dev/null 2>&1 3>&- &
  wpid=$!
  n=0; until [ -f "$STATE/run/alice@$SID.pid" ] || [ $n -ge 50 ]; do sleep 0.1; n=$((n+1)); done
  doctor
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has "^info a watcher for alice is running on this store \(pid $wpid\)$"
}

@test "a watcher for the name on another store doesn't count" {
  "$SH" "$CLI" watch 1 30 >/dev/null 2>&1 3>&- &
  wpid=$!
  n=0; until [ -f "$STATE/run/alice@$SID.pid" ] || [ $n -ge 50 ]; do sleep 0.1; n=$((n+1)); done
  # (the pid files now name another store, as the files of a watcher on it would)
  for f in "$STATE/run/alice@$SID.pid" "$STATE/run/alice.pid"; do echo "$wpid alice 0123456789abcdef" > "$f"; done
  doctor
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  has '^info no watcher for alice is running on this store$'
}

@test "when this session ran watch and no watcher runs now, doctor warns, and still passes" {
  AGENT_MAILBOX_SESSION=s2 "$SH" "$CLI" watch 1 1 >/dev/null 2>&1 || true
  doctor AGENT_MAILBOX_SESSION=s2
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has "^warn no watcher for alice is running on this store, though this session ran watch for it"
  lacks "hook didn't start a watcher"
}

@test "another session's watch doesn't make doctor warn" {
  doctor AGENT_MAILBOX_SESSION=s3
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has '^info no watcher for alice is running on this store$'
  lacks '^warn (no watcher|the Claude Code)'
}

@test "when the plugin's hook declined at the last turn end, doctor says why no watcher started" {
  mkdir -p "$STATE/rewake/alice/s2@$SID"; echo k1 > "$STATE/rewake/alice/s2@$SID/declined"
  doctor AGENT_MAILBOX_SESSION=s2
  rm -f "$STATE/rewake/alice/s2@$SID/declined"
  [ "$status" -eq 0 ] || { printf 'exit %s\n%s\n' "$status" "$output" >&2; return 1; }
  has "^warn no watcher for alice is running on this store"
  has "^warn the Claude Code plugin's hook didn't start a watcher at the last turn end: it runs only where Claude Code 2\.1\.69"
}

@test "once the name is retired, its session's stopped watcher isn't a warning" {
  "$SH" "$CLI" --as bob register --kind x --about y --no-key >/dev/null
  AGENT_MAILBOX_SESSION=s4 "$SH" "$CLI" --as bob watch 1 1 >/dev/null 2>&1 || true
  AGENT_MAILBOX_SESSION=s4 "$SH" "$CLI" --as bob update --status retired >/dev/null
  run env AGENT_MAILBOX_SESSION=s4 "$(command -v "$SH")" "$CLI" --as bob doctor
  lacks '^warn no watcher'
  has '^info no watcher for bob is running on this store$'
}
