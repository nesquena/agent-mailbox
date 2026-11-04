#!/bin/sh
# test/run.sh [adapter...]: end-to-end tests of bin/agent-mailbox against throwaway stores. Each simulated agent
# gets its own HOME, so config, keys, pins and the store checkout are as separate as on two machines.
# Needs git; the signature tests need ssh-keygen (OpenSSH 8+) and are skipped without it. Exit 0 when all pass.
# Run it with a specific shell to test that shell: `dash test/run.sh`, `bash test/run.sh`.
set -u
ROOTDIR=$(CDPATH= cd -P -- "$(dirname "$0")/.." && pwd -P)
CLI="$ROOTDIR/bin/agent-mailbox"
SH="${TEST_SHELL:-sh}"
# each simulated agent's HOME must decide its config and state: clear anything the host sets (CI runners set XDG_*)
unset XDG_CONFIG_HOME XDG_STATE_HOME AGENT_MAILBOX_CONFIG AGENT_MAILBOX_STATE AGENT_MAILBOX_NAME AGENT_MAILBOX_STORE \
  AGENT_MAILBOX_ADAPTER AGENT_MAILBOX_ROOT AGENT_MAILBOX_BRANCH AGENT_MAILBOX_KEY AGENT_MAILBOX_SESSION CLAUDE_CODE_SESSION_ID
ADAPTERS="${*:-git dir}"
# a space in every path, as in a macOS home folder like "/Users/Jo Smith"
W=$(mktemp -d "${TMPDIR:-/tmp}/agent mailbox test.XXXXXX")
trap 'rm -rf "$W"' EXIT
pass=0 fail=0 skip=0
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/       | /'; }
sk() { skip=$((skip+1)); echo "  skip $1"; }
SSH=""; command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -Y 2>&1 | grep -Eq 'ssh-keygen -Y (sign|verify)' && SSH=1
# On CI, signatures must be tested, never skipped (REQUIRE_SSH=1 turns a missing ssh-keygen into a failure)
[ -n "$SSH" ] || [ -z "${REQUIRE_SSH:-}" ] || { echo "FAIL ssh-keygen -Y isn't available, and REQUIRE_SSH is set"; exit 1; }

# as <agent> <args...>: run the CLI as that agent, in its own home
as() { a=$1; shift; HOME="$W/home-$a" XDG_CONFIG_HOME= XDG_STATE_HOME= AGENT_MAILBOX_SESSION= CLAUDE_CODE_SESSION_ID= \
       AGENT_MAILBOX_NAME= "$SH" "$CLI" "$@"; }
# in_dir <dir> <command...>: run a command from <dir> (no quoting of the path in a string)
in_dir() { (d=$1; shift; cd "$d" && "$@"); }
# block <agent> <text>: the part of <agent>'s read output for the message whose path contains <text>
block() { as "$1" read 2>/dev/null | awk -v t="$2" '/^===== / && index($0, t) { on = 1 } on && /^===== end/ { on = 0 } on'; }
expect() { # expect <description> <exit code> <grep pattern or -> <command...>
  d=$1 code=$2 pat=$3; shift 3
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" != "$code" ]; then no "$d (exit $rc, wanted $code)" "$out"; return; fi
  if [ "$pat" != - ] && ! printf '%s\n' "$out" | grep -Eq -- "$pat"; then no "$d (output didn't match /$pat/)" "$out"; return; fi
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
  expect "--as after the command is refused, not ignored" 1 "goes before the command" as alice list --as bob
  expect "--as= after the command is refused too" 1 "goes before the command" as alice list --as=bob
  expect "--config after the command is refused" 1 "goes before the command" as alice read --config /nowhere
  expect "help takes anything" 0 "Usage" as alice help --as bob
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
  expect "the reply keeps the thread's context" 0 "context: proj-x" as alice read
  # --in-reply-to alone keeps the context too, and an explicit --context wins
  echo q > "$T/q"; as alice send bob ctx-2 "$T/q" --context proj-y >/dev/null
  c2=$(as bob list | grep 'ctx-2' | head -n 1)
  as bob send alice ctx-2-reply "$T/reply" --in-reply-to "$c2" >/dev/null
  as bob send alice ctx-2-other "$T/reply" --in-reply-to "$c2" --context other >/dev/null
  expect "a reply with --in-reply-to alone keeps the context" 0 "context: proj-y" block alice ctx-2-reply
  expect "an explicit --context wins over the thread's" 0 "context: other" block alice ctx-2-other
  as bob consume "$(basename "$c2")" >/dev/null
  r=$(as alice list | head -n 1)
  expect "consume removes a message" 0 "consumed" as alice consume "$(basename "$r")"
  expect "consuming a missing message fails" 1 "not in your inbox" as alice consume "$(basename "$r")"
  expect "an option's value may be --as" 0 "^sent mailbox/inbox/bob/" as alice send bob opt-value "$T/body" --needs --as
  as bob consume "$(basename "$(as bob list | grep opt-value)")" >/dev/null

  # holds: a gate the receiver checks before acting on an item
  expect "send a hold" 0 sent sh -c "echo held | HOME='$W/home-bob' '$SH' '$CLI' send alice gate-1 - --hold 'proj#12 abc1234'"
  expect "holds --version refuses while held" 5 "is held by bob" as alice holds "proj#12" --version abc1234
  expect "send a release" 0 sent sh -c "sleep 1; echo ok | HOME='$W/home-bob' '$SH' '$CLI' send alice gate-2 - --release 'proj#12 abc1234'"
  expect "holds passes on the released version" 0 "released by bob" as alice holds "proj#12" --version abc1234
  expect "a different version isn't released" 5 "not def5678" as alice holds "proj#12" --version def5678
  expect "a malformed hold is refused" 1 "<item> <version>" sh -c "echo x | HOME='$W/home-bob' '$SH' '$CLI' send alice gate-3 - --hold 'no-version'"
  if [ "$AD" = git ]; then
    for m in $(as alice list 2>/dev/null | grep '\.md$'); do as alice consume "$(basename "$m")" >/dev/null; done
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

  # symlinks planted in the store: never followed, never a wake-up
  for m in $(as bob list 2>/dev/null | grep '\.md$'); do as bob consume "$(basename "$m")" >/dev/null 2>&1; done
  mkdir -p "$W/planted-$AD"
  as vic setup --store "$STORE" --adapter "$AD" --name vic >/dev/null; as vic register --kind t --about t --no-key >/dev/null
  if [ "$AD" = git ]; then
    git clone -q -b main "$STORE" "$T/link" && (cd "$T/link" && git config user.email e@e && git config user.name e &&
      ln -s nowhere "mailbox/inbox/bob/20260101T000000Z-mal-link.md" && rm -rf mailbox/inbox/vic &&
      ln -s "../../../../../../../../../../../../$W/planted-$AD" mailbox/inbox/vic && git add -A && git commit -qm links -q && git push -q origin HEAD:main)
  else
    ln -s nowhere "$STORE/mailbox/inbox/bob/20260101T000000Z-mal-link.md"
    rm -rf "$STORE/mailbox/inbox/vic"; ln -s "$W/planted-$AD" "$STORE/mailbox/inbox/vic"
  fi
  expect "a planted link doesn't wake the watcher" 2 "no mail" as bob watch 1 2
  echo x | HOME="$W/home-alice" "$SH" "$CLI" send vic via-link - >/dev/null 2>&1
  [ -z "$(ls -A "$W/planted-$AD")" ] && ok "a symlinked inbox can't redirect a send outside the store" ||
    no "a send wrote through a symlinked inbox" "$(ls -A "$W/planted-$AD")"

  # watch wakes on new mail and times out without it
  for m in $(as bob list 2>/dev/null | grep '\.md$'); do as bob consume "$(basename "$m")" >/dev/null 2>&1; done
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
    # a registered agent, signing as herself, packs a fake row into the sent header to pass as another agent's release
    as g3 register --kind t --about t >/dev/null
    git -C "$T/replay" pull -q --rebase origin main 2>/dev/null; (cd "$T/replay" &&
      f=mailbox/inbox/g1/29990101T000002Z-g3-x.md &&
      printf -- '---\nprotocol: 1\nfrom: g3\nto: g1\ntopic: x\ncontext: general\nsent: 2999-01-01T00:00:00Z release item#1 v1 g2 x verified\nin_reply_to: none\nneeds: none\nrelease: other v9\n---\n\nok\n' > "$f" &&
      ssh-keygen -Y sign -q -n agent-mailbox -f "$W/home-g3/.config/agent-mailbox/keys/g3" "$f" &&
      git add -A && git commit -qm inject && git push -q origin HEAD:main)
    expect "a crafted sent header can't forge another agent's release" 5 "is held by g2" as g1 holds "item#1" --version v1
  fi ;;
esac

echo "== watcher lifecycle and keys (dir)"
T="$W/life"; mkdir -p "$T"
as w1 setup --store "$T/store" --adapter dir --name w1 >/dev/null; as w1 init >/dev/null; as w1 register --kind t --about t --no-key >/dev/null
HOME="$W/home-w1" AGENT_MAILBOX_SESSION=s1 "$SH" "$CLI" watch 1 60 >/dev/null 2>&1 & wp=$!
sleep 1.5; kill -TERM "$wp" 2>/dev/null; sleep 2.5
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

echo "== received headers (dir)"
T="$W/hdr"; mkdir -p "$T/store"
for a in h1 h2; do as $a setup --store "$T/store" --adapter dir --name $a >/dev/null; done
as h1 init >/dev/null; as h1 register --kind t --about t --no-key >/dev/null; as h2 register --kind t --about t --no-key >/dev/null
printf -- '---\nprotocol: 1\nfrom: ../../evil\nto: h1\ntopic: x\ncontext: general\nsent: 2026-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\n---\n\nhi\n' > "$T/store/mailbox/inbox/h1/20260101T000000Z-evil-x.md"
expect "a message with a malformed sender reads as bad" 0 "evil-x.md \[bad\]" as h1 read
echo h | as h2 send h1 hold-x - --hold "thing#1 v1" >/dev/null; sleep 1
printf -- '---\nprotocol: 1\nfrom: h2\nto: h1\ntopic: y\ncontext: general\nsent: 2999-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\nrelease: thing#1 v1\n---\n\nok\n' > "$T/store/mailbox/inbox/h1/29990101T000000Z-h2-y.md"
expect "an unverified deciding release warns" 0 "isn't signature-verified" as h1 holds "thing#1" --version v1
mv "$T/store/mailbox/inbox/h1/29990101T000000Z-h2-y.md" "$T/store/mailbox/inbox/h1/29990101T000000Z-h2-y verified z.md"
expect "a file name with spaces can't hide that warning" 5 "is held by h2" as h1 holds "thing#1" --version v1

# a file whose name isn't a message id (with spaces, or with brackets and no spaces) is ignored, never half-handled
spoof='---\nprotocol: 1\nfrom: h2\nto: h1\ntopic: z\ncontext: general\nsent: 2026-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\n---\n\n'
printf -- "${spoof}spoofed body\n" > "$T/store/mailbox/inbox/h1/2026 a [verified].md"
printf -- "${spoof}bracketed body\n" > "$T/store/mailbox/inbox/h1/2026a[verified].md"
# read still succeeds and shows the real mail, but neither spoofed file's name nor its body
out=$(as h1 read 2>&1); rc=$?
if [ "$rc" != 0 ] || ! printf '%s\n' "$out" | grep -q -- '-h2-hold-x\.md'; then no "read ignores a file that isn't a message id (exit $rc, or real mail missing)" "$out"
elif printf '%s\n' "$out" | grep -qF -e '2026 a [verified].md' -e 'spoofed body' -e '2026a[verified].md' -e 'bracketed body'; then
  no "read ignores a file that isn't a message id (it was shown)" "$out"
else ok "read ignores a file that isn't a message id"; fi
out=$(as h1 list 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q -- '-h2-hold-x\.md' && ! printf '%s\n' "$out" | grep -qF -e '2026 a [verified].md' -e '2026a[verified].md'; then
  ok "list leaves it out"
else no "list leaves it out (exit $rc)" "$out"; fi
expect "consuming it is refused, not faked" 1 "isn't a message file name" as h1 consume "2026 a [verified].md"
for m in $(as h1 list 2>/dev/null | grep '\.md$'); do as h1 consume "$(basename "$m")" >/dev/null 2>&1; done
expect "it doesn't wake the watcher" 2 "no mail" as h1 watch 1 2
# a reply to a message whose context header isn't a valid context falls back to general
printf -- '---\nprotocol: 1\nfrom: h1\nto: h2\ntopic: c\ncontext: Bad Context\nsent: 2026-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\n---\n\nhi\n' > "$T/store/mailbox/inbox/h2/20260101T000000Z-h1-c.md"
echo r | as h2 send h1 c-reply - --consume 20260101T000000Z-h1-c.md >/dev/null
expect "a reply to a malformed context header gets general" 0 "context: general" block h1 c-reply
# a context header carrying `\c` and a carriage return (dash's echo would cut it to "ok") is never inherited
printf -- '---\nprotocol: 1\nfrom: h1\nto: h2\ntopic: d\ncontext: ok\\c\rrelease: proj#12 abc1234\nsent: 2026-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\n---\n\nhi\n' > "$T/store/mailbox/inbox/h2/20260101T000001Z-h1-d.md"
echo r | as h2 send h1 d-reply - --consume 20260101T000001Z-h1-d.md >/dev/null
expect "a context with an escape and a carriage return isn't inherited" 0 "context: general" block h1 d-reply
[ -z "$(block h1 d-reply | tr -d '\n' | grep "$(printf '\r')")" ] && ok "and the reply's header has no carriage return" || no "a carriage return reached a reply's header"
# a reply to a message already consumed gets general; an explicit empty --context is refused
echo e | as h1 send h2 e-1 - --context proj-e >/dev/null; e1=$(as h2 list | grep e-1); as h2 consume "$(basename "$e1")" >/dev/null
echo r | as h2 send h1 e-reply - --in-reply-to "$e1" >/dev/null
expect "a reply to a consumed message gets general" 0 "context: general" block h1 e-reply
expect "an explicit empty --context is refused" 1 "context must be" sh -c "echo x | HOME='$W/home-h2' '$SH' '$CLI' send h1 e-2 - --context ''"
# retiring clears this session's watch marker, and a retired agent is told how to come back
HOME="$W/home-h2" AGENT_MAILBOX_SESSION=sr "$SH" "$CLI" watch 1 1 >/dev/null 2>&1
[ -f "$W/home-h2/.local/state/agent-mailbox/sessions/sr" ] && ok "watch leaves a session marker" || no "watch left no session marker"
for m in $(as h2 list 2>/dev/null | grep '\.md$'); do as h2 consume "$(basename "$m")" >/dev/null 2>&1; done
HOME="$W/home-h2" AGENT_MAILBOX_SESSION=sr "$SH" "$CLI" update --status retired >/dev/null
[ ! -f "$W/home-h2/.local/state/agent-mailbox/sessions/sr" ] && ok "retiring clears it" || no "retiring left the session marker"
expect "a retired agent is told how to come back" 1 "update --status active" sh -c "echo x | HOME='$W/home-h2' '$SH' '$CLI' send h1 r-1 -"

if [ -n "$SSH" ]; then
echo "== strict stores fail closed (git)"
T="$W/strict2"; mkdir -p "$T"; git init -q --bare "$T/store.git"
for a in k1 k2 k3; do as $a setup --store "$T/store.git" --name $a >/dev/null; done
as k1 init --require-signatures >/dev/null; for a in k1 k2 k3; do as $a register --kind t --about t >/dev/null; done
git clone -q -b main "$T/store.git" "$T/w" && git -C "$T/w" config user.email e@e && git -C "$T/w" config user.name e
wr() { (cd "$T/w" && git pull -q --rebase origin main 2>/dev/null && "$@" && git add -A && git commit -qm w && git push -q origin HEAD:main); }
# k3 releases and k2 holds the same version; k1 has checked holds once, so it has pinned both keys
echo r | as k3 send k1 ra - --release "a#1 v1" >/dev/null; echo h | as k2 send k1 ha - --hold "a#1 v1" >/dev/null
echo r | as k3 send k1 rb - --release "b#1 v1" >/dev/null; echo h | as k2 send k1 hb - --hold "b#1 v1" >/dev/null
expect "a signed hold holds" 5 "a#1 is held by k2" as k1 holds "a#1" --version v1
as k1 holds "b#1" --version v1 >/dev/null 2>&1
# someone with write access swaps k2's key in the registry: its hold reads changed, and must still hold
ssh-keygen -q -t ed25519 -N '' -f "$T/swap" -C swap
wr sh -c "sed 's|^key: .*|key: $(cut -d' ' -f1,2 "$T/swap.pub")|' mailbox/agents/k2.md > mailbox/agents/k2.t && mv mailbox/agents/k2.t mailbox/agents/k2.md"
expect "a hold whose sender's key was swapped still holds" 5 "a#1 is held by k2 .*changed" as k1 holds "a#1" --version v1
# ... or deletes k2's record: its hold reads nokey, and must still hold
wr git rm -q mailbox/agents/k2.md mailbox/agents/k2.md.sig
expect "a hold whose sender's record was removed still holds" 5 "b#1 is held by k2 .*nokey" as k1 holds "b#1" --version v1
# store.md is edited to stop requiring signatures, and an unsigned release "from k3" is planted after k3's signed hold
echo h | as k3 send k1 hc - --hold "c#1 v1" >/dev/null
wr sh -c "sed 's/^require_signatures: true/require_signatures: false/' mailbox/store.md > mailbox/store.t && mv mailbox/store.t mailbox/store.md &&
  printf -- '---\nprotocol: 1\nfrom: k3\nto: k1\ntopic: rc\ncontext: general\nsent: 2999-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\nrelease: c#1 v1\n---\n\nok\n' > mailbox/inbox/k1/29990101T000000Z-k3-rc.md"
expect "a store seen strict stays strict after store.md is edited" 5 "c#1 is held by k3" as k1 holds "c#1" --version v1
expect "and says so" 5 "still treating this store as strict" as k1 holds "c#1" --version v1
expect "trust --relax ends that" 0 "strict for you only while" as k1 trust --relax
expect "after which the store's own setting applies" 0 "c#1 released by k3" as k1 holds "c#1" --version v1
# a history git can't read in full stops holds, rather than deciding from part of it
mkdir -p "$T/shim"; printf '#!/bin/sh\nfor a; do case "$a" in -G*) exit 128 ;; esac; done\nexec "%s" "$@"\n' "$(command -v git)" > "$T/shim/git"; chmod +x "$T/shim/git"
expect "holds stops when it can't read the history" 1 "can't read this store's full history" env PATH="$T/shim:$PATH" HOME="$W/home-k1" "$SH" "$CLI" holds "a#1" --version v1
fi

echo "== installed link (install.sh)"
T="$W/inst"; mkdir -p "$T"
expect "install.sh links the CLI" 0 "linked" env HOME="$W/home-i1" "$SH" "$ROOTDIR/install.sh" --prefix "$T/prefix"
# a link to a link, as a package manager's shim might add
ln -s "$T/prefix/bin/agent-mailbox" "$T/shim"
for link in "$T/prefix/bin/agent-mailbox" "$T/shim"; do
  expect "the linked CLI finds its adapters ($(basename "$link"))" 0 "initialized" \
    env HOME="$W/home-i-$(basename "$link")" AGENT_MAILBOX_STORE="$T/store-$(basename "$link")" AGENT_MAILBOX_ADAPTER=dir "$SH" "$link" init
done
# a relative link with '..' to the script, reached through a linked folder, as a package installs it on a merged /usr
# (/bin -> usr/bin, /usr/bin/x -> ../share/x/bin/x): '..' must resolve physically, from usr/bin, not from bin
mkdir -p "$T/usr/bin" "$T/usr/share/am"; cp -R "$ROOTDIR/bin" "$ROOTDIR/adapters" "$T/usr/share/am/"
ln -s usr/bin "$T/bin"; ln -s ../share/am/bin/agent-mailbox "$T/usr/bin/am"
# a decoy at the logical (wrong) path: a CLI that resolves '..' logically sources it, in every shell
mkdir -p "$T/share/am/bin" "$T/share/am/adapters"; printf 'echo decoy adapter >&2; exit 9\n' > "$T/share/am/adapters/dir.sh"
expect "a relative link through a linked folder finds its adapters" 0 "initialized" \
  env HOME="$W/home-i-rel" AGENT_MAILBOX_STORE="$T/store-rel" AGENT_MAILBOX_ADAPTER=dir "$SH" "$T/bin/am" init
# a relative invocation with CDPATH exported: cd mustn't print or jump elsewhere
expect "an exported CDPATH doesn't break the lookup" 0 "initialized" env CDPATH=. HOME="$W/home-i-cdp" \
  AGENT_MAILBOX_STORE="$T/store-cdp" AGENT_MAILBOX_ADAPTER=dir sh -c "cd '$ROOTDIR' && '$SH' bin/agent-mailbox init"

# install.sh by a relative path, with CDPATH exported, links the right file
P=$(dirname "$ROOTDIR"); B=$(basename "$ROOTDIR")
(cd "$P" && CDPATH=. "$SH" "$B/install.sh" --prefix "$T/prefix-cdp" >/dev/null 2>&1)
got=$(readlink "$T/prefix-cdp/bin/agent-mailbox" 2>/dev/null)
[ "$got" = "$ROOTDIR/bin/agent-mailbox" ] && ok "install.sh by relative path with CDPATH exported links the right file" ||
  no "install.sh by relative path with CDPATH exported links the right file" "link target: $got"
if [ -n "$SSH" ]; then
  mkdir -p "$T/k"; ssh-keygen -q -t ed25519 -N '' -f "$T/k/rel" -C rel
  as kr setup --store "$T/store-kr" --adapter dir --name kr >/dev/null; as kr init >/dev/null
  expect "register --key by relative path with CDPATH exported keeps the right key" 0 "^key = .*/k/rel$" sh -c \
    "cd '$T' && HOME='$W/home-kr' CDPATH=. '$SH' '$CLI' register --kind t --about t --key k/rel.pub >/dev/null && grep '^key' '$W/home-kr/.config/agent-mailbox/config'"
fi
# `bash agent-mailbox` found through PATH gets $0 without a slash: it must not load adapters from beside the
# current folder (here, a planted one), and doctor must say why
if command -v bash >/dev/null 2>&1; then
  mkdir -p "$T/evil/adapters" "$T/evil/work" "$T/pathbin"; ln -s "$ROOTDIR/bin/agent-mailbox" "$T/pathbin/agent-mailbox"
  printf 'echo planted adapter >&2; exit 9\n' > "$T/evil/adapters/dir.sh"
  ev="cd '$T/evil/work' && HOME='$W/home-ev' PATH='$T/pathbin':\"\$PATH\" AGENT_MAILBOX_STORE='$T/store-ev' AGENT_MAILBOX_ADAPTER=dir"
  expect "bash with the CLI found on PATH doesn't load an adapter from beside the current folder" 1 "can't find the folder" \
    sh -c "$ev bash agent-mailbox init"
  expect "doctor says the adapters folder wasn't found" 1 "FAIL the CLI finds its adapter" sh -c "$ev bash agent-mailbox doctor"
fi
# a copy of the script without its adapters folder: doctor says so
mkdir -p "$T/lone/bin"; cp "$ROOTDIR/bin/agent-mailbox" "$T/lone/bin/"
expect "doctor flags a CLI copied without its adapters" 1 "FAIL the CLI finds its adapter" \
  env HOME="$W/home-lone" AGENT_MAILBOX_STORE="$T/store-lone" AGENT_MAILBOX_ADAPTER=dir "$SH" "$T/lone/bin/agent-mailbox" doctor
# a relative dir store, with CDPATH naming another folder of the same name: watch must look in the real store
mkdir -p "$T/rel/other/st"
for a in r1 r2; do (cd "$T/rel" && HOME="$W/home-$a" "$SH" "$CLI" setup --store st --adapter dir --name $a >/dev/null); done
(cd "$T/rel" && HOME="$W/home-r1" "$SH" "$CLI" init >/dev/null && HOME="$W/home-r1" "$SH" "$CLI" register --kind t --about t --no-key >/dev/null &&
  HOME="$W/home-r2" "$SH" "$CLI" register --kind t --about t --no-key >/dev/null && echo hi | HOME="$W/home-r1" "$SH" "$CLI" send r2 rel -)  >/dev/null 2>&1
expect "watch on a relative dir store ignores CDPATH" 0 "r1-rel.md" sh -c "cd '$T/rel' && HOME='$W/home-r2' CDPATH='$T/rel/other' '$SH' '$CLI' watch 1 3"
echo "== doctor, messages and odd values (dir)"
T="$W/odd/O'Brien"; mkdir -p "$T"
for a in o1 o2; do as $a setup --store "$T/store" --adapter dir --name $a >/dev/null; done
as o1 init >/dev/null; for a in o1 o2; do as $a register --kind t --about t --no-key >/dev/null; done
out=$(as o1 doctor 2>&1)
printf '%s\n' "$out" | grep -q "ok   a store is configured" && printf '%s\n' "$out" | grep -q "ok   the CLI finds its adapter" &&
  ok "doctor runs every check with a ' and a space in the store path" || no "doctor with a ' in the store path" "$out"
expect "doctor flags a malformed adapter name" 1 "FAIL the CLI finds its adapter" \
  env HOME="$W/home-o1" AGENT_MAILBOX_ADAPTER=../adapters/dir "$SH" "$CLI" doctor
echo "dash body" > "$T/--as"
expect "a body file named like an option is read" 0 "^sent " sh -c "cd '$W/odd' && cd \"O'Brien\" && HOME='$W/home-o1' '$SH' '$CLI' send o2 dash-body --as"
# a message whose name starts with '-': --except must take it as a file name and hide it
cp "$(ls "$T"/store/mailbox/inbox/o2/*dash-body.md)" "$T/store/mailbox/inbox/o2/-x.md"
expect "watch --except takes a value starting with - as a file name" 2 "no mail" \
  as o2 watch 1 2 --except -x.md --except "$(basename "$(ls "$T"/store/mailbox/inbox/o2/*dash-body.md)")"
out=$(as o2 read --except -x.md 2>&1); rc=$?
hit=$(printf '%s\n' "$out" | grep -c -e '/-x\.md' -e basename)
if [ "$rc" = 0 ] && [ "$hit" = 0 ] && printf '%s\n' "$out" | grep -q 'dash-body.md'; then ok "an --except value starting with - is a file name"
else no "an --except value starting with - is a file name (exit $rc)" "$out"; fi
expect "trust refuses a misplaced --as" 1 "goes before the command" as o1 trust o2 --as o2
expect "an error quotes a value as given" 1 "v1.cZ" as o1 send o2 h - --hold 'p#1 v1\cZ'
# a mailbox folder starting with '-' is refused (find and basename would read it as an option)
as o3 setup --store "$T/store-dash" --adapter dir --root -mb --name o3 >/dev/null
expect "a root part starting with - is refused" 1 "root must be" as o3 init
expect "and doctor says why" 1 "FAIL the mailbox folder \(root\) is valid" as o3 doctor
expect "a root part named .git is refused" 1 "root must be" env HOME="$W/home-o3" AGENT_MAILBOX_ROOT=x/.git "$SH" "$CLI" init
expect "in any case (a case-insensitive disk makes .GIT git's own folder)" 1 "root must be" env HOME="$W/home-o3" AGENT_MAILBOX_ROOT=x/.GIT "$SH" "$CLI" init
# a backslash in the store path (paths are printed with printf, never echo)
for a in o4 o5; do as $a setup --store "$T/st\tore" --adapter dir --name $a >/dev/null; done
as o4 init >/dev/null; as o4 register --kind t --about t --no-key >/dev/null; as o5 register --kind t --about t --no-key >/dev/null
expect "a backslash in the store path works" 0 "^sent " sh -c "echo hi | HOME='$W/home-o4' '$SH' '$CLI' send o5 bs -"
expect "and the mail is listed" 0 '^mailbox/inbox/o5/[^/]*-o4-bs\.md$' as o5 list
expect "and read" 0 '^===== mailbox/inbox/o5/[^/]*-o4-bs\.md \[' as o5 read
# a backslash in the home folder, with the git adapter (its checkout and keys live under HOME)
git init -q --bare "$T/bs.git"
for a in q1 q2; do HOME="$W/h\tq-$a" "$SH" "$CLI" setup --store "$T/bs.git" --name $a >/dev/null; done
HOME="$W/h\tq-q1" "$SH" "$CLI" init >/dev/null
for a in q1 q2; do HOME="$W/h\tq-$a" "$SH" "$CLI" register --kind t --about t >/dev/null 2>&1; done
expect "a backslash in the home folder works (git adapter)" 0 "^sent " sh -c "echo hi | HOME='$W/h\tq-q1' '$SH' '$CLI' send q2 hq -"
if [ -n "$SSH" ]; then st=verified; else st=unsigned; fi
expect "and the mail is read, $st" 0 "^===== mailbox/inbox/q2/[^/]*-q1-hq\\.md \\[$st\\]" env HOME="$W/h\tq-q2" "$SH" "$CLI" read
# options' values starting with '-': --in-reply-to and --consume take them as file names; verify too
mv "$T/store/mailbox/inbox/o2/-x.md" "$T/store/mailbox/inbox/o2/-y.md" 2>/dev/null || cp "$(ls "$T"/store/mailbox/inbox/o2/*dash-body.md)" "$T/store/mailbox/inbox/o2/-y.md"
expect "send --consume takes a value starting with - as a file name" 0 "^sent " sh -c "echo r | HOME='$W/home-o2' '$SH' '$CLI' send o1 c-y - --in-reply-to -y.md --consume -y.md"
[ ! -e "$T/store/mailbox/inbox/o2/-y.md" ] && ok "and consumes it" || no "send --consume left -y.md in the inbox"
# --in-reply-to alone, with a value starting with '-'
cp "$(ls "$T"/store/mailbox/inbox/o2/*dash-body.md)" "$T/store/mailbox/inbox/o2/-w.md"
echo r | as o2 send o1 c-w - --in-reply-to -w.md >/dev/null
expect "send --in-reply-to alone takes a value starting with - as a file name" 0 "in_reply_to: -w\.md" block o1 c-w
expect "verify refuses a misplaced --as" 1 "goes before the command" as o1 verify x.md --as o2
expect "verify takes a name, never a pattern" 1 "no such message" as o1 verify '*.md'
cp "$(ls "$T"/store/mailbox/inbox/o1/*c-y.md)" "$T/store/mailbox/inbox/o1/-z.md"
expect "verify takes a name starting with - as a file name" 6 "^(unsigned|nokey)$" env HOME="$W/home-o1" "$SH" "$CLI" verify -z.md
# a dir store given by a relative path starting with '-'
mkdir -p "$T/rel2"
for a in d1 d2; do (cd "$T/rel2" && HOME="$W/home-$a" "$SH" "$CLI" setup --store -ds --adapter dir --name $a >/dev/null); done
(cd "$T/rel2" && HOME="$W/home-d1" "$SH" "$CLI" init >/dev/null && HOME="$W/home-d1" "$SH" "$CLI" register --kind t --about t --no-key >/dev/null &&
  HOME="$W/home-d2" "$SH" "$CLI" register --kind t --about t --no-key >/dev/null && echo hi | HOME="$W/home-d1" "$SH" "$CLI" send d2 dd - >/dev/null 2>&1)
expect "a dir store at a relative path starting with - lists mail" 0 "d1-dd\.md" in_dir "$T/rel2" env HOME="$W/home-d2" "$SH" "$CLI" list
# watch must notice mail that arrives while it waits (its poll reads the store too)
in_dir "$T/rel2" env HOME="$W/home-d2" "$SH" "$CLI" consume "$(basename "$(in_dir "$T/rel2" env HOME="$W/home-d2" "$SH" "$CLI" list | grep d1-dd)")" >/dev/null
( sleep 2; echo hi | in_dir "$T/rel2" env HOME="$W/home-d1" "$SH" "$CLI" send d2 dd2 - >/dev/null 2>&1 ) &
expect "and watch wakes on new mail" 0 "d1-dd2\.md" in_dir "$T/rel2" env HOME="$W/home-d2" "$SH" "$CLI" watch 1 8
wait
# a git store given by a path starting with '-' is a path, never an option to git clone
mkdir -p "$T/rel3"; git init -q --bare "$T/rel3/-st.git"
expect "a git store at a relative path starting with - works" 0 "initialized" in_dir "$T/rel3" env HOME="$W/home-g9" AGENT_MAILBOX_STORE=-st.git "$SH" "$CLI" init

echo "== holds and header rules (git)"
T="$W/rules"; mkdir -p "$T"; git init -q --bare "$T/store.git"
for a in u1 u2; do as $a setup --store "$T/store.git" --name $a >/dev/null; done
as u1 init >/dev/null; for a in u1 u2; do as $a register --kind t --about t --no-key >/dev/null; done
echo h | as u2 send u1 h-8 - --hold "item#8 v1" >/dev/null; echo h | as u2 send u1 h-9 - --hold "item#9 v1" >/dev/null
# planted by someone with write access: a release in a subfolder of the inbox, and one in a header that never closes
git clone -q -b main "$T/store.git" "$T/plant" && (cd "$T/plant" && git config user.email e@e && git config user.name e &&
  mkdir -p mailbox/inbox/u1/sub &&
  printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: r\ncontext: general\nsent: 2999-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\nrelease: item#8 v1\n---\n\nok\n' > mailbox/inbox/u1/sub/29990101T000000Z-u2-r.md &&
  printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: open\ncontext: general\nsent: 2999-01-01T00:00:01Z\nin_reply_to: none\nneeds: none\nrelease: item#9 v1\n\nno closing line\n' > mailbox/inbox/u1/29990101T000001Z-u2-open.md &&
  git add -A && git commit -qm plant && git push -q origin HEAD:main)
expect "holds ignores a release in a subfolder of the inbox" 5 "is held by u2" as u1 holds "item#8" --version v1
expect "and one whose header never closes" 5 "is held by u2" as u1 holds "item#9" --version v1
expect "read marks a header that never closes as bad" 0 "u2-open\.md \[bad\]" as u1 read
# a hold written without a space after the colon is still a hold (field() strips one space only if it's there): a
# holds pattern that required the space would miss it, and an older release would then pass
echo r | as u2 send u1 r-7 - --release "item#7 v1" >/dev/null; sleep 1
(cd "$T/plant" && git pull -q --rebase origin main 2>/dev/null &&
  printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: h7\ncontext: general\nsent: 2999-01-01T00:00:02Z\nin_reply_to: none\nneeds: none\nhold:item#7 v1\n---\n\nheld\n' > mailbox/inbox/u1/29990101T000002Z-u2-h7.md &&
  git add -A && git commit -qm h7 && git push -q origin HEAD:main)
expect "a hold with no space after the colon still holds" 5 "is held by u2" as u1 holds "item#7" --version v1
# A store writer can't hide a hold from holds, however the file got into history. In each case below the hold is
# newer than a release of the same version, so a hidden hold would let the release pass (exit 0).
pl() { (cd "$T/plant" && git pull -q --rebase origin main 2>/dev/null && "$@" && git add -A && git commit -qm plant && git push -q origin HEAD:main); }
# 1. an attribute that makes git treat the hold as binary
echo r | as u2 send u1 r-6 - --release "item#6 v1" >/dev/null; sleep 1; echo h | as u2 send u1 h-6 - --hold "item#6 v1" >/dev/null
pl sh -c 'printf "%s -diff\n" "$(basename "$(ls mailbox/inbox/u1/*-u2-h-6.md)")" > mailbox/inbox/u1/.gitattributes'
expect "a hold still counts when an attribute marks it binary" 5 "item#6 is held by u2" as u1 holds "item#6" --version v1
pl rm -f mailbox/inbox/u1/.gitattributes
# 2. a NUL byte in the hold
echo r | as u2 send u1 r-5 - --release "item#5 v1" >/dev/null; sleep 1
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: h5\ncontext: general\nsent: 2999-01-01T00:00:03Z\nin_reply_to: none\nneeds: none\nhold: item#5 v1\n---\n\nnul \000 byte\n' > mailbox/inbox/u1/29990101T000003Z-u2-h5.md"
expect "a hold in a message with a NUL byte still counts" 5 "item#5 is held by u2" as u1 holds "item#5" --version v1
# 3. an earlier release renamed to a new name and rewritten as a newer hold, in one commit
echo r | as u2 send u1 r-4 - --release "item#4 v1" >/dev/null; sleep 1
pl sh -c 'old=$(ls mailbox/inbox/u1/*-u2-r-4.md) && new=mailbox/inbox/u1/29990101T000004Z-u2-h4.md && git mv "$old" "$new" &&
  sed "s/^release: item#4 v1\$/hold: item#4 v1/; s/^sent: .*/sent: 2999-01-01T00:00:04Z/" "$new" > "$new.t" && mv "$new.t" "$new"'
expect "a hold renamed into the inbox still counts" 5 "item#4 is held by u2" as u1 holds "item#4" --version v1
# 4. an earlier release rewritten in place as a newer hold
echo r | as u2 send u1 r-3 - --release "item#3 v1" >/dev/null; sleep 1
pl sh -c 'f=$(ls mailbox/inbox/u1/*-u2-r-3.md) && sed "s/^release: item#3 v1\$/hold: item#3 v1/; s/^sent: .*/sent: 2999-01-01T00:00:05Z/" "$f" > "$f.t" && mv "$f.t" "$f"'
expect "a hold rewritten in place still counts" 5 "item#3 is held by u2" as u1 holds "item#3" --version v1
# 4b. a hold with an old sent time, then rewritten in place so only its sent line changes (later than a release)
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: h13\ncontext: general\nsent: 2000-01-01T00:00:00Z\nin_reply_to: none\nneeds: none\nhold: item#13 v1\n---\n\nheld\n' > mailbox/inbox/u1/20000101T000000Z-u2-h13.md"
echo r | as u2 send u1 r-13 - --release "item#13 v1" >/dev/null
pl sh -c 'f=mailbox/inbox/u1/20000101T000000Z-u2-h13.md && sed "s/^sent: .*/sent: 2999-01-01T00:00:08Z/" "$f" > "$f.t" && mv "$f.t" "$f"'
expect "a hold whose rewrite changes only its sent line still counts" 5 "item#13 is held by u2" as u1 holds "item#13" --version v1
# 5. a merge whose inbox tree drops the hold, so a history walk with neither -m nor --full-history never visits the commit
# that added it
echo r | as u2 send u1 r-2 - --release "item#2 v1" >/dev/null
(cd "$T/plant" && git pull -q --rebase origin main 2>/dev/null) && base=$(git -C "$T/plant" rev-parse HEAD)
sleep 1; echo h | as u2 send u1 h-2 - --hold "item#2 v1" >/dev/null
(cd "$T/plant" && git checkout -q -b side "$base" && echo x > note.txt && git add note.txt && git commit -qm side &&
  git fetch -q origin main && git checkout -q -B m origin/main && { git merge -q --no-ff --no-commit side >/dev/null 2>&1 || :; } &&
  git rm -q -r mailbox/inbox/u1 && git checkout side -- mailbox/inbox/u1 && git commit -qm merge && git push -q origin HEAD:main &&
  git checkout -q main && git reset -q --hard origin/main)
expect "a hold dropped by a merge still counts" 5 "item#2 is held by u2" as u1 holds "item#2" --version v1
# 6. a hold that exists only in a merge commit (in neither parent), read by a user whose git config turns merge diffs off
echo r | as u2 send u1 r-11 - --release "item#11 v1" >/dev/null; sleep 1
(cd "$T/plant" && git pull -q --rebase origin main 2>/dev/null && base=$(git rev-parse HEAD) &&
  git checkout -q -b side2 "$base" && echo y > note2.txt && git add note2.txt && git commit -qm side2 && git checkout -q main &&
  echo z > note3.txt && git add note3.txt && git commit -qm main3 && { git merge -q --no-ff --no-commit side2 >/dev/null 2>&1 || :; } &&
  printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: h11\ncontext: general\nsent: 2999-01-01T00:00:06Z\nin_reply_to: none\nneeds: none\nhold: item#11 v1\n---\n\nheld\n' > mailbox/inbox/u1/29990101T000006Z-u2-h11.md &&
  git add -A && git commit -qm evil-merge && git push -q origin HEAD:main)
printf '[log]\n\tdiffMerges = off\n' >> "$W/home-u1/.gitconfig"
expect "a hold only in a merge commit still counts, whatever the reader's git config" 5 "item#11 is held by u2" as u1 holds "item#11" --version v1
sed -i.bak '/diffMerges/d; /^\[log\]$/d' "$W/home-u1/.gitconfig"; rm -f "$W/home-u1/.gitconfig.bak"
# 7. a hold and a release with the same sent time: the hold counts, whatever order history puts them in
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: h12\ncontext: general\nsent: 2999-01-01T00:00:07Z\nin_reply_to: none\nneeds: none\nhold: item#12 v1\n---\n\nheld\n' > mailbox/inbox/u1/29990101T000007Z-u2-h12.md"
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: r12\ncontext: general\nsent: 2999-01-01T00:00:07Z\nin_reply_to: none\nneeds: none\nrelease: item#12 v1\n---\n\nok\n' > mailbox/inbox/u1/29990101T000007Z-u2-r12.md"
expect "on an equal sent time, a hold beats a later release" 5 "item#12 is held by u2" as u1 holds "item#12" --version v1
# 7b. the same, with the release first in history
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: r16\ncontext: general\nsent: 2999-01-01T00:00:10Z\nin_reply_to: none\nneeds: none\nrelease: item#16 v1\n---\n\nok\n' > mailbox/inbox/u1/29990101T000010Z-u2-r16.md"
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: h16\ncontext: general\nsent: 2999-01-01T00:00:10Z\nin_reply_to: none\nneeds: none\nhold: item#16 v1\n---\n\nheld\n' > mailbox/inbox/u1/29990101T000010Z-u2-h16.md"
expect "on an equal sent time, a hold beats an earlier release" 5 "item#16 is held by u2" as u1 holds "item#16" --version v1
# 8. two releases with the same sent time naming different versions conflict: neither counts
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: r14a\ncontext: general\nsent: 2999-01-01T00:00:09Z\nin_reply_to: none\nneeds: none\nrelease: item#14 v1\n---\n\nok\n' > mailbox/inbox/u1/29990101T000009Z-u2-r14a.md"
pl sh -c "printf -- '---\nprotocol: 1\nfrom: u2\nto: u1\ntopic: r14b\ncontext: general\nsent: 2999-01-01T00:00:09Z\nin_reply_to: none\nneeds: none\nrelease: item#14 v2\n---\n\nok\n' > mailbox/inbox/u1/29990101T000009Z-u2-r14b.md"
expect "releases of different versions at the same time conflict" 5 "item#14 has releases from u2 sent at the same time.*send one release again" as u1 holds "item#14" --version v2
expect "for either version" 5 "item#14 has releases from u2 sent at the same time" as u1 holds "item#14" --version v1
# 9. merges don't multiply what holds reads: one hold file under several merges is one row of history
echo h | as u2 send u1 h-15 - --hold "item#15 v1" >/dev/null
for n in 1 2 3; do (cd "$T/plant" && git pull -q --rebase origin main 2>/dev/null && base=$(git rev-parse HEAD~1) &&
  git checkout -q -b "s$n" "$base" && echo "$n" > "note-s$n.txt" && git add "note-s$n.txt" && git commit -qm "s$n" && git checkout -q main &&
  git merge -q --no-ff -m "m$n" "s$n" >/dev/null 2>&1 && git push -q origin HEAD:main); done
as u1 holds "item#15" >/dev/null 2>&1
co=$(ls -d "$W"/home-u1/.local/state/agent-mailbox/checkouts/*/ | head -n 1)
rows=$( (AD_DIR=${co%/} BRANCH=main ME=u1; die() { :; }; warn() { :; }; . "$ROOTDIR/adapters/git.sh"; ad_history mailbox/inbox/u1 '^(hold|release):') | grep -c -- '-u2-h-15\.md$')
[ "$rows" = 1 ] && ok "a hold under several merges is read once" || no "a hold under merges was listed $rows times"
sleep 1; echo r | as u2 send u1 r-9 - --release "item#9 v1" >/dev/null
expect "a real release still counts (holds reads only mail that may carry one)" 0 "released by u2 at v1" as u1 holds "item#9" --version v1
# 10. in a store that requires signatures, a copy of a signed hold committed without its signature (an old-dated side
# branch merged in, so history lists the copy first) doesn't stand in for the signed one
if [ -n "$SSH" ]; then
  T="$W/rules-strict"; mkdir -p "$T"; git init -q --bare "$T/store.git"
  for a in sg1 sg2; do as $a setup --store "$T/store.git" --name $a >/dev/null; done
  as sg1 init --require-signatures >/dev/null; for a in sg1 sg2; do as $a register --kind t --about t >/dev/null; done
  echo r | as sg2 send sg1 r-1 - --release "item#1 v1" >/dev/null; sleep 1; echo h | as sg2 send sg1 h-1 - --hold "item#1 v1" >/dev/null
  git clone -q -b main "$T/store.git" "$T/plant" && (cd "$T/plant" && git config user.email e@e && git config user.name e &&
    f=$(ls mailbox/inbox/sg1/*-sg2-h-1.md) && cp "$f" ../h.md && git checkout -q -b side "$(git log --format=%H --diff-filter=A -- "$f")^" &&
    cp ../h.md "$f" && git add "$f" && GIT_COMMITTER_DATE=2001-01-01T00:00:00Z GIT_AUTHOR_DATE=2001-01-01T00:00:00Z git commit -qm side &&
    git checkout -q main && git merge -q --no-edit side && git push -q origin HEAD:main)
  expect "an unsigned copy of a signed hold doesn't hide it" 5 "item#1 is held by sg2" as sg1 holds "item#1" --version v1
fi

echo "== capability probe"
mkdir -p "$W/oldssh"; printf '#!/bin/sh\necho "unknown option -- Y" >&2\necho "usage: ssh-keygen [-q] [-b bits] [-t dsa | ecdsa | ed25519 | rsa]" >&2\nexit 1\n' > "$W/oldssh/ssh-keygen"; chmod +x "$W/oldssh/ssh-keygen"
expect "an OpenSSH without -Y isn't taken for a signer" 1 "FAIL ssh-keygen -Y" env PATH="$W/oldssh:$PATH" HOME="$W/home-probe" "$SH" "$CLI" doctor
echo "passed $pass, failed $fail, skipped $skip"
[ "$fail" -eq 0 ]
