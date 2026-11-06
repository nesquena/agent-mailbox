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
# It needs an interactive Claude Code 2.1.69 or later (see the checks below); anywhere else it exits 0 at once.
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
state="${AGENT_MAILBOX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-mailbox}"
name=$(tr -d ' \n' 2>/dev/null < "$state/sessions/$sid")
printf '%s\n' "$name" | grep -Eq '^[a-z0-9][a-z0-9.-]{0,62}$' || exit 0
conf=$(cat "$state/session-configs/$sid" 2>/dev/null)
cli="$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)/bin/agent-mailbox"
[ -f "$cli" ] || exit 0
run="$state/rewake/$name"; mkdir -p "$run" 2>/dev/null || exit 0
# args <pid>: that process's command line, its arguments joined by spaces
args() { if [ -r "/proc/$1/cmdline" ]; then tr '\0' ' ' < "/proc/$1/cmdline"; else ps -p "$1" -o args= 2>/dev/null; fi; }
# mine: the pid file (pid, session id, Claude Code's pid) names a live claude-rewake.sh, not this one, for this
# session, whose Claude Code is still alive
mine() {
  set -- $(cat "$run/pid" 2>/dev/null)
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" != $$ ] && [ "${2:-}" = "$sid" ] && kill -0 "$1" 2>/dev/null || return 1
  [ -z "${3:-}" ] || kill -0 "$3" 2>/dev/null || return 1
  case "$(args "$1")" in (*claude-rewake.sh*) return 0 ;; (*) return 1 ;; esac
}
mine && exit 0

# Claude Code runs asyncRewake hooks in the background from 2.1.69, and (in newer versions) only in an interactive
# session: an older one drops the key, and a headless one (`claude -p`, or output to a file or pipe) runs the hook as
# an ordinary Stop hook, so the run would wait at every turn end until mail came. So both come first.
# The version: from AI_AGENT when Claude Code set it for its hooks (claude-code_2-1-318_harness; another suffix is a
# value passed down from an outer Claude Code), else from the Claude Code process that started this hook (a parent
# within three steps: a native `claude`, or node running Claude Code's cli.js), asked for --version by its absolute
# path. ccver prints the version and Claude Code's pid (if known).
ccver() {
  v=$(printf '%s\n' "${AI_AGENT:-}" | sed -n 's/^claude-code_\([0-9][0-9]*\)-\([0-9][0-9]*\)-\([0-9][0-9]*\)_harness$/\1.\2.\3/p')
  [ -z "$v" ] || { echo "$v ${CLAUDE_PID:-}"; return 0; }
  p=$PPID n=0
  while [ $n -lt 3 ]; do
    case "$p" in ''|*[!0-9]*|0|1) return 1 ;; esac
    # the executable and its first argument that isn't an option (the script, for node)
    if [ -r "/proc/$p/cmdline" ]; then x=$(readlink "/proc/$p/exe" 2>/dev/null)
      a=$(tr '\0' '\n' < "/proc/$p/cmdline" | sed -n '2,$p' | grep -v '^-' | head -n 1)
    else x=$(ps -o comm= -p "$p" 2>/dev/null); a=$(ps -o args= -p "$p" 2>/dev/null | tr ' ' '\n' | sed -n '2,$p' | grep -v '^-' | head -n 1); fi
    out=""
    case "$x" in
      # a native install's `claude` is a link to .../claude/versions/<version>, which /proc resolves
      (/*/claude|/*/claude.exe|/*/claude/versions/[0-9]*) out=$("$x" --version 2>/dev/null) ;;
      (/*/node|/*/node.exe|/*/nodejs) case "$a" in (/*/cli.js|/*/claude) out=$("$x" "$a" --version 2>/dev/null) ;; esac ;;
    esac
    v=$(printf '%s\n' "$out" | sed -n '1s/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) (Claude Code).*/\1/p')
    [ -z "$v" ] || { echo "$v $p"; return 0; }
    q=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$q" ] || q=$(sed -n 's/.*) [A-Za-z] \([0-9][0-9]*\) .*/\1/p' "/proc/$p/stat" 2>/dev/null)
    p=$q n=$((n+1))
  done
  return 1
}
# Headless: Claude Code names an SDK or GitHub Action run in CLAUDE_CODE_ENTRYPOINT (sdk-cli for -p, or output that
# isn't a terminal), and a -p run under a host that set its own entrypoint still has -p or --print in its arguments.
# ceiling: a run without -p whose output isn't a terminal, under a host's entrypoint (remote, a desktop app), isn't
# seen as headless; upgrade path: a hook field from Claude Code saying the hook runs in the background.
headless() {
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in (sdk-*|claude-code-github-action) return 0 ;; esac
  [ -n "$ccpid" ] || return 1
  case " $(args "$ccpid") " in (*" -p "*|*" --print "*|*" --print="*) return 0 ;; esac
  return 1
}
cc=$(ccver); ccv=${cc%% *}; ccpid=${cc#"$ccv"}; ccpid=${ccpid# }
case "$ccpid" in (*[!0-9]*) ccpid="" ;; esac
if ! printf '%s\n' "$ccv" | awk -F. '{ exit !($1 > 2 || $1 == 2 && ($2 > 1 || $2 == 1 && $3 >= 69)) }' || headless; then
  # a note for claude-watch-guard.sh, which then asks for a re-arm at once instead of waiting for this hook
  echo "${ccv:-unknown}" > "$run/declined"; exit 0
fi
rm -f "$run/declined"
# a watcher already running for this name (one the agent started by hand) wakes the session itself; this hook starts
# at the turn end after it exits. A stopped hook's own watcher, still finishing its last poll, isn't one: `child` names it
wp=$(cut -d' ' -f1 "$state/run/$name.pid" 2>/dev/null)
case "$wp" in (''|*[!0-9]*) ;; ("$(cat "$run/child" 2>/dev/null)") ;; (*)
  if kill -0 "$wp" 2>/dev/null; then case "$(args "$wp")" in (*agent-mailbox*watch*) exit 0 ;; esac; fi ;;
esac
# the lock, taken with noclobber, so two hooks starting together can't both hold it; a stale one is replaced once
claim() { ( set -C; printf '%s %s %s\n' $$ "$sid" "$ccpid" > "$run/pid" ) 2>/dev/null; }
if ! claim; then mine && exit 0; rm -f "$run/pid"; claim || exit 0; fi
set -- --as "$name"; [ -z "$conf" ] || set -- --config "$conf" "$@"
# word <text>: <text> as one shell word, quoted unless it's only characters the shell reads literally
word() { case "$1" in (*[!A-Za-z0-9_./@%+:,-]*|'') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;; (*) printf '%s' "$1" ;; esac; }
child="" dog=""
cleanup() { [ -z "$child" ] || kill "$child" 2>/dev/null; [ -z "$dog" ] || kill "$dog" 2>/dev/null
  [ "$(cut -d' ' -f1 "$run/pid" 2>/dev/null)" != $$ ] || rm -f "$run/pid"; }
trap 'cleanup; exit 0' TERM INT HUP
trap cleanup EXIT
# Claude Code may stop this hook by killing only the shell it started it through, or end (or crash) without stopping
# it: a hook left running would hold the lock, and its wake would reach no session. So it stops itself once that shell
# or Claude Code (when its pid is known) is gone, and it doesn't record mail it would wake no one for.
top=$PPID
here() { kill -0 "$top" 2>/dev/null && { [ -z "$ccpid" ] || kill -0 "$ccpid" 2>/dev/null; }; }
( while here; do sleep 15; done; kill -TERM $$ 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
dog=$!

# the mail it already woke the session for, kept only while it's still in the inbox (when the inbox can't be read,
# the list is kept as it is)
if [ -s "$run/woke" ]; then
  inbox=$("$cli" "$@" list 2>/dev/null); lrc=$?
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

iv=${AGENT_MAILBOX_REWAKE_INTERVAL:-120} max=${AGENT_MAILBOX_REWAKE_MAX:-86100} start=$(date +%s)
while :; do
  left=$(( max - ($(date +%s) - start) )); [ "$left" -ge 1 ] || left=1
  # the watcher in the background, so a stop (TERM) can end it too
  # shellcheck disable=SC2086
  "$cli" "$@" watch "$iv" "$left" $ex > "$run/out" 2>&1 &
  child=$!; echo "$child" > "$run/child"
  wait "$child"; rc=$?; child=""
  case $rc in
    0)
      here || exit 0
      rm -f "$run/error"
      sed -n '2,$s#.*/##p' "$run/out" >> "$run/woke"
      c=$(word "$cli"); [ -z "$conf" ] || c="$c --config $(word "$conf")"
      { echo "agent-mailbox: new mail for $name. Read it: $c --as $name read"; cat "$run/out"; } >&2
      exit 2 ;;
    2)
      rm -f "$run/error"
      echo "agent-mailbox: the watcher for $name reached its daily limit with no new mail; it starts again at this turn's end." >&2
      exit 2 ;;
  esac
  # a signal ended it (a stop, a time limit, the system): nothing to report
  [ "$rc" -le 128 ] || exit 0
  # it can't go on: say so once per distinct error, then retry quietly every interval until the day's limit
  err="exit $rc: $(tail -n 3 "$run/out" | tr '\n' ' ')"
  if [ "$err" != "$(cat "$run/error" 2>/dev/null)" ]; then
    printf '%s' "$err" > "$run/error"
    echo "agent-mailbox: the watcher for $name can't go on ($err). It keeps retrying quietly; tell your human." >&2
    exit 2
  fi
  [ $(( $(date +%s) - start )) -lt "$max" ] || {
    echo "agent-mailbox: the watcher for $name reached its daily limit, still failing ($err); it starts again at this turn's end." >&2
    exit 2; }
  sleep "$iv" & child=$!; wait "$child"; child=""
done
