#!/bin/sh
# claude-rewake.sh: the session's mailbox watcher, run as a Claude Code Stop hook with "asyncRewake": true
# (hooks/hooks.json). Claude Code starts it in the background at every turn end, and an asyncRewake hook that exits 2
# wakes the session, even an idle one, with what it printed on stderr. So nothing has to be re-armed by hand:
# - new mail: it exits 2 with the listing;
# - a watcher that can't go on (the store unreachable, the name retired): it exits 2 with the error, once per
#   distinct error, then keeps retrying quietly, so the session hears once and still wakes when mail comes;
# - just before the hook's timeout (a day) it exits 2 with a one-line note, so a session that saw no turn all day
#   is woken once and its turn end starts a new watcher; otherwise the watcher would stop without a word;
# - stopped (Claude Code ends the session, or the hook is killed): it exits 0, silently.
# It acts only where it can tell that Claude Code (2.1.69 or later) runs it in the background: a session in a terminal,
# or the cloud's launch (see the checks below). Anywhere else it exits 0 at once, and claude-watch-guard.sh asks
# for a re-arm as before.
# One instance per session: a pid file that counts only while that pid is still this script and the Claude Code it
# ran under is still alive (so neither a pid reused after a restart nor a hook left behind by a crash counts). Mail
# it already woke the session for is passed to `watch` as --except at its next start, so mail you read but haven't
# consumed doesn't wake the session at every turn end; only new mail does.
#
# It acts only in a session that has run `agent-mailbox watch`, which records the session's name (and config) under
# the CLI's state folder; any other session exits 0 at once. It finds those records through the same state path the
# CLI uses (AGENT_MAILBOX_STATE, else XDG_STATE_HOME, else ~/.local/state). AGENT_MAILBOX_REWAKE_INTERVAL and
# AGENT_MAILBOX_REWAKE_MAX set watch's interval and limit in seconds (120 and 86100, five minutes under the timeout).
input=$(cat 2>/dev/null)
if command -v jq >/dev/null 2>&1; then sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
else sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1); fi
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
case "$sid" in (''|.|..|*/*) exit 0 ;; esac
# this stop's prompt id, which the Stop guard gets too: the notes below that tell the guard what this hook did at this
# turn end carry it (or, from a Claude Code that sends none, the time)
# (read the way the guard reads it: with jq where there is one)
if command -v jq >/dev/null 2>&1; then key=$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null | head -n 1)
else key=$(printf '%s' "$input" | sed -n 's/.*"prompt_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1); fi
[ -n "$key" ] || key="@$(date +%s)"
state="${AGENT_MAILBOX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-mailbox}"
name=$(tr -d ' \n' 2>/dev/null < "$state/sessions/$sid")
printf '%s\n' "$name" | grep -Eq '^[a-z0-9][a-z0-9.-]{0,62}$' || exit 0
conf=$(cat "$state/session-configs/$sid" 2>/dev/null)
cli="$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)/bin/agent-mailbox"
[ -f "$cli" ] || exit 0
# this session's files: its lock, the mail it woke for, its last error (one folder per session, so two sessions
# that use one name, against the protocol, don't share them)
# ceiling: a finished session's folder stays (a few small files); upgrade path: prune folders whose lock is stale
run="$state/rewake/$name/$sid"; mkdir -p "$run" 2>/dev/null || exit 0
# args <pid>: that process's command line, its arguments joined by spaces
args() { if [ -r "/proc/$1/cmdline" ]; then tr '\0' ' ' < "/proc/$1/cmdline"; else ps -p "$1" -o args= 2>/dev/null; fi; }
# ppid <pid>: its parent's pid
ppid() { q=$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')
  [ -n "$q" ] || q=$(sed -n 's/.*) [A-Za-z] \([0-9][0-9]*\) .*/\1/p' "/proc/$1/stat" 2>/dev/null); echo "$q"; }
# live <pid>: that process exists and isn't a zombie (one no parent has reaped yet still answers kill -0)
live() { kill -0 "$1" 2>/dev/null || return 1
  st=$(sed -n 's/.*) \([A-Za-z]\) .*/\1/p' "/proc/$1/stat" 2>/dev/null); [ -n "$st" ] || st=$(ps -o stat= -p "$1" 2>/dev/null)
  case "$st" in (Z*|' Z'*) return 1 ;; esac; }
# mine: the pid file (pid, session id, Claude Code's pid) names a live claude-rewake.sh, not this one, for this
# session, whose Claude Code is still alive
mine() {
  set -- $(cat "$run/pid" 2>/dev/null)
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" != $$ ] && [ "${2:-}" = "$sid" ] && live "$1" || return 1
  [ -z "${3:-}" ] || live "$3" || return 1
  case "$(args "$1")" in (*claude-rewake.sh*) return 0 ;; (*) return 1 ;; esac
}
# this stop's key, for a hook already watching that may wake the session during this stop
printf '%s\n' "$key" > "$run/key"
mine && exit 0
# tell the guard this hook is starting at this stop (it waits for the outcome, which can take a few seconds on a node
# install's --version), and drop the outcome (a wake or a decline) of an earlier stop
prev=$(cat "$run/last" 2>/dev/null); printf '%s\n' "$key" > "$run/start"; rm -f "$run/last" "$run/declined"

# Claude Code runs asyncRewake hooks in the background from 2.1.69, and (in newer versions) only in a session that is
# interactive or has streaming input. Anywhere else (an older version that drops the key, `claude -p`, output to a file
# or pipe) it runs the hook as an ordinary Stop hook, and the run would wait at every turn end until mail came. So the
# hook acts only on positive evidence of both, and declines when it can't tell.
# The version: from AI_AGENT when Claude Code set it for its hooks (claude-code_2-1-318_harness; another suffix is a
# value passed down from an outer Claude Code), with Claude Code's pid from CLAUDE_PID; else from a native install,
# whose `claude` links to .../claude/versions/<version> (the path /proc shows), asked for --version by that absolute
# path. Either must be the hook's nearest parent that isn't a shell (Claude Code runs a hook through sh -c, and maybe
# a wrapper script, CLAUDE_CODE_SHELL_PREFIX), up to 16 steps: an npm install renames its process, so without
# AI_AGENT its version can't be told, and an outer Claude Code is never read for an inner one; the hook declines. ccver
# prints the version and Claude Code's pid.
ccver() {
  v=$(printf '%s\n' "${AI_AGENT:-}" | sed -n 's/^claude-code_\([0-9][0-9]*\)-\([0-9][0-9]*\)-\([0-9][0-9]*\)_harness$/\1.\2.\3/p')
  p=$PPID n=0
  while [ $n -lt 16 ]; do
    case "$p" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ -z "$v" ] || [ "$p" != "${CLAUDE_PID:-}" ] || { echo "$v $p"; return 0; }
    if [ -r "/proc/$p/cmdline" ]; then x=$(readlink "/proc/$p/exe" 2>/dev/null); else x=$(ps -o comm= -p "$p" 2>/dev/null); fi
    case "${x##*/}" in
      # Claude Code runs a hook through a shell (sh -c, a wrapper script): pass over those
      (sh|dash|bash|zsh|ksh|mksh|ash|busybox) p=$(ppid "$p") n=$((n+1)); continue ;;
    esac
    # the first other process is Claude Code: told by AI_AGENT (above), or a native install asked for its version
    # (asked whatever AI_AGENT says: 2.1.120 to 2.1.212 set it but not CLAUDE_PID)
    case "$x" in (/*/claude|/*/claude.exe|/*/claude/versions/[0-9]*)
      w=$(printf '%s\n' "$("$x" --version 2>/dev/null)" | sed -n '1s/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) (Claude Code).*/\1/p')
      [ -z "$w" ] || { echo "$w $p"; return 0; } ;;
    esac
    return 1
  done
  return 1
}
# background: Claude Code (ccpid) runs this hook in the background. With none of the options that make it headless
# (-p alone or in a group of short options such as -pc, --print, --init-only, --sdk-url), two cases are taken as
# evidence:
# - an interactive session: its output a terminal;
# - the cloud's launch, a session with streaming input: `--preload` as its first argument, and its input not a
#   terminal.
# Other hosts with streaming input (`--input-format stream-json`) decline: the flag alone doesn't show that Claude
# Code reads streaming input (a later `--input-format`, or input from a terminal, undoes it). Each argument is read
# on its own where /proc has them, else from the command line split at spaces.
# ceiling: without /proc (macOS), a word like -help in a prompt given on the command line reads as -p, and the hook
# declines; and a cloud launch gets its real arguments only once a session claims it, which /proc doesn't show, so
# one claimed for a headless run would be taken as streaming. Upgrade path: a field in the hook's input saying
# whether it runs in the background
term() { case "$1" in (/dev/pts/*|/dev/tty*|/dev/console) return 0 ;; esac; return 1; }
background() {
  [ -n "$ccpid" ] || return 1
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in (sdk-*|claude-code-github-action) return 1 ;; esac
  # one argument per line, a line break inside an argument (a multi-line prompt) kept apart as \001; without /proc,
  # the command line split at spaces, where a prompt's words can't be told from options, so only a terminal counts
  if [ -r "/proc/$ccpid/cmdline" ]; then av=$(tr '\n\0' '\001\n' < "/proc/$ccpid/cmdline") px=1
  else av=$(args "$ccpid" | tr ' ' '\n') px=""; fi
  printf '%s\n' "$av" | sed 1d | grep -Eq -e '^--print(=|$)' -e '^-[A-Za-z]*p' -e '^--init-only$' -e '^--sdk-url' && return 1
  # (its input checked only where it can be read)
  if [ -n "$px" ] && [ "$(printf '%s\n' "$av" | sed -n 2p)" = --preload ]; then
    i=$(readlink "/proc/$ccpid/fd/0" 2>/dev/null) && [ -n "$i" ] && ! term "$i" && return 0
  fi
  o=$(readlink "/proc/$ccpid/fd/1" 2>/dev/null) || o=$(lsof -a -p "$ccpid" -d 1 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
  term "$o"
}
# a stop that a Stop hook already kept going (stop_hook_active) at the prompt this hook already woke the session at
# means Claude Code waited for it: run as an ordinary Stop hook after all, so it steps aside
if command -v jq >/dev/null 2>&1; then sha=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
else sha=$(printf '%s' "$input" | sed -n 's/.*"stop_hook_active"[[:space:]]*:[[:space:]]*\(true\).*/\1/p' | head -n 1); fi
looped() { [ "$sha" = true ] && [ "$prev" = "$key" ]; }
cc=$(ccver); ccv=${cc%% *}; ccpid=${cc#"$ccv"}; ccpid=${ccpid# }
case "$ccpid" in (*[!0-9]*) ccpid="" ;; esac
if ! printf '%s\n' "$ccv" | awk -F. '{ exit !($1 > 2 || $1 == 2 && ($2 > 1 || $2 == 1 && $3 >= 69)) }' || ! background || looped
then
  # a note for claude-watch-guard.sh (this stop's key), which then asks for a re-arm at once instead of waiting
  printf '%s\n' "$key" > "$run/declined"; exit 0
fi
rm -f "$run/declined"
# a watcher already running for this name (one the agent started by hand) wakes the session itself; this hook starts
# at the turn end after it exits. A stopped hook's own watcher, still finishing its last poll, isn't one: `child` names it
wp=$(cut -d' ' -f1 "$state/run/$name.pid" 2>/dev/null)
case "$wp" in (''|*[!0-9]*) ;; ("$(cat "$run/child" 2>/dev/null)") ;; (*)
  if kill -0 "$wp" 2>/dev/null; then case "$(args "$wp")" in (*agent-mailbox*watch*) exit 0 ;; esac; fi ;;
esac
# the lock: checked and taken while holding a short mutex, so two hooks starting together, a stale lock between them,
# can't both take it. The mutex is a file the shell creates with noclobber, an exclusive create (mkdir isn't exclusive
# everywhere: some coreutils check, then create). One left by a hook that died while holding it goes after a minute,
# and so does the folder an older version used
claim() { ( set -C; echo $$ > "$run/claiming" ) 2>/dev/null; }
unclaim() { rm -f "$run/claiming"; }
if ! claim; then
  [ -n "$(find "$run/claiming" -prune -mmin +1 2>/dev/null)" ] &&
    { rm -f "$run/claiming" 2>/dev/null; rmdir "$run/claiming" 2>/dev/null; claim; } || exit 0
fi
if mine; then unclaim; exit 0; fi
printf '%s %s %s\n' $$ "$sid" "$ccpid" > "$run/pid.new" && mv -f "$run/pid.new" "$run/pid"; unclaim
set -- --as "$name"; [ -z "$conf" ] || set -- --config "$conf" "$@"
# note <name>: a note for the guard naming the latest stop's key (a hook can run on through several stops)
note() { k=$(cat "$run/key" 2>/dev/null); printf '%s\n' "${k:-$key}" > "$run/$1"; }
# word <text>: <text> as one shell word, quoted unless it's only characters the shell reads literally
word() { case "$1" in (*[!A-Za-z0-9_./@%+:,-]*|'') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;; (*) printf '%s' "$1" ;; esac; }
child="" dog=""
# the interval (1 s to an hour) and the day's limit: whole seconds, the limit kept under the hook's timeout (86400 s) by
# an interval and a minute, since Claude Code kills a hook at its timeout without a word, and the session would hear
# nothing
iv=${AGENT_MAILBOX_REWAKE_INTERVAL:-120} max=${AGENT_MAILBOX_REWAKE_MAX:-86100}
iv=${iv#"${iv%%[!0]*}"} max=${max#"${max%%[!0]*}"}
case "$iv" in (''|*[!0-9]*) iv=120 ;; esac; { [ "${#iv}" -le 4 ] && [ "$iv" -ge 1 ] && [ "$iv" -le 3600 ]; } || iv=120
case "$max" in (''|*[!0-9]*) max=86100 ;; esac; { [ "${#max}" -le 6 ] && [ "$max" -ge 1 ]; } || max=86100
[ "$max" -le $((86340 - iv)) ] || max=$((86340 - iv))
start=$(date +%s)
# cleanup: the watcher and the watchdog, and everything under them (a sleep, a git fetch and its ssh), deepest first,
# so none outlives the lock
stop() { for k in $(pgrep -P "$1" 2>/dev/null); do stop "$k"; done; kill "$1" 2>/dev/null; }
# (the lock goes only under the mutex that guards replacing it, so a hook that has just taken it over keeps it; when
# the mutex is busy, the lock stays, and reads as stale once this hook is gone)
cleanup() { [ -z "$child" ] || stop "$child"; [ -z "$dog" ] || stop "$dog"
  if claim; then
    [ "$(cut -d' ' -f1 "$run/pid" 2>/dev/null)" != $$ ] || rm -f "$run/pid"; unclaim
  fi; }
# (a stop at the watchdog's deadline, below, is the day's end: the session hears so, as at the limit)
trap 'if [ -f "$run/deadline" ]; then rm -f "$run/deadline"; cleanup; note last
  printf "%s\\n" "agent-mailbox: the watcher for $name reached its daily limit; it starts again at this turn'"'"'s end." >&2; exit 2; fi
  cleanup; exit 0' TERM INT HUP
trap cleanup EXIT
# Claude Code may stop this hook by killing only the shell it started it through, or end (or crash) without stopping
# it: a hook left running would hold the lock, and its wake would reach no session. So it stops itself once that shell
# or Claude Code (when its pid is known) is gone, and it doesn't record mail it would wake no one for. It also keeps a
# deadline, the day's limit plus an interval and a little more, so a command that hangs (a git fetch over a dead
# connection) can't run the hook into Claude Code's timeout, which would end it without a word.
top=$PPID
here() { live "$top" && { [ -z "$ccpid" ] || live "$ccpid"; }; }
hook=$$
dl=$((start + max + iv + 15)); rm -f "$run/deadline"
( while here && kill -0 "$hook" 2>/dev/null; do
    [ "$(date +%s)" -lt "$dl" ] || { : > "$run/deadline"; break; }; sleep 15; done
  kill -TERM "$hook" 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
dog=$!

# the mail it already woke the session for, kept only while it's still in the inbox (when the inbox can't be read,
# the list is kept as it is)
if [ -s "$run/woke" ]; then
  # (in the background, so a stop can end it too)
  "$cli" "$@" list > "$run/list" 2>/dev/null & child=$!; wait "$child"; lrc=$?; child=""; inbox=$(cat "$run/list")
  if [ $lrc = 0 ] || [ $lrc = 3 ]; then
    inbox=$(printf '%s\n' "$inbox" | sed 's#.*/##')
    while IFS= read -r f; do
      [ -n "$f" ] && printf '%s\n' "$inbox" | grep -qxF -- "$f" && printf '%s\n' "$f"
    done < "$run/woke" > "$run/woke.new"
    mv -f "$run/woke.new" "$run/woke"
  fi
fi
# a message's file name holds only these characters (the CLI's own rule is narrower), so the list splits safely
ex=""; [ ! -s "$run/woke" ] || while IFS= read -r f; do
  case "$f" in (*[!A-Za-z0-9._-]*|'') ;; (*) ex="$ex --except $f" ;; esac
done < "$run/woke" > /dev/null

while :; do
  # what's left of the day's limit
  left=$(( max - ($(date +%s) - start) ))
  [ "$left" -ge 1 ] || { note last
    printf '%s\n' "agent-mailbox: the watcher for $name reached its daily limit; it starts again at this turn's end." >&2; exit 2; }
  # the watcher in the background, so a stop (TERM) can end it too
  # shellcheck disable=SC2086
  "$cli" "$@" watch "$iv" "$left" $ex > "$run/out" 2>&1 &
  child=$!; echo "$child" > "$run/child"
  wait "$child"; rc=$?; child=""
  case $rc in
    0)
      here || exit 0
      note last
      rm -f "$run/error"
      sed -n '2,$s#.*/##p' "$run/out" >> "$run/woke"
      c=$(word "$cli"); [ -z "$conf" ] || c="$c --config $(word "$conf")"
      { printf '%s\n' "agent-mailbox: new mail for $name. Read it: $c --as $name read"; cat "$run/out"; } >&2
      exit 2 ;;
    2)
      note last
      rm -f "$run/error"
      printf '%s\n' "agent-mailbox: the watcher for $name reached its daily limit with no new mail; it starts again at this turn's end." >&2
      exit 2 ;;
  esac
  # a signal ended the watcher (the system, or someone stopping it) while this hook and its session go on: start it
  # again after an interval, quietly; and it can't go on: say so once per distinct error, then retry quietly
  here || exit 0
  # (printable text only, for the session; compared without its counts and times, so a try count or a time in it
  # isn't a new error, while an exit code or an HTTP status still is)
  err="exit $rc: $(tail -n 3 "$run/out" | tr '\n' ' ' | LC_ALL=C tr -c '[:print:]' '?')"
  ek=$(printf '%s' "$err" | sed -E 's/[0-9]+([.:][0-9]+)* ?(tries|try|ms|milliseconds?|seconds?|s|minutes?|m)([^A-Za-z]|$)/N \2\3/g')
  if [ "$rc" -le 128 ] && [ "$ek" != "$(cat "$run/error" 2>/dev/null)" ]; then
    printf '%s' "$ek" > "$run/error"; note last
    printf '%s\n' "agent-mailbox: the watcher for $name can't go on ($err). It keeps retrying quietly; tell your human." >&2
    exit 2
  fi
  [ $(( $(date +%s) - start )) -lt "$max" ] || { note last
    printf '%s\n' "agent-mailbox: the watcher for $name reached its daily limit, still failing ($err); it starts again at this turn's end." >&2
    exit 2; }
  sleep "$iv" & child=$!; wait "$child"; child=""
done
