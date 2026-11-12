#!/usr/bin/env bats
# Registry metadata: the optional human, env and groups fields of a record, how register, update and setup write them,
# how agents shows and filters by them.

load helpers

# as <agent> <args...>: the CLI as that agent, with a HOME of its own
as() { local a=$1; shift; HOME="$T/home-$a" "$SH" "$CLI" "$@"; }
# fails <description> <output>: print why, and fail
fails() { printf '%s\n%s\n' "$1" "$2" >&2; return 1; }

setup_file() {
  # the tests build on one another's records and mail: run them in order
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  export T; T=$(workdir)
  export RM="$T/store/mailbox/agents"
}

@test "setup takes --human, and saves it in the config" {
  expect 0 "^wrote " as m1 setup --store "$T/store" --adapter dir --name m1 --human nesq
  expect 0 "^human = nesq$" cat "$T/home-m1/.config/agent-mailbox/config"
  expect 0 "initialized" as m1 init
}

@test "register records setup's human, with --env and --groups (spaces made single)" {
  expect 0 "register: m1" as m1 register --kind t --about t --no-key --env local --groups "camanji  ops"
  expect 0 "^human: nesq$" cat "$RM/m1.md"
  expect 0 "^env: local$" cat "$RM/m1.md"
  expect 0 "^groups: camanji ops$" cat "$RM/m1.md"
}

@test "setup run again keeps the human" {
  expect 0 "^wrote " as m1 setup --store "$T/store" --adapter dir
  expect 0 "^human = nesq$" cat "$T/home-m1/.config/agent-mailbox/config"
}

@test "register without a human records none" {
  as m2 setup --store "$T/store" --adapter dir --name m2 >/dev/null
  expect 0 "register: m2" as m2 register --kind t --about other --no-key --env cloud
  ! grep -q '^human:' "$RM/m2.md" || fails "a human line was written without one" "$(cat "$RM/m2.md")"
  as m3 setup --store "$T/store" --adapter dir --name m3 --human nesq >/dev/null
  as m3 register --kind t --about t3 --no-key --env cloud --groups camanji >/dev/null
  as m4 setup --store "$T/store" --adapter dir --name m4 >/dev/null
  as m4 register --kind t --about t4 --no-key --human bob >/dev/null
}

@test "update sets a field, and keeps what it isn't given" {
  expect 0 "update: m2" as m2 update --human bob --groups ops
  expect 0 "^human: bob$" cat "$RM/m2.md"
  expect 0 "update: m2" as m2 update --about changed
  [ "$(grep -c -e '^human: bob$' -e '^env: cloud$' -e '^groups: ops$' "$RM/m2.md")" = 3 ] ||
    fails "update dropped a field it wasn't given" "$(cat "$RM/m2.md")"
}

@test "an empty value clears a field, keeping the rest" {
  expect 0 "update: m2" as m2 update --env "" --groups ""
  ! grep -q -e '^env:' -e '^groups:' "$RM/m2.md" || fails "clearing didn't remove the line" "$(cat "$RM/m2.md")"
  grep -q '^human: bob$' "$RM/m2.md" || fails "clearing took another field" "$(cat "$RM/m2.md")"
}

@test "a value that isn't a name is refused" {
  expect 1 "--human takes one name" as m2 update --human "Not A Name"
  expect 1 "--env takes one name" as m2 update --env "Not A Name"
  expect 1 "--groups takes up to 16 names" as m2 update --groups "a b c d e f g h i j k l m n o p q"
  expect 1 "--human takes one name" as m5 setup --store "$T/store" --adapter dir --name m5 --human "a b"
}

@test "agents shows HUMAN, ENV and GROUPS" {
  run as m1 agents
  [ "$status" = 0 ] || fails "exit $status" "$output"
  printf '%s\n' "$output" | grep -q '^NAME  *STATUS  *KIND  *KEY  *HUMAN  *ENV  *GROUPS  *ABOUT$' &&
    printf '%s\n' "$output" | grep -q '^m1  *active  *t  *no  *nesq  *local  *camanji,ops  *t$' &&
    printf '%s\n' "$output" | grep -q '^m2  *active  *t  *no  *bob  *-  *-  *changed$' || fails "the new columns are missing" "$output"
}

@test "agents --names with each filter, alone and together" {
  [ "$(as m1 agents --names --human nesq | tr '\n' ' ')" = "m1 m3 " ] || fails "--human" "$(as m1 agents --names --human nesq)"
  [ "$(as m1 agents --names --env cloud | tr '\n' ' ')" = "m3 " ] || fails "--env" "$(as m1 agents --names --env cloud)"
  [ "$(as m1 agents --names --group camanji | tr '\n' ' ')" = "m1 m3 " ] || fails "--group" "$(as m1 agents --names --group camanji)"
  [ "$(as m1 agents --names --group camanji --group ops | tr '\n' ' ')" = "m1 " ] || fails "two --group" ""
  [ "$(as m1 agents --names --human nesq --env cloud --group camanji | tr '\n' ' ')" = "m3 " ] || fails "all three" ""
}

@test "the table filters too" {
  run as m1 agents --human bob
  printf '%s\n' "$output" | grep -q '^m2 ' && printf '%s\n' "$output" | grep -q '^m4 ' &&
    ! printf '%s\n' "$output" | grep -q -e '^m1 ' -e '^m3 ' || fails "the table didn't filter" "$output"
}

@test "a record's ill-formed human, env and groups read as absent, and match no filter" {
  printf -- '---\nname: m6\nkind: t\nabout: t6\nruns_on: \nwatch: \nhuman: Nes Q\nenv: CLOUD\ngroups: ok Bad\nstatus: active\nkey: \nregistered: 2026-01-01T00:00:00Z\n---\n' > "$RM/m6.md"
  mkdir -p "$T/store/mailbox/inbox/m6"; : > "$T/store/mailbox/inbox/m6/.keep"
  as m6 setup --store "$T/store" --adapter dir --name m6 >/dev/null
  expect 0 '^m6  *active  *t  *no  *-  *-  *-  *t6$' as m1 agents
  [ -z "$(as m1 agents --names --group ok)" ] || fails "an ill-formed groups field matched" "$(as m1 agents --names --group ok)"
}

@test "--names leaves out a retired agent" {
  as m4 update --status retired >/dev/null
  ! as m1 agents --names --human bob | grep -q m4 || fails "a retired agent was listed" "$(as m1 agents --names --human bob)"
}

@test "agents refuses a filter value that isn't one name, and an unknown option as such" {
  mkdir -p "$T/globdir"; : > "$T/globdir/ops"; : > "$T/globdir/dev"
  ( cd "$T/globdir" && expect 1 "--group takes one name" as m1 agents --names --group 'o*' )
  expect 1 "--group takes one name" as m1 agents --names --group "ops dev"
  expect 1 "--human takes one name" as m1 agents --human "Nes Q"
  expect 1 "unknown option bogus" as m1 agents bogus
}

@test "setup drops a config's human that isn't a name, with a warning, rather than refusing a flag not given" {
  as m7 setup --store "$T/store" --adapter dir --name m7 >/dev/null
  printf 'human = Nathan Q\n' >> "$T/home-m7/.config/agent-mailbox/config"
  expect 0 "dropping the config's human 'Nathan Q'" as m7 setup --store "$T/store" --adapter dir
  ! grep -q '^human' "$T/home-m7/.config/agent-mailbox/config" || fails "the bad human was kept" "$(cat "$T/home-m7/.config/agent-mailbox/config")"
}

@test "--groups of only spaces is refused, not taken for clearing" {
  expect 1 "--groups takes names separated by spaces" as m3 update --groups "   "
  expect 0 "^groups: camanji$" cat "$RM/m3.md"
}

@test "register warns about a config human that isn't a name, and records none" {
  as m8 setup --store "$T/store" --adapter dir --name m8 >/dev/null
  printf 'human = bob\r\n' >> "$T/home-m8/.config/agent-mailbox/config"
  run as m8 register --kind t --about t --no-key
  printf '%s\n' "$output" | grep -q "your config's human isn't a name, so none is recorded" || fails "register didn't warn" "$output"
  ! grep -q '^human:' "$RM/m8.md" || fails "register recorded a bad human" "$(cat "$RM/m8.md")"
}

@test "read prints a message as before: its frame lines and body, nothing about the sender's record" {
  echo hi from m3 | as m3 send m1 plain - >/dev/null 2>&1
  run as m1 read
  [ "$(printf '%s\n' "$output" | grep -c '^=')" = 2 ] && printf '%s\n' "$output" | grep -qx 'hi from m3' ||
    fails "read printed something new" "$output"
  ! printf '%s\n' "$output" | grep -q -e 'sender:' -e '(yours)' || fails "read printed a sender line" "$output"
}
