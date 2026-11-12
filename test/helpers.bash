# test/helpers.bash: shared setup for the bats-core tests in test/*.bats. Load it at a file's top level
# (`load helpers`), so its functions reach every test. The tests are bash; the CLI they drive still runs under
# TEST_SHELL (default sh), as in test/run.sh.
#
# Background jobs started from a test must close fd 3 (`cmd 3>&- &`): bats waits for every process holding it.

ROOTDIR=$(CDPATH= cd -P -- "$BATS_TEST_DIRNAME/.." && pwd -P)
CLI="$ROOTDIR/bin/agent-mailbox"
SH="${TEST_SHELL:-sh}"
# each simulated agent's HOME must decide its config and state: clear anything the host sets (CI runners set XDG_*)
unset XDG_CONFIG_HOME XDG_STATE_HOME AGENT_MAILBOX_CONFIG AGENT_MAILBOX_STATE AGENT_MAILBOX_NAME AGENT_MAILBOX_STORE \
  AGENT_MAILBOX_ADAPTER AGENT_MAILBOX_ROOT AGENT_MAILBOX_BRANCH AGENT_MAILBOX_KEY AGENT_MAILBOX_SESSION CLAUDE_CODE_SESSION_ID \
  AI_AGENT CLAUDE_PID CLAUDE_CODE_ENTRYPOINT RWMAX

# every test is bounded: one that runs past BATS_TEST_TIMEOUT seconds (120 unless set) fails, rather than hanging the run
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-120}"

# workdir: make and print a folder for this file's fixtures, with a space in its path, as in a macOS home folder like
# "/Users/Jo Smith". bats removes it after the file's last test.
workdir() { : "${BATS_FILE_TMPDIR:?test/*.bats needs bats-core 1.4 or later}"; mkdir -p "$BATS_FILE_TMPDIR/agent mailbox test" && printf '%s\n' "$BATS_FILE_TMPDIR/agent mailbox test"; }

# expect <exit code> <grep -E pattern or -> <command...>: run the command, stdout and stderr together, and fail
# unless it exits with that code and some line of its output matches the pattern. The same check as test/run.sh's
# expect, so a block moves over unchanged. (A failed [[ ]] that isn't a test's last command doesn't fail the test
# under bash before 4.1, macOS's /bin/bash among them; grep and return 1 do.)
expect() {
  local code=$1 pat=$2; shift 2
  run "$@"
  if [ "$status" != "$code" ]; then
    printf 'exit %s, wanted %s\n%s\n' "$status" "$code" "$output" >&2; return 1
  fi
  if [ "$pat" != - ] && ! printf '%s\n' "$output" | grep -Eq -- "$pat"; then
    printf "output didn't match /%s/\n%s\n" "$pat" "$output" >&2; return 1
  fi
}
