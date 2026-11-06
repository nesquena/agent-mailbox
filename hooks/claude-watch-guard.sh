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
# config it ran with, under <state>/sessions/<session id>.config, and both commands the hook prints carry
# --config <that path>, even when it's the default: the default worked out here could differ from the agent's shell.
# A record from before that (only the name) gets the commands without it. A session id that could name another
# folder (empty, `.`, `..`, or holding a `/`) is refused, and the stop allowed.
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = true ] && exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
case "$sid" in (''|.|..|*/*) exit 0 ;; esac
state="${AGENT_MAILBOX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-mailbox}"
name=$(tr -d ' \n' 2>/dev/null < "$state/sessions/$sid")
printf '%s\n' "$name" | grep -Eq '^[a-z0-9][a-z0-9.-]{0,62}$' || exit 0
alive() {
  pid=$(cut -d' ' -f1 "$state/run/$name.pid" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then args=$(tr '\0' ' ' < "/proc/$pid/cmdline"); else args=$(ps -p "$pid" -o args= 2>/dev/null); fi
  case "$args" in *agent-mailbox*watch*) return 0 ;; *) return 1 ;; esac
}
alive && exit 0
# word <text>: <text> as one shell word, quoted unless it's only characters the shell reads literally
word() { case "$1" in (*[!A-Za-z0-9_./@%+:,-]*|'') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;; (*) printf '%s' "$1" ;; esac; }
cli="$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)/bin/agent-mailbox"
command -v agent-mailbox >/dev/null 2>&1 && cli=agent-mailbox
cli=$(word "$cli")
# ceiling: the config record and the name are two files, so a stale .config (left by a newer CLI before an older one
# rewrote only the name, or by another watcher in the same session) can pair with a newer name; the commands then
# name that config. Upgrade path: one record holding both, once no reader of the name-only format is left.
conf=$(cat "$state/sessions/$sid.config" 2>/dev/null)
[ -z "$conf" ] || cli="$cli --config $(word "$conf")"
# ceiling: a backtick in the config or plugin path ends the backtick-quoted command early for the agent reading the
# message, though the shell quoting stays valid. Upgrade path: put each command in its own JSON field.
jq -n --arg n "$name" --arg c "$cli" '{decision: "block", reason: ("The agent-mailbox watcher for \($n) is not running, so new mail would not wake this session. First run `\($c) --as \($n) read` and handle any mail (consume it, or pass --except for mail you are holding). Then re-arm it as a background command (in Claude Code, the Bash tool with run_in_background: true; never a shell & or nohup): `\($c) --as \($n) watch 120 0`. Re-arm it quietly: no message to your human about it, unless there is mail they need to know about, or the read or the watcher fails (exit 1): then tell them. If this session is ending for good, say so and stop again.")}'
