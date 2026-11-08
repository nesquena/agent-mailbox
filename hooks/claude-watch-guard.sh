#!/bin/sh
# claude-watch-guard.sh: a Claude Code Stop hook that keeps a session's mailbox watcher armed.
#
# `agent-mailbox watch` exits as soon as mail arrives (a background command's exit is what wakes the session), and
# harnesses cap how long a background command may run. A watcher that isn't re-armed leaves mail unnoticed. This
# hook blocks a turn from ending while the session's watcher is down, and says how to re-arm it.
#
# It acts only in a session that has run `agent-mailbox watch`: that records the session's agent name under
# <state>/sessions/<session id> and the watcher's pid under <state>/run/<name>.pid. A pid counts as alive only if
# that process is still an agent-mailbox watcher, so a reused pid can't fool it. stop_hook_active (a stop that a
# hook already continued) lets the stop through, so it never loops. It fails open: without jq, a session id, or a
# record of a watcher, it allows the stop. It finds the records through the same state path the CLI uses
# (AGENT_MAILBOX_STATE, else XDG_STATE_HOME, else ~/.local/state): a watcher started with a custom state path needs
# the same variable in the hook's environment, or the hook can't see it and allows the stop. `watch` also records the
# config it ran with, under <state>/session-configs/<session id>, and both commands the hook prints carry
# --config <that path>, even when it's the default: the default worked out here could differ from the agent's shell.
# A record from before that (only the name) gets the commands without it. A session id that could name another
# folder (empty, `.`, `..`, or holding a `/`) is refused, and the stop allowed. A session that ran `watch` on several
# stores (session-stores/<session id>, a line per store and name) needs each of them watched; the stop is blocked for
# the first that isn't, with that store's name and config.
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = true ] && exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
case "$sid" in (''|.|..|*/*) exit 0 ;; esac
state="${AGENT_MAILBOX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-mailbox}"
name=$(tr -d ' \n' 2>/dev/null < "$state/sessions/$sid")
printf '%s\n' "$name" | grep -Eq '^[a-z0-9][a-z0-9.-]{0,62}$' || exit 0
conf=$(cat "$state/session-configs/$sid" 2>/dev/null)
# what to check: each store line (as claude-rewake.sh reads them) when there are several, else the session's one name;
# as "<store id or -> <name> <config>"
list=$(awk 'NF >= 3 && $1 ~ /^[A-Za-z0-9]+$/ && length($1) <= 64 && $2 ~ /^[a-z0-9][a-z0-9.-]*$/ && length($2) <= 63' \
  "$state/session-stores/$sid" 2>/dev/null)
[ "$(printf '%s\n' "$list" | grep -c .)" -ge 2 ] || list="- $name $conf"
# pick <line>: set store, name, conf and the folder claude-rewake.sh keeps for it
pick() { store=${1%% *}; r=${1#* }; name=${r%% *}; conf=${r#"$name"}; conf=${conf# }
  [ "$store" != - ] || store=""; dir="$state/rewake/$name/$sid${store:+@$store}"; }
# (on one of several stores, only a watcher on that store counts: its own pid file)
alive() {
  set -- $(cat "$state/run/$name${store:+@$store}.pid" 2>/dev/null); pid=${1:-}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then args=$(tr '\0' ' ' < "/proc/$pid/cmdline"); else args=$(ps -p "$pid" -o args= 2>/dev/null); fi
  case "$args" in *agent-mailbox*watch*) return 0 ;; *) return 1 ;; esac
}
# claude-rewake.sh, the watcher as an asyncRewake hook, starts at this same turn end: give it a moment (it, for this
# session, or the watcher it starts, counts) before asking for a re-arm. Where it has declined (a Claude Code too old
# for it or headless, or one whose version it can't find) it leaves a `declined` note, and this blocks at once
# live <pid>: that process exists and isn't a zombie (as claude-rewake.sh reads its lock)
live() { kill -0 "$1" 2>/dev/null || return 1
  st=$(sed -n 's/.*) \([A-Za-z]\) .*/\1/p' "/proc/$1/stat" 2>/dev/null); [ -n "$st" ] || st=$(ps -o stat= -p "$1" 2>/dev/null)
  case "$st" in (Z*|' Z'*) return 1 ;; esac; }
rewaking() {
  set -- $(cat "$dir/pid" 2>/dev/null); rp=${1:-}
  case "$rp" in ''|*[!0-9]*) return 1 ;; esac
  [ "${2:-}" = "$sid" ] || return 1
  [ -z "${3:-}" ] || live "$3" || return 1
  live "$rp" || return 1
  if [ -r "/proc/$rp/cmdline" ]; then a=$(tr '\0' ' ' < "/proc/$rp/cmdline"); else a=$(ps -p "$rp" -o args= 2>/dev/null); fi
  case "$a" in *claude-rewake.sh*) return 0 ;; *) return 1 ;; esac
}
# It also counts that hook waking the session at this turn end (mail already waiting), which leaves a `last` note
# naming this stop's prompt id (or, from a Claude Code that sends none, the time); a `declined` note for this stop means
# it isn't coming
key=$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null); t0=$(date +%s)
this() { n1=$(cat "$dir/$1" 2>/dev/null)
  if [ -n "$key" ]; then [ "$n1" = "$key" ]; else case "$n1" in (@*[!0-9]*|@) return 1 ;; (@*) [ "${n1#@}" -ge $((t0 - 2)) ] ;; (*) return 1 ;; esac; fi; }
# A store is covered when its watcher runs, or its hook does or has woken the session at this stop. The stop is blocked
# for the first store that isn't: at once when its hook declined, else after the wait (3 s, or 15 s once a hook has
# said it's starting at this stop)
n=0 lim=3; while :; do
  miss="" dec=""; while IFS= read -r l; do pick "$l"; alive && continue
    this declined && { miss=$l dec=1; break; }
    rewaking || this last || { [ -n "$miss" ] || miss=$l; ! this start || lim=15; }; done <<LIST
$list
LIST
  [ -n "$miss" ] || exit 0; [ -z "$dec" ] && [ $n -lt $lim ] || break; sleep 1; n=$((n+1)); done
pick "$miss"
# word <text>: <text> as one shell word, quoted unless it's only characters the shell reads literally
word() { case "$1" in (*[!A-Za-z0-9_./@%+:,-]*|'') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;; (*) printf '%s' "$1" ;; esac; }
cli="$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)/bin/agent-mailbox"
command -v agent-mailbox >/dev/null 2>&1 && cli=agent-mailbox
cli=$(word "$cli")
# ceiling: the config record and the name are two files, so a stale config record (session-configs/<id>, left by a
# newer CLI before an older one rewrote only the name, or by another watcher in the same session) can pair with a
# newer name; the commands then name that config. Upgrade path: one record holding both, once no reader of the
# name-only format is left.
[ -z "$conf" ] || cli="$cli --config $(word "$conf")"
# ceiling: a backtick in the config or plugin path ends the backtick-quoted command early for the agent reading the
# message, though the shell quoting stays valid; and jq prints a path that isn't valid UTF-8 with U+FFFD in place of
# the bad bytes, so that command names another file and fails. Upgrade path: put each command in its own JSON field.
jq -n --arg n "$name" --arg c "$cli" '{decision: "block", reason: ("The agent-mailbox watcher for \($n) is not running, so new mail would not wake this session. First run `\($c) --as \($n) read` and handle any mail (consume it, or pass --except for mail you are holding). Then re-arm it as a background command (in Claude Code, the Bash tool with run_in_background: true; never a shell & or nohup): `\($c) --as \($n) watch 120 0`. Re-arm it quietly: no message to your human about it, unless there is mail they need to know about, or the read or the watcher fails (exit 1): then tell them. If this session is ending for good, say so and stop again.")}'
