#!/bin/sh
# claude-rewake.sh: the session's mailbox watcher, run as a Claude Code Stop hook with "asyncRewake": true
# (hooks/hooks.json). Claude Code starts it in the background at every turn end, and an asyncRewake hook that exits 2
# wakes the session, even an idle one, with what it printed on stderr. So nothing has to be re-armed by hand:
# - new mail: it exits 2 with the listing;
# - a watcher that can't go on (the store unreachable, the name retired): it exits 2 with the error, once per
#   distinct error, so the session hears without a wake at every turn end;
# - just before the hook's timeout (a day) it exits 2 with a one-line note, so a session that saw no turn all day
#   is woken once and its turn end starts a new watcher; otherwise the watcher would stop without a word;
# - stopped (Claude Code ends the session, or the hook is killed): it exits 0, silently.
# It needs Claude Code 2.1.69 or later (see the version check below); on anything older it exits 0 at once.
# One instance per agent name: a pid file that counts only while that pid is still this script (a pid reused after a
# container restart doesn't). Mail it already woke the session for is passed to `watch` as --except at its next
# start, so mail you read but haven't consumed doesn't wake the session at every turn end; only new mail does.
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
# Claude Code runs asyncRewake hooks in the background from 2.1.69. An older one drops the key and would run this as an
# ordinary Stop hook, holding every turn end until mail came. So the running version comes first: from AI_AGENT
# (claude-code_2-1-318_..., which newer versions give hooks), else from the Claude Code process that started this hook
# (a parent within three steps: a native `claude`, or node running Claude Code's cli.js), asked for --version by its
# absolute path. Below 2.1.69, or when it can't tell, this exits 0 at once and claude-watch-guard.sh asks for a re-arm
# as before.
ccver() {
  v=$(printf '%s\n' "${AI_AGENT:-}" | sed -n 's/^claude-code_\([0-9][0-9]*\)-\([0-9][0-9]*\)-\([0-9][0-9]*\)_.*/\1.\2.\3/p')
  [ -z "$v" ] || { echo "$v"; return 0; }
  p=$PPID n=0
  while [ $n -lt 3 ]; do
    case "$p" in ''|*[!0-9]*|0|1) return 1 ;; esac
    if [ -r "/proc/$p/cmdline" ]; then x=$(readlink "/proc/$p/exe" 2>/dev/null); a=$(tr '\0' '\n' < "/proc/$p/cmdline" | sed -n 2p)
    else x=$(ps -o comm= -p "$p" 2>/dev/null); a=$(ps -o args= -p "$p" 2>/dev/null | awk '{ print $2 }'); fi
    out=""
    case "$x" in
      (/*/claude|/*/claude.exe) out=$("$x" --version 2>/dev/null) ;;
      (/*/node|/*/node.exe|/*/nodejs) case "$a" in (/*/cli.js|/*/claude) out=$("$x" "$a" --version 2>/dev/null) ;; esac ;;
    esac
    v=$(printf '%s\n' "$out" | sed -n '1s/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) (Claude Code).*/\1/p')
    [ -z "$v" ] || { echo "$v"; return 0; }
    q=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$q" ] || q=$(sed -n 's/.*) [A-Za-z] \([0-9][0-9]*\) .*/\1/p' "/proc/$p/stat" 2>/dev/null)
    p=$q n=$((n+1))
  done
  return 1
}
ccv=$(ccver) && printf '%s\n' "$ccv" | awk -F. '{ exit !($1 > 2 || $1 == 2 && ($2 > 1 || $2 == 1 && $3 >= 69)) }' || exit 0
set -- --as "$name"; [ -z "$conf" ] || set -- --config "$conf" "$@"
# word <text>: <text> as one shell word, quoted unless it's only characters the shell reads literally
word() { case "$1" in (*[!A-Za-z0-9_./@%+:,-]*|'') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;; (*) printf '%s' "$1" ;; esac; }

run="$state/rewake/$name"; mkdir -p "$run" 2>/dev/null || exit 0
mine() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  if [ -r "/proc/$1/cmdline" ]; then a=$(tr '\0' ' ' < "/proc/$1/cmdline"); else a=$(ps -p "$1" -o args= 2>/dev/null); fi
  case "$a" in (*claude-rewake.sh*) return 0 ;; (*) return 1 ;; esac
}
mine "$(cat "$run/pid" 2>/dev/null)" && exit 0
echo $$ > "$run/pid"
child=""
cleanup() { [ -z "$child" ] || kill "$child" 2>/dev/null; [ "$(cat "$run/pid" 2>/dev/null)" != $$ ] || rm -f "$run/pid"; }
trap 'cleanup; exit 0' TERM INT HUP
trap cleanup EXIT

# the mail it already woke the session for, kept only while it's still in the inbox (when the inbox can't be read,
# the list is kept as it is)
inbox=$("$cli" "$@" list 2>/dev/null); lrc=$?
if [ -s "$run/woke" ] && { [ $lrc = 0 ] || [ $lrc = 3 ]; }; then
  inbox=$(printf '%s\n' "$inbox" | sed 's#.*/##')
  while IFS= read -r f; do
    [ -n "$f" ] && printf '%s\n' "$inbox" | grep -qxF -- "$f" && printf '%s\n' "$f"
  done < "$run/woke" > "$run/woke.new"
  mv -f "$run/woke.new" "$run/woke"
fi
# a message's file name holds only these characters (the CLI's own rule is narrower), so the list splits safely
ex=""; [ ! -s "$run/woke" ] || while IFS= read -r f; do
  case "$f" in (*[!A-Za-z0-9._-]*|'') ;; (*) ex="$ex --except $f" ;; esac
done < "$run/woke" > /dev/null

# the watcher in the background, so a stop (TERM) can end it too
# shellcheck disable=SC2086
"$cli" "$@" watch "${AGENT_MAILBOX_REWAKE_INTERVAL:-120}" "${AGENT_MAILBOX_REWAKE_MAX:-86100}" $ex > "$run/out" 2>&1 &
child=$!
wait "$child"; rc=$?; child=""
case $rc in
  0)
    rm -f "$run/error"
    sed -n '2,$s#.*/##p' "$run/out" >> "$run/woke"
    c=$(word "$cli"); [ -z "$conf" ] || c="$c --config $(word "$conf")"
    { echo "agent-mailbox: new mail for $name. Read it: $c --as $name read"; cat "$run/out"; } >&2
    exit 2 ;;
  2)
    echo "agent-mailbox: the watcher for $name reached its daily limit with no new mail; it starts again at this turn's end." >&2
    exit 2 ;;
  130|143) exit 0 ;;
  *)
    # the same error again at the next turn end doesn't wake the session again
    err="exit $rc: $(tail -n 3 "$run/out" | tr '\n' ' ')"
    [ "$err" = "$(cat "$run/error" 2>/dev/null)" ] && exit 0
    printf '%s' "$err" > "$run/error"
    echo "agent-mailbox: the watcher for $name can't go on ($err). It stays off until this changes; tell your human." >&2
    exit 2 ;;
esac
