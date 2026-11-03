#!/bin/sh
# test/run.sh [adapter...]: end-to-end tests of bin/agent-mailbox against throwaway stores. Each simulated agent
# gets its own HOME, so config, keys, pins and the store checkout are as separate as on two machines.
# Needs git; the signature tests need ssh-keygen (OpenSSH 8+) and are skipped without it. Exit 0 when all pass.
# Run it with a specific shell to test that shell: `dash test/run.sh`, `bash test/run.sh`.
set -u
ROOTDIR=$(cd "$(dirname "$0")/.." && pwd -P)
CLI="$ROOTDIR/bin/agent-mailbox"
SH="${TEST_SHELL:-sh}"
ADAPTERS="${*:-git dir}"
# a space in every path, as in a macOS home folder like "/Users/Jo Smith"
W=$(mktemp -d "${TMPDIR:-/tmp}/agent mailbox test.XXXXXX")
trap 'rm -rf "$W"' EXIT
pass=0 fail=0 skip=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/       | /'; }
sk() { skip=$((skip+1)); echo "  skip $1"; }
SSH=""; command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -Y 2>&1 | grep -q 'sign\|usage' && SSH=1

# as <agent> <args...>: run the CLI as that agent, in its own home
as() { a=$1; shift; HOME="$W/home-$a" XDG_CONFIG_HOME= XDG_STATE_HOME= AGENT_MAILBOX_SESSION= CLAUDE_CODE_SESSION_ID= \
       AGENT_MAILBOX_NAME= "$SH" "$CLI" "$@"; }
expect() { # expect <description> <exit code> <grep pattern or -> <command...>
  d=$1 code=$2 pat=$3; shift 3
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" != "$code" ]; then no "$d (exit $rc, wanted $code)" "$out"; return; fi
  if [ "$pat" != - ] && ! echo "$out" | grep -Eq -- "$pat"; then no "$d (output didn't match /$pat/)" "$out"; return; fi
  ok "$d"
}

for AD in $ADAPTERS; do
  echo "== adapter: $AD (shell: $SH)"
  T="$W/$AD"; mkdir -p "$T"
  if [ "$AD" = git ]; then git init -q --bare "$T/store.git"; STORE="$T/store.git"; else STORE="$T/store"; fi
  for a in alice bob carol; do as $a setup --store "$STORE" --adapter "$AD" --name $a >/dev/null; done

  expect "a command before init explains what to do" 1 "init" as alice agents
  expect "init creates the mailbox" 0 "initialized" as alice init
  expect "init refuses to run twice" 1 "already exists" as bob init

  if [ -n "$SSH" ]; then
    expect "register generates a signing key" 0 "signing key" as alice register --kind assistant --about "test agent A"
    expect "a second agent registers" 0 "register: bob" as bob register --kind reviewer --about "test agent B"
  else
    expect "register without ssh-keygen" 0 "register: alice" as alice register --kind assistant --about "test agent A" --no-key
    expect "a second agent registers" 0 "register: bob" as bob register --kind reviewer --about "test agent B" --no-key
  fi
  expect "names are unique" 1 "already registered" as alice register --kind x --about y --no-key
  expect "agents lists both" 0 "bob +active" as carol agents
  expect "an unregistered sender is refused" 1 "register first" sh -c "echo hi | HOME='$W/home-carol' '$SH' '$CLI' send alice hello -"
  expect "an unknown recipient is refused" 1 "isn't an active agent" sh -c "echo hi | HOME='$W/home-alice' '$SH' '$CLI' send nobody hello -"
  expect "a header value can't hold a line break" 1 "line break" as alice send bob hello /dev/null --needs "$(printf 'a\nfrom: bob')"

  echo "please review" > "$T/body"
  expect "send delivers" 0 "^sent mailbox/inbox/bob/" as alice send bob review-1 "$T/body" --needs "a yes or no" --context proj-x
  expect "list shows it to the recipient" 0 "alice-review-1.md" as bob list
  expect "the sender's own inbox is empty" 3 "no mail" as alice list
  if [ -n "$SSH" ]; then expect "read verifies the signature" 0 "\[verified\]" as bob read
  else expect "read marks it unsigned" 0 "\[unsigned\]" as bob read; fi
  expect "read prints the header and body" 0 "needs: a yes or no" as bob read
  f=$(as bob list | head -n 1); fb=$(basename "$f")

  echo "yes" > "$T/reply"
  expect "a reply consumes what it answers" 0 "^sent mailbox/inbox/alice/" as bob send alice review-1-reply "$T/reply" --consume "$fb"
  expect "the consumed message is gone" 3 "no mail" as bob list
  expect "the reply threads to it" 0 "in_reply_to: $fb" as alice read
  r=$(as alice list | head -n 1)
  expect "consume removes a message" 0 "consumed" as alice consume "$(basename "$r")"
  expect "consuming a missing message fails" 1 "not in your inbox" as alice consume "$(basename "$r")"

  # holds: a gate the receiver checks before acting on an item
  expect "send a hold" 0 sent sh -c "echo held | HOME='$W/home-bob' '$SH' '$CLI' send alice gate-1 - --hold 'proj#12 abc1234'"
  expect "holds --version refuses while held" 5 "is held by bob" as alice holds "proj#12" --version abc1234
  expect "send a release" 0 sent sh -c "sleep 1; echo ok | HOME='$W/home-bob' '$SH' '$CLI' send alice gate-2 - --release 'proj#12 abc1234'"
  expect "holds passes on the released version" 0 "released by bob" as alice holds "proj#12" --version abc1234
  expect "a different version isn't released" 5 "not def5678" as alice holds "proj#12" --version def5678
  expect "a malformed hold is refused" 1 "<item> <version>" sh -c "echo x | HOME='$W/home-bob' '$SH' '$CLI' send alice gate-3 - --hold 'no-version'"
  if [ "$AD" = git ]; then
    for m in $(as alice list); do as alice consume "$(basename "$m")" >/dev/null; done
    expect "holds still sees consumed mail (git keeps history)" 0 "released by bob" as alice holds "proj#12" --version abc1234
  fi

  if [ -n "$SSH" ]; then
    # tamper with a delivered message in the store itself, as someone with write access could
    echo "original" > "$T/b2"; as alice send bob tamper-test "$T/b2" >/dev/null
    if [ "$AD" = git ]; then
      git clone -q -b main "$STORE" "$T/evil" && (cd "$T/evil" && git config user.email e@e && git config user.name e &&
        m=$(ls mailbox/inbox/bob/*tamper-test.md) && sed -i.bak 's/original/changed/' "$m" && rm -f "$m.bak" &&
        git commit -qam tamper && git push -q origin HEAD:main)
    else
      m=$(ls "$STORE"/mailbox/inbox/bob/*tamper-test.md); sed -i.bak 's/original/changed/' "$m"; rm -f "$m.bak"
    fi
    expect "a tampered message fails verification" 0 "\[bad\]" as bob read
    expect "verify exits 6 on it" 6 bad as bob verify "$(basename "$(as bob list | grep tamper-test)")"
    # a forged sender: bob writes a message claiming to be from alice, signed with his own key
    if [ "$AD" = git ]; then
      git clone -q -b main "$STORE" "$T/forge" && (cd "$T/forge" && git config user.email e@e && git config user.name e &&
        printf -- '---\nprotocol: 1\nfrom: alice\nto: carol\ntopic: forged\ncontext: general\nsent: 2026-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\n---\n\nhi\n' > mailbox/inbox/bob/20260101T000000Z-alice-forged.md &&
        ssh-keygen -Y sign -q -n agent-mailbox -f "$W/home-bob/.config/agent-mailbox/keys/bob" mailbox/inbox/bob/20260101T000000Z-alice-forged.md &&
        git add -A && git commit -qm forge && git push -q origin HEAD:main)
      expect "a message signed by someone else fails" 0 "forged.md \[(bad|misrouted)\]" as bob read
    fi
    # key rotation in the registry is flagged until the reader trusts it
    if [ "$AD" = git ]; then
      git clone -q -b main "$STORE" "$T/swap" && (cd "$T/swap" && git config user.email e@e && git config user.name e &&
        ssh-keygen -q -t ed25519 -N '' -f "$T/k2" && k=$(cut -d' ' -f1,2 "$T/k2.pub") &&
        sed -i.bak "s|^key: .*|key: $k|" mailbox/agents/alice.md && rm -f mailbox/agents/alice.md.bak &&
        git commit -qam swap && git push -q origin HEAD:main)
      expect "a swapped key reads as changed" 0 "tamper-test.md \[changed\]" as bob read
      expect "trust re-pins it" 0 "pinned alice" as bob trust alice
      expect "after trust, the old signature fails against the new key" 0 "tamper-test.md \[bad\]" as bob read
    fi
  else
    sk "signature tests (no ssh-keygen)"
  fi

  # watch wakes on new mail and times out without it
  for m in $(as bob list 2>/dev/null); do as bob consume "$(basename "$m")" >/dev/null 2>&1; done
  expect "watch times out with no mail" 2 "no mail" as bob watch 1 2
  ( sleep 2; echo ping | HOME="$W/home-alice" "$SH" "$CLI" send bob ping - >/dev/null 2>&1 ) &
  expect "watch wakes on new mail" 0 "alice-ping.md" as bob watch 1 30
  wait

  if [ "$AD" = git ]; then
    # many writers at once: every send lands, none fails
    as carol register --kind t --about t --no-key >/dev/null 2>&1
    for a in d1 d2 d3 d4 d5; do as $a setup --store "$STORE" --name $a >/dev/null; as $a register --kind t --about t --no-key >/dev/null; done
    for a in d1 d2 d3 d4 d5; do ( for i in 1 2 3; do echo "$a $i" | HOME="$W/home-$a" "$SH" "$CLI" send carol "n-$a-$i" - >/dev/null 2>>"$T/conc.err" || echo x >> "$T/conc.fail"; done ) & done
    wait
    got=$(as carol list 2>/dev/null | grep -c '\-n-d')
    [ ! -s "$T/conc.fail" ] && [ "$got" = 15 ] && ok "5 agents x 3 concurrent sends: 15/15 delivered" ||
      no "concurrent sends: $got/15 delivered, $(wc -l < "$T/conc.fail" 2>/dev/null || echo 0) failed" "$(cat "$T/conc.err" 2>/dev/null)"
  fi
done

# --- cases that need their own store -------------------------------------------------------------------------------
case " $ADAPTERS " in *" git "*)
  echo "== git: a store whose default branch isn't the mailbox branch"
  T="$W/branch"; mkdir -p "$T"; git init -q --bare "$T/store.git"
  git clone -q "$T/store.git" "$T/seed" 2>/dev/null && (cd "$T/seed" && git config user.email s@s && git config user.name s &&
    git checkout -q -b trunk && echo "unrelated project file" > app.txt && git add app.txt && git commit -qm app &&
    git push -q origin trunk && git --git-dir="$T/store.git" symbolic-ref HEAD refs/heads/trunk)
  as e1 setup --store "$T/store.git" --name e1 >/dev/null
  expect "init on a store whose default branch is another" 0 initialized as e1 init
  expect "the mailbox branch holds only the mailbox" 0 "^mailbox/store.md$" sh -c "git --git-dir='$T/store.git' ls-tree -r --name-only main | grep store.md"
  [ -z "$(git --git-dir="$T/store.git" ls-tree -r --name-only main | grep app.txt)" ] && ok "trunk's history isn't pulled into main" || no "main carries trunk's files"

  if [ -n "$SSH" ]; then
    echo "== git: replayed releases and required signatures"
    T="$W/strict"; mkdir -p "$T"; git init -q --bare "$T/store.git"
    for a in g1 g2 g3; do as $a setup --store "$T/store.git" --name $a >/dev/null; done
    expect "init a store that requires signatures" 0 "require_signatures: true" as g1 init --require-signatures
    expect "registering without a key is refused" 1 "requires signatures" as g3 register --kind t --about t --no-key
    as g1 register --kind t --about t >/dev/null; as g2 register --kind t --about t >/dev/null
    echo r | as g2 send g1 rel-1 - --release "item#1 v1" >/dev/null
    old=$(as g1 list | head -n 1); cp "$W/home-g1/.local/state/agent-mailbox/checkouts/"*/"$old" "$T/old.md"
    cp "$W/home-g1/.local/state/agent-mailbox/checkouts/"*/"$old.sig" "$T/old.md.sig"
    sleep 1; echo h | as g2 send g1 hold-1 - --hold "item#1 v1" >/dev/null
    expect "the newer hold wins" 5 "is held by g2" as g1 holds "item#1" --version v1
    # someone with write access re-adds the old, validly signed release under a new name
    git clone -q -b main "$T/store.git" "$T/replay" && (cd "$T/replay" && git config user.email e@e && git config user.name e &&
      cp "$T/old.md" "mailbox/inbox/g1/29990101T000000Z-g2-rel-1.md" && cp "$T/old.md.sig" "mailbox/inbox/g1/29990101T000000Z-g2-rel-1.md.sig" &&
      git add -A && git commit -qm replay && git push -q origin HEAD:main)
    expect "a replayed older release doesn't override the hold" 5 "is held by g2" as g1 holds "item#1" --version v1
    # an unsigned forged release is ignored outright in a strict store
    git -C "$T/replay" pull -q --rebase origin main 2>/dev/null; (cd "$T/replay" &&
      printf -- '---\nprotocol: 1\nfrom: g2\nto: g1\ntopic: fake\ncontext: general\nsent: 2999-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\nrelease: item#1 v1\n---\n\nok\n' > mailbox/inbox/g1/29990101T000001Z-g2-fake.md &&
      git add -A && git commit -qm fake && git push -q origin HEAD:main)
    expect "an unsigned release is ignored when signatures are required" 5 "is held by g2" as g1 holds "item#1" --version v1
  fi ;;
esac

echo "== watcher lifecycle and keys (dir)"
T="$W/life"; mkdir -p "$T"
as w1 setup --store "$T/store" --adapter dir --name w1 >/dev/null; as w1 init >/dev/null; as w1 register --kind t --about t --no-key >/dev/null
HOME="$W/home-w1" AGENT_MAILBOX_SESSION=s1 "$SH" "$CLI" watch 1 60 >/dev/null 2>&1 & wp=$!
sleep 1.5; kill -TERM "$wp"; sleep 2.5
if kill -0 "$wp" 2>/dev/null; then no "SIGTERM ends the watcher"; kill -9 "$wp"; else ok "SIGTERM ends the watcher"; fi
[ ! -f "$W/home-w1/.local/state/agent-mailbox/run/w1.pid" ] && ok "the watcher removes its pid file on exit" || no "a pid file was left behind"
expect "a bad root is refused" 1 "root must be" env HOME="$W/home-w1" AGENT_MAILBOX_ROOT=../x "$SH" "$CLI" agents
if [ -n "$SSH" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$T/own" -C own
  as w2 setup --store "$T/store" --adapter dir --name w2 >/dev/null
  expect "register with your own key" 0 "register: w2" as w2 register --kind t --about t --key "$T/own.pub"
  expect "the key path is kept in the config" 0 "^key = .*/own$" grep '^key' "$W/home-w2/.config/agent-mailbox/config"
  expect "later sends are signed with it" 0 "^sent" sh -c "echo hi | HOME='$W/home-w2' '$SH' '$CLI' send w1 signed-own -"
  expect "and verify" 0 "signed-own.md \\[verified\\]" as w1 read
fi

echo "passed $pass, failed $fail, skipped $skip"
[ "$fail" -eq 0 ]
