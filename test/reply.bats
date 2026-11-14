#!/usr/bin/env bats
# reply: answer a message in your inbox, to its sender, on its topic and context, and consume it in the same change.
# Every test runs against a git store and a dir store; a store that requires signatures has tests of its own.

load helpers

# as <adapter> <agent> <args...>: run the CLI as that agent on that adapter's store, in its own home
as() { local ad=$1 a=$2; shift 2
  HOME="$T/$ad/home-$a" XDG_CONFIG_HOME= XDG_STATE_HOME= AGENT_MAILBOX_SESSION= CLAUDE_CODE_SESSION_ID= \
    AGENT_MAILBOX_NAME= "$SH" "$CLI" "$@"; }
# store <adapter>: that adapter's store
store() { if [ "$1" = git ] || [ "$1" = sgit ]; then printf '%s\n' "$T/$1/store.git"; else printf '%s\n' "$T/$1/store"; fi; }
# tamper <adapter> <shell command>: change the store directly, as anyone with write access could, from its top folder
tamper() { local s; s=$(store "$1")
  case "$1" in
    (git|sgit) rm -rf "$T/tw"; git clone -q -b main "$s" "$T/tw" && (cd "$T/tw" && git config user.email e@e &&
      git config user.name e && sh -c "$2" && git add -A && git commit -qm tamper && git push -q origin HEAD:main) ;;
    (*) (cd "$s" && sh -c "$2") ;;
  esac; }
# plant <adapter> <inbox> <file name> <from> <topic> [<to>]: put an unsigned message in an inbox by hand, its to:
# header naming the inbox's owner unless <to> is given
plant() { tamper "$1" "mkdir -p mailbox/inbox/$2 && printf -- '---\nprotocol: 1\nfrom: $4\nto: ${6:-$2}\ntopic: $5\ncontext: general\nsent: 2026-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\n---\n\nhi\n' > mailbox/inbox/$2/$3"; }
# sent_id <send output>: the file name of the message it sent
sent_id() { printf '%s\n' "$1" | sed -n 's#^sent .*/##p'; }
# header <adapter> <agent> <file name> <field>: a header field of a message in that agent's inbox, read from the store
header() { as "$1" "$2" read | awk -v f="$3" -v k="$4: " '/^===== / { on = index($0, f) > 0 } on && index($0, k) == 1 { print substr($0, length(k) + 1); exit }'; }

setup_file() {
  export T; T=$(workdir)
  export SSH=""; ssh-keygen -Y 2>&1 | grep -Eq 'ssh-keygen -Y (sign|verify)' && SSH=1
  local ad a
  git init -q --bare "$T/git/store.git"; mkdir -p "$T/dir"
  for ad in git dir; do
    for a in alice bob carol; do as $ad $a setup --store "$(store $ad)" --adapter $ad --name $a >/dev/null; done
    as $ad alice init >/dev/null
    # (with signing keys when ssh-keygen can sign, so a tampered message reads bad; the store doesn't require them)
    for a in alice bob carol; do as $ad $a register --kind t --about t $([ -n "$SSH" ] || echo --no-key) >/dev/null; done
  done
  [ -n "$SSH" ] || return 0
  git init -q --bare "$T/sgit/store.git"; mkdir -p "$T/sdir"
  for ad in sgit sdir; do
    local adapter=git; [ $ad = sgit ] || adapter=dir
    for a in alice bob; do as $ad $a setup --store "$(store $ad)" --adapter $adapter --name $a >/dev/null; done
    as $ad alice init --require-signatures >/dev/null
    for a in alice bob; do as $ad $a register --kind t --about t >/dev/null; done
  done
}

@test "reply sends to the sender, on its topic and context, and consumes the message" {
  for ad in git dir; do
    run as $ad bob send alice plan - --context proj-x --needs "an answer" <<< "the plan"
    [ "$status" -eq 0 ] || { echo "$ad: $output"; return 1; }
    id=$(sent_id "$output")
    expect 0 "^sent mailbox/inbox/bob/[0-9]{8}T[0-9]{6}Z-alice-plan\.md$" as $ad alice reply "$id" - <<< "the answer"
    rid=$(sent_id "$output")
    expect 3 "no mail for alice" as $ad alice list
    [ "$(header $ad bob "$rid" from)" = alice ] || { echo "$ad: from"; return 1; }
    [ "$(header $ad bob "$rid" topic)" = plan ] || { echo "$ad: topic"; return 1; }
    [ "$(header $ad bob "$rid" context)" = proj-x ] || { echo "$ad: context"; return 1; }
    [ "$(header $ad bob "$rid" in_reply_to)" = "$id" ] || { echo "$ad: in_reply_to"; return 1; }
    [ "$(header $ad bob "$rid" needs)" = none ] || { echo "$ad: needs"; return 1; }
    as $ad bob consume "$rid" >/dev/null
  done
}

@test "in a git store the reply and the consume are one commit" {
  run as git bob send alice onecommit - <<< "q"; id=$(sent_id "$output")
  run as git alice reply "$id" - <<< "a"; [ "$status" -eq 0 ]; rid=$(sent_id "$output")
  run git --git-dir "$T/git/store.git" show --no-renames --name-status --format= main
  printf '%s\n' "$output" | grep -Eq "^D[[:space:]]+mailbox/inbox/alice/$id$" || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -Eq "^A[[:space:]]+mailbox/inbox/bob/$rid$" || { echo "$output"; return 1; }
  as git bob consume "$rid" >/dev/null
}

@test "reply takes the path read prints, a body file, and send's --needs and --context" {
  for ad in git dir; do
    run as $ad bob send alice paths - <<< "q"; id=$(sent_id "$output")
    printf 'the answer\n' > "$T/body.md"
    expect 0 "^sent " as $ad alice reply "mailbox/inbox/alice/$id" "$T/body.md" --needs "a review" --context other
    rid=$(sent_id "$output")
    [ "$(header $ad bob "$rid" needs)" = "a review" ] || { echo "$ad: needs"; return 1; }
    [ "$(header $ad bob "$rid" context)" = other ] || { echo "$ad: context"; return 1; }
    expect 3 - as $ad alice list
    as $ad bob consume "$rid" >/dev/null
  done
}

@test "options may come before the body" {
  for ad in git dir; do
    run as $ad bob send alice order - <<< "q"; id=$(sent_id "$output")
    expect 0 "^sent " as $ad alice reply "$id" --needs "an ack" - <<< "a"
    rid=$(sent_id "$output")
    [ "$(header $ad bob "$rid" needs)" = "an ack" ] || { echo "$ad: needs"; return 1; }
    as $ad bob consume "$rid" >/dev/null
  done
}

@test "--keep answers without consuming" {
  for ad in git dir; do
    run as $ad bob send alice keepme - <<< "q"; id=$(sent_id "$output")
    expect 0 "^sent " as $ad alice reply "$id" - --keep <<< "a"
    rid=$(sent_id "$output")
    expect 0 "$id" as $ad alice list
    [ "$(header $ad bob "$rid" in_reply_to)" = "$id" ] || { echo "$ad: in_reply_to"; return 1; }
    as $ad alice consume "$id" >/dev/null; as $ad bob consume "$rid" >/dev/null
  done
}

@test "a message that isn't in your inbox is refused" {
  for ad in git dir; do
    expect 1 "not in your inbox: 20260101T000000Z-bob-none\.md" as $ad alice reply 20260101T000000Z-bob-none.md - <<< "a"
    # (mail to carol, named as alice's)
    run as $ad bob send carol notyours - <<< "q"; id=$(sent_id "$output")
    expect 1 "not in your inbox: $id" as $ad alice reply "mailbox/inbox/carol/$id" - <<< "a"
    expect 1 "isn't a message file name" as $ad alice reply notes.txt - <<< "a"
    as $ad carol consume "$id" >/dev/null
  done
}

@test "a message whose from: header and file name name different senders is refused, and nothing is sent" {
  for ad in git dir; do
    plant $ad alice 20260101T000000Z-carol-spoof.md bob spoof
    expect 1 "20260101T000000Z-carol-spoof\.md: its file name doesn't name it as from bob about spoof; answer with send" \
      as $ad alice reply 20260101T000000Z-carol-spoof.md - <<< "a"
    expect 3 - as $ad bob list; expect 3 - as $ad carol list
    expect 0 "20260101T000000Z-carol-spoof\.md" as $ad alice list
    as $ad alice consume 20260101T000000Z-carol-spoof.md >/dev/null
  done
}

@test "a message whose topic: header isn't its file name's topic is refused" {
  for ad in git dir; do
    plant $ad alice 20260101T000000Z-bob-one.md bob two
    expect 1 "20260101T000000Z-bob-one\.md: its file name doesn't name it as from bob about two; answer with send" \
      as $ad alice reply 20260101T000000Z-bob-one.md - <<< "a"
    expect 3 - as $ad bob list
    as $ad alice consume 20260101T000000Z-bob-one.md >/dev/null
  done
}

@test "a file name that can be read two ways, or has no stamp, gets the same note, and nothing is sent" {
  for ad in git dir; do
    # (bob about ops-x, or bob-ops about x: names may hold '-', so the note doesn't guess which part is off)
    plant $ad alice 20260101T000000Z-bob-ops-x.md bob x
    expect 1 "20260101T000000Z-bob-ops-x\.md: its file name doesn't name it as from bob about x; answer with send" \
      as $ad alice reply 20260101T000000Z-bob-ops-x.md - <<< "a"
    plant $ad alice 2026-bob-two.md bob two
    expect 1 "2026-bob-two\.md: its file name doesn't name it as from bob about two; answer with send" \
      as $ad alice reply 2026-bob-two.md - <<< "a"
    expect 3 - as $ad bob list
    as $ad alice consume 20260101T000000Z-bob-ops-x.md >/dev/null; as $ad alice consume 2026-bob-two.md >/dev/null
  done
}

@test "a message with no valid from: header is refused" {
  for ad in git dir; do
    plant $ad alice 20260101T000000Z-bob-nofrom.md Bob nofrom
    expect 1 "no valid from: header" as $ad alice reply 20260101T000000Z-bob-nofrom.md - <<< "a"
    as $ad alice consume 20260101T000000Z-bob-nofrom.md >/dev/null
  done
}

@test "outside a strict store, an unsigned message that names its sender is answered, with its status on stderr" {
  for ad in git dir; do
    plant $ad alice 20260101T000000Z-bob-plain.md bob plain
    # (stderr apart from stdout, without bats 1.5's run --separate-stderr)
    status=0; output=$(as $ad alice reply 20260101T000000Z-bob-plain.md - 2>"$T/err" <<< "a") || status=$?; stderr=$(cat "$T/err")
    [ "$status" -eq 0 ] || { echo "$ad: exit $status: $output $stderr"; return 1; }
    printf '%s\n' "$output" | grep -Eq "^sent mailbox/inbox/bob/" || { echo "$ad: $output"; return 1; }
    printf '%s\n' "$stderr" | grep -Eq "20260101T000000Z-bob-plain\.md reads unsigned \(see verify\); answering it anyway" ||
      { echo "$ad stderr: $stderr"; return 1; }
    rid=$(sent_id "$output"); expect 3 - as $ad alice list; as $ad bob consume "$rid" >/dev/null
  done
}

@test "outside a strict store, a misrouted message is refused, and stays in the inbox" {
  for ad in git dir; do
    plant $ad alice 20260101T000000Z-bob-elsewhere.md bob elsewhere carol
    expect 1 "20260101T000000Z-bob-elsewhere\.md reads misrouted \(see verify\), so reply won't answer or consume it" \
      as $ad alice reply 20260101T000000Z-bob-elsewhere.md - <<< "a"
    expect 3 - as $ad bob list
    expect 0 "20260101T000000Z-bob-elsewhere\.md" as $ad alice list
    as $ad alice consume 20260101T000000Z-bob-elsewhere.md >/dev/null
  done
}

@test "outside a strict store, a tampered signed message is refused, and stays in the inbox" {
  [ -n "$SSH" ] || skip "needs ssh-keygen -Y (OpenSSH 8.1+)"
  for ad in git dir; do
    run as $ad bob send alice tampered - <<< "the plan"; id=$(sent_id "$output")
    expect 0 "^verified$" as $ad alice verify "$id"
    tamper $ad "printf 'more\n' >> mailbox/inbox/alice/$id"
    expect 1 "$id reads bad \(see verify\), so reply won't answer or consume it; answer with send" \
      as $ad alice reply "$id" - <<< "a"
    expect 3 - as $ad bob list
    expect 0 "$id" as $ad alice list
    as $ad alice consume "$id" >/dev/null
  done
}

@test "in a store that requires signatures, reply answers only a message that verifies" {
  [ -n "$SSH" ] || skip "needs ssh-keygen -Y (OpenSSH 8.1+)"
  for ad in sgit sdir; do
    plant $ad alice 20260101T000000Z-bob-forged.md bob forged
    expect 1 "requires signatures, and 20260101T000000Z-bob-forged\.md doesn't verify \(unsigned" \
      as $ad alice reply 20260101T000000Z-bob-forged.md - <<< "a"
    expect 3 - as $ad bob list
    as $ad alice consume 20260101T000000Z-bob-forged.md >/dev/null
    run as $ad bob send alice signed - <<< "q"; id=$(sent_id "$output")
    expect 0 "^sent " as $ad alice reply "$id" - <<< "a"; rid=$(sent_id "$output")
    expect 0 "^verified$" as $ad bob verify "$rid"
    expect 3 - as $ad alice list
  done
}

@test "reply's usage errors" {
  expect 1 "usage: reply <file>" as dir alice reply
  expect 1 "usage: reply <file>" as dir alice reply 20260101T000000Z-bob-x.md
  expect 1 "unknown option --consume" as dir alice reply 20260101T000000Z-bob-x.md - --consume x.md
  expect 1 "unknown option --in-reply-to" as dir alice reply 20260101T000000Z-bob-x.md - --in-reply-to x.md
  expect 1 "one message and one body" as dir alice reply 20260101T000000Z-bob-x.md a.md b.md
  expect 1 "--needs needs a value" as dir alice reply 20260101T000000Z-bob-x.md - --needs
  expect 1 "--keep was given twice" as dir alice reply 20260101T000000Z-bob-x.md - --keep --keep
  expect 1 "goes before the command" as dir alice reply --as bob
}

@test "help lists reply" {
  expect 0 "^  reply <file> <body.md\|->" as dir alice help
}
