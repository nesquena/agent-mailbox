# git.sh: the git adapter. The store is any git repository you can push to (a dedicated private repo is best);
# the mailbox lives under $ROOT/ on $BRANCH. The CLI keeps its own clone of it under $STATE/checkouts/, so it never
# touches a working tree you use for anything else. Contract: adapters/README.md.
#
# Reliability rules this adapter keeps (each one was a real failure):
# - Never `git pull`: it reads FETCH_HEAD, which a watcher fetching in the same clone can rewrite mid-pull. Fetch
#   into origin/<branch> explicitly, then rebase onto that ref.
# - A rejected push (someone pushed first) fetches, rebases and retries, with a random pause.
# - A commit left unpublished by an earlier failure is published by the next command; nothing is resent.
# - A rebase that stops part-way is aborted, so the clone is never left mid-rebase. One that publishes what an earlier
#   command left, stopped by a conflict with the store, goes on instead (ad_unstick): that commit can't wedge the clone.
# - The watcher's peek fetch and holds' history fetch write only their own refs (`--refmap=`): git updates a ref only
#   from the value it read, so a peek that also moved origin/<branch> made a send's fetch or push in this clone fail;
#   and origin/<branch> is the clone's record of where it last synced, which tells it what it has published.
# - Commits carry the agent's mailbox name as author, never a person's name or email. It's set in each command's
#   environment, never in the clone's config, which commands sharing the clone would race to rewrite.
# - Symlinks in the store are checked out as plain files (core.symlinks=false), and `ad_peek` lists only regular
#   files, so a link a writer plants can't redirect writes or wake a watcher.
# - The store's own .gitattributes and .lfsconfig are inert here: .git/info/attributes, which outranks them, turns off
#   line-ending conversion, filters (Git LFS too) and diff drivers, and has merges use git's own text merge; git runs
#   with submodule recursion off, without hooks or a file-system monitor, and never on a repository the environment
#   names (GIT_DIR, as in a git hook), so every file is checked out exactly as stored and nothing the store names is
#   contacted.

AD_SPEC="+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
# git's own terminal prompt is off (GIT_TERMINAL_PROMPT=0), and so is Git Credential Manager's (GCM_INTERACTIVE=never),
# so a credential that needs one fails at once with git's own message. An askpass program stays on (GIT_ASKPASS,
# core.askPass, SSH_ASKPASS): many just print a token. credential.interactive=false isn't set: from git 2.47 it turns
# askpass off too.
# ceiling: other prompts still wait until someone answers: an askpass program that opens a dialog; a credential helper
# that prompts on its own (after a git upgrade, macOS's git-credential-osxkeychain can make Keychain ask once to let the
# new helper in); and, for an SSH store, ssh's own prompts (a key's passphrase, an unknown host key)
ad_g() { GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_EDITOR=: git -c submodule.recurse=false -c core.hooksPath=/dev/null \
  -c core.fsmonitor= "$@"; }
ad_git() { ad_g -C "$AD_DIR" "$@"; }
ad_jitter() { sleep "$(od -An -N1 -tu1 /dev/urandom | awk 'NF {printf "%.2f", 0.2 + $1 / 255 * 1.8; exit}')"; }
# ad_gist: git's error output as one line for a die or warn. In the C locale, so a byte that isn't UTF-8 can't make grep
# take it for binary and drop it, and through clean: git masks ASCII controls in its errors, but not C1 ones
ad_gist() { ( LC_ALL=C && export LC_ALL && sed -E 's#//[^@/]*@#//***@#g' | grep -v '^hint:' | tail -n 3 | tr '\n' ' ' | clean ); }
ad_remote_has_branch() { ad_git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null; }
# ad_clone: clone the store into $AD_DIR, in the C locale so its messages read the same everywhere. git clone takes a
# name that exists as a repository or bundle where it runs as that local path first, even a URL's (ssh://h/x is also
# the path ssh:/h/x), so a store named by a URL, host:path or an absolute path is cloned from the agent's own folder,
# where nothing else can put one. A relative path is the caller's own folder, read from where the command runs; a name
# with a colon and no slash before it is taken as host:path, even if a folder of that name is there (write ./a:b for a
# folder). The remote is always origin. Relative paths in your own git setup (GIT_SSH, core.sshCommand, an insteadOf
# target) are read from the state folder for that clone.
# ceiling: an insteadOf alias spelled like a path (a slash before its colon) is read as that path where the command
# runs, as git reads it; name such a store by its URL
ad_cd_state() { CDPATH= cd -P -- "$STATE/checkouts" || exit; }
ad_clone() { ( to=$AD_DIR; case $to in (/*) ;; (*) to=$PWD/$to ;; esac
  case $STORE in (/*) ad_cd_state ;; (*:*) case ${STORE%%:*} in (*/*) ;; (*) ad_cd_state ;; esac ;; esac
  LC_ALL=C && export LC_ALL && ad_g clone -q --no-checkout --single-branch --origin origin "$@" -- "$STORE" "$to" ) 2>&1; }

# ad_attrs [<first line>]: make the store's own attributes inert in this clone; succeeds only when it had to write the
# file. A first line (a comment) marks work still to do: the file counts as done only once it starts with the rules.
# merge and diff come first, so a store macro of either name ([attr]merge ...) can't undo the neutral settings after them
AD_ATTRS='* merge !diff -text -eol -filter -ident -working-tree-encoding'
ad_attrs_put() { mkdir -p "$AD_DIR/.git/info" &&
  printf '%s\n' ${1:+"$1"} "$AD_ATTRS" > "$af.$$" && mv -f "$af.$$" "$af"; }
ad_attrs() {
  af="$AD_DIR/.git/info/attributes" al=
  [ ! -f "$af" ] || IFS= read -r al < "$af"
  [ "$al" = "$AD_ATTRS" ] && return 1
  ad_attrs_put "${1:-}" || die "can't write $af"
}

ad_open() {
  command -v git >/dev/null 2>&1 || die "the git adapter needs git"
  # git acts on this clone only, never on a repository the environment names (GIT_DIR and the like, as in a git hook);
  # config passed through the environment (GIT_CONFIG_COUNT and the like: insteadOf, credentials, proxies) still applies,
  # but not GIT_CONFIG, which would send this clone's own config writes to another file
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars | grep -v '^GIT_CONFIG_')
  # one clone per agent name, so names sharing a state folder (one HOME, a config each) never work in the same clone
  AD_ID=$STORE_ID; [ -z "${ME:-}" ] || ! matches "$NAME_RE" "$ME" || AD_ID="$STORE_ID-$ME"
  AD_DIR="$STATE/checkouts/$AD_ID"
  mkdir -p "$STATE/checkouts" || die "can't create $STATE/checkouts"
  ad_lock
  if [ ! -d "$AD_DIR/.git" ]; then
    # set the clone up under a temporary name and move it into place once it's complete, so a command cut off
    # part-way never leaves a clone that later commands take as ready. ceiling: that cut-off one's .<id>.<pid> folder
    # stays behind (removing another command's could break a setup still running); delete it by hand
    d=$AD_DIR AD_DIR="$STATE/checkouts/.$AD_ID.$$"
    # clone only the mailbox branch; a store that doesn't have it yet is cloned without it. clone itself says which it
    # is (git's message), so nothing reads the store's name any other way than clone does; any other
    # failure is an error
    rm -rf "$AD_DIR"
    err=$(ad_clone --branch "$BRANCH") || { rm -rf "$AD_DIR"
      case $err in (*"Remote branch $BRANCH not found in upstream"*) err=$(ad_clone) ;; (*) false ;; esac; } ||
      { rm -rf "$AD_DIR"; die "can't clone the store: $(printf '%s\n' "$err" | ad_gist)"; }
    ad_git config core.symlinks false
    ad_attrs || :
    # check out the mailbox branch itself, whatever the store's default branch is; a store without it gets an empty
    # one, holding none of the default branch's files
    ad_git fetch -q origin "$AD_SPEC" 2>/dev/null
    # (git's output is kept for the one die line, never passed through: it prints a path it can't create as it is)
    cerr=""
    if ad_remote_has_branch; then cerr=$(ad_git checkout -q -B "$BRANCH" "origin/$BRANCH" 2>&1)
    else cerr=$( { ad_git symbolic-ref HEAD "refs/heads/$BRANCH" && ad_git read-tree --empty; } 2>&1 )
    fi || { rm -rf "$AD_DIR"; die "can't check out the store${cerr:+: $(printf '%s\n' "$cerr" | ad_gist)}"; }
    # another command may set up the same clone meanwhile: whichever moves first is kept, and is never removed. A loser
    # that moved after it lands inside it, so that copy goes too
    [ -e "$d" ] || mv "$AD_DIR" "$d" 2>/dev/null || [ -d "$d/.git" ] || { rm -rf "$AD_DIR"; die "can't move a new clone to $d"; }
    rm -rf "$AD_DIR" "$d/${AD_DIR##*/}"; AD_DIR=$d
    [ -d "$AD_DIR/.git" ] || die "$AD_DIR isn't a clone: remove it, then run this again"
  # an older clone may hold files checked out under the store's attributes: check them out again, as stored (read-tree
  # first drops the index's stat data, which would otherwise let git skip files it thinks unchanged). The attributes are
  # in force from the start, marked for retry until that succeeds, so a failed or interrupted run is redone next time
  elif ad_attrs '# retry'; then
    if ! ad_git rev-parse -q --verify HEAD >/dev/null ||
      { ad_git read-tree HEAD && ad_git checkout-index -q -a -f -u; } 2>/dev/null; then ad_attrs_put || :; fi
  fi
  # an older clone may hold links checked out before this rule: replace them with plain files
  if [ "$(ad_git config core.symlinks)" != false ]; then
    ad_git config core.symlinks false
    ad_git ls-files -s | awk '$1 == "120000" { sub(/^[^\t]*\t/, ""); print }' | while IFS= read -r l; do
      rm -f "$AD_DIR/$l" && ad_git checkout -q -- "$l"; done
  fi
  GIT_AUTHOR_NAME="${ME:-agent-mailbox}" GIT_AUTHOR_EMAIL="${ME:-agent-mailbox}@agent-mailbox.invalid"
  GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
  export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

# fetch, then rebase local commits onto origin/<branch>; prints git's error on failure
ad_pull() {
  # whether this clone had seen the store's branch before this fetch, and where it was then
  seen="" pre=""; ! ad_remote_has_branch || { seen=1; pre=$(ad_git rev-parse -q --verify "refs/remotes/origin/$BRANCH"); }
  ferr=$(ad_git fetch -q origin "$AD_SPEC" 2>&1) || {
    # an empty store has no branch yet: that's not an error (exit 2), but a store that can't be reached is, and so is
    # a branch gone from the store since this clone fetched it
    ad_ls_branch >/dev/null 2>&1
    case $? in (2) ad_remote_has_branch || return 0
      printf 'the store no longer has the branch %s; if it was re-created, delete %s and run this again\n' "$BRANCH" "$AD_DIR"
      return 1 ;; esac
    printf '%s\n' "$ferr"; return 1; }
  ad_remote_has_branch || return 0
  post=$(ad_git rev-parse -q --verify "refs/remotes/origin/$BRANCH")
  # the mailbox folder as git prints paths, without ./ parts, and whether the store's branch has a mailbox there
  rr=$(printf '%s\n' "$ROOT" | sed -e ':a' -e 's#/\./#/#' -e 'ta' -e ':b' -e 's#^\./##' -e 'tb' -e 's#/\.$##' -e 's#^\.$##')
  taken=""; ! ad_git cat-file -e "origin/$BRANCH:${rr:+$rr/}store.md" 2>/dev/null || taken=1
  # an init an earlier command made but never published (its push failed), when the branch now has a mailbox in its
  # folder: another agent's init won while this one waited. It's dropped, and the clone goes on with that mailbox. Only
  # a lone commit `init` writes (store.md and the two .keep files) that the store never had is dropped; a clone holding
  # anything more, or one whose init the store once had (a mailbox since reset), fails below as before
  if [ -n "$taken" ] && [ -z "${AD_INIT:-}" ] && ad_git rev-parse -q --verify HEAD >/dev/null &&
    [ "$(ad_git rev-list --count HEAD --not "origin/$BRANCH")" = 1 ] &&
    [ "$(ad_git log -1 --format=%s HEAD)" = "mailbox: init" ] &&
    { [ -z "$pre" ] || ! ad_git merge-base --is-ancestor HEAD "$pre"; } &&
    [ -z "$(ad_git diff-tree --no-commit-id --name-only -r --root HEAD |
      grep -vxF -e "${rr:+$rr/}store.md" -e "${rr:+$rr/}agents/.keep" -e "${rr:+$rr/}inbox/.keep")" ]; then
    # (git prints a path it can't create as it is, line breaks included, and a store writer chooses paths: its output
    # is returned for the one die line, never passed through)
    rerr=$(ad_git reset -q --hard "origin/$BRANCH" 2>&1) || { printf '%s\n' "$rerr"; return 1; }
    warn "dropped an init this clone made earlier but never published: another agent has since started the mailbox at '$ROOT/' (require_signatures: $(field require_signatures "$AD_DIR/$ROOT/store.md" | clean "$CAP"); its settings are in $ROOT/store.md)"
    return 0
  fi
  # the commit `init` made in this same command (AD_INIT), when the branch now has a mailbox in its folder, is a race
  # lost just now: init saw no mailbox there, and its own sync published anything left before, so that commit is all
  # this clone holds unpublished. It's dropped, and init reports the winner
  if [ -n "${AD_INIT:-}" ] && [ -n "$taken" ] && ad_git rev-parse -q --verify HEAD >/dev/null &&
    [ "$(ad_git rev-list --count "origin/$BRANCH..HEAD")" = 1 ]; then
    rerr=$(ad_git reset -q --hard "origin/$BRANCH" 2>&1) || { printf '%s\n' "$rerr"; return 1; }; return 0
  fi
  # a clone whose history shares nothing with the store's branch fails, saying how to recover, and is never rebased onto
  # it, so nothing it holds is published into that mailbox, when it had seen the store's branch before (one since
  # reset, deleted or re-created) or the branch now has a mailbox in its own folder (another agent's init took it). A
  # clone that never saw the branch, whose mailbox folder the branch doesn't have (a mailbox in another folder of the
  # same branch), is rebased and published as before. It returns 3, so a push retrying doesn't add "don't resend"
  if ad_git rev-parse -q --verify HEAD >/dev/null && ! ad_git merge-base HEAD "origin/$BRANCH" >/dev/null 2>&1; then
    if [ -n "$seen" ] || [ -n "$taken" ]; then
      # (what goes with the clone: its commits the store never had, past where it last saw the store's branch)
      if [ -n "$pre" ]; then un=$(ad_git rev-list --count "$pre..HEAD"); else un=$(ad_git rev-list --count HEAD); fi
      lost=""; [ "${un:-0}" = 0 ] || lost=" (its $un unpublished commit(s) go with it: send again what they held)"
      printf "this clone's history doesn't match the store's (another agent's init took this mailbox's folder, or the mailbox was re-created): remove %s%s and run this again\n" "$AD_DIR" "$lost"
      # (the fetch moved the tracking ref to the store's new tip: it goes back to where it was, so a command run again
      # counts from the same point, not from a tip this clone shares nothing with; only while it still holds what this
      # fetch set, so a later fetch's value is never overwritten with an older one)
      if [ -n "$pre" ]; then ad_git update-ref "refs/remotes/origin/$BRANCH" "$pre" "$post" 2>/dev/null
      else ad_git update-ref -d "refs/remotes/origin/$BRANCH" "$post" 2>/dev/null; fi
      return 3
    fi
  fi
  if ad_git rev-parse -q --verify HEAD >/dev/null; then
    rb=$(ad_git rebase -q --autostash "origin/$BRANCH" 2>&1 >/dev/null) ||
      { [ -n "${AD_UNSTICK:-}" ] && ad_unstick; } || { ad_git rebase --abort >/dev/null 2>&1; printf '%s\n' "$rb"; return 1; }
  else
    rerr=$(ad_git reset -q --hard "origin/$BRANCH" 2>&1) || { printf '%s\n' "$rerr"; return 1; }
  fi
}

# ad_unstick: finish a rebase of commits an earlier command left that stopped on a conflict with the store, so they
# can't wedge the clone. A message such a commit added, whose name the store now has for another message (two senders
# whose name and topic join to one file name, in one second), is moved to a new stamp, with its .sig: a signature
# covers the bytes, not the name. Any other conflicting commit is set aside under refs/agent-mailbox/stuck/<n> in the
# clone (one ref per commit, kept if a run cut short made it already), and skipped. What it did is said once the rebase
# is done, and only then. Status 1 (a rebase that failed without stopping, or that didn't end on the store) leaves it
# to be aborted, as before
ad_unstick() { k=0 said="" rr=$(printf '%s\n' "$ROOT" | sed -e ':a' -e 's#/\./#/#' -e 'ta' -e ':b' -e 's#^\./##' -e 'tb' -e 's#/\.$##' -e 's#^\.$##')
  [ -d "$AD_DIR/.git/rebase-merge" ] || [ -d "$AD_DIR/.git/rebase-apply" ] || return 1
  while [ -d "$AD_DIR/.git/rebase-merge" ] || [ -d "$AD_DIR/.git/rebase-apply" ]; do
    k=$((k+1)); [ $k -le 50 ] || return 1
    c=$(ad_git rev-parse -q --verify REBASE_HEAD) || return 1
    u=$(ad_git -c core.quotePath=false diff --name-only --diff-filter=U); [ -n "$u" ] || return 1
    if ad_restamp; then ad_git rebase --continue >/dev/null 2>&1 || :
    else ref=$(ad_git for-each-ref --format='%(objectname) %(refname)' refs/agent-mailbox/stuck/ | awk -v c="$c" '$1 == c { print $2; exit }')
      if [ -z "$ref" ]; then n=1; while ad_git rev-parse -q --verify "refs/agent-mailbox/stuck/$n" >/dev/null; do n=$((n+1)); done
        ref="refs/agent-mailbox/stuck/$n"; ad_git update-ref "$ref" "$c" || return 1; fi
      said="$said${NL}set aside a commit an earlier command left unpublished ($(ad_git log -1 --format=%s "$c" | clean "$CAP")), which conflicts with the store: what it held isn't published, so send again what it held (it's kept as $ref in $AD_DIR); this clone goes on from the store"
      ad_git rebase --skip >/dev/null 2>&1 || :
    fi
  done
  ad_git merge-base --is-ancestor "origin/$BRANCH" HEAD || return 1
  printf '%s\n' "$said" | while IFS= read -r w; do [ -z "$w" ] || warn "$w"; done; }
# ad_restamp: (for ad_unstick) resolve the stopped commit's conflicts when each is a message that commit added, under a
# name the store took meanwhile, by moving it (and its .sig) to the next free stamp; status 1 when any isn't
ad_restamp() { ms=""
  # (a line at a time, so a path the store chose is never expanded as a pattern)
  while IFS= read -r f; do m=${f%.sig}
    printf '%s\n' "$m" | grep -Eq "^${rr:+$rr/}inbox/[a-z0-9][a-z0-9.-]{0,62}/[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9._-]+\\.md\$" || return 1
    [ "$(ad_git diff-tree --root -r --no-commit-id --name-status "$c" -- "$m" | cut -f1)" = A ] || return 1
    # (and the store has a message of that name: a conflict git reports at a path the store lacks, as a reply quoting a
    # message it consumes, against an edit to that message, is no name taken)
    ad_git cat-file -e "HEAD:$m" 2>/dev/null || return 1
    case " $ms " in (*" $m "*) ;; (*) ms="$ms $m" ;; esac
  done <<EOF
$u
EOF
  for m in $ms; do d=${m%/*} b=${m##*/}; rest=${b#*Z-} i=0
    st=$(date -u +%Y%m%dT%H%M%SZ)
    while ad_git cat-file -e "HEAD:$d/$st-$rest" 2>/dev/null || [ -e "$AD_DIR/$d/$st-$rest" ]; do
      i=$((i+1)); [ $i -le 10 ] || return 1; sleep 1; st=$(date -u +%Y%m%dT%H%M%SZ); done
    nm="$d/$st-$rest"
    ad_git show "$c:$m" > "$AD_DIR/$nm" || return 1; set -- "$nm"
    if ad_git cat-file -e "$c:$m.sig" 2>/dev/null; then ad_git show "$c:$m.sig" > "$AD_DIR/$nm.sig" || return 1; set -- "$nm" "$nm.sig"; fi
    # the store's own message keeps its name, as the store has it
    for f in "$m" "$m.sig"; do
      if ad_git cat-file -e "HEAD:$f" 2>/dev/null; then ad_git checkout -q HEAD -- "$f" || return 1
      else ad_git rm -q -f --cached --ignore-unmatch -- "$f" >/dev/null || return 1; rm -f "$AD_DIR/$f"; fi
    done
    ad_git add -f -- "$@" || return 1
    said="$said${NL}moved ${m##*/} to ${nm##*/} (published with this clone's next push): the store already had another message by that name"
  done
  [ -z "$(ad_git diff --name-only --diff-filter=U)" ]; }

# ad_unpublished <why>: say what's saved locally but not published. A command publishing what an earlier one left
# (AD_LEFTOVER, from ad_sync) has written nothing of its own yet, so it says so: that one is to be run again
ad_unpublished() {
  if [ -n "${AD_LEFTOVER:-}" ]; then
    warn "this command wrote nothing: an earlier command's change is saved locally but not published ($1); re-run a command with the same name to publish it, then run this one again"
  else warn "written locally, not published ($1); re-run a command with the same name to publish it, don't resend"; fi
}

ad_push() {
  n=0
  until perr=$(ad_git push -q origin "HEAD:refs/heads/$BRANCH" 2>&1); do
    n=$((n+1))
    [ $n -lt 10 ] || { ad_unpublished "push failed 10 times: $(printf '%s\n' "$perr" | ad_gist)"; exit 4; }
    ad_jitter
    rerr=$(ad_pull); pr=$?
    # (a clone whose history the store doesn't share: its own message says what to do, and what goes with the clone)
    [ "$pr" != 3 ] || die "$(printf '%s\n' "$rerr" | ad_gist)"
    [ "$pr" = 0 ] || { ad_unpublished "$(printf '%s\n' "$rerr" | ad_gist)"; exit 4; }
  done
  # what was pushed is now the store's branch, as far as this clone knows: recorded here, since a clone made from a
  # store with no branch yet fetches it only on its next command. Then a branch deleted from the store before that is
  # seen as deleted, not as one this clone has yet to publish
  ad_git update-ref "refs/remotes/origin/$BRANCH" HEAD 2>/dev/null || :
}

# ad_lock: take this clone's lock, held until the command exits (or ad_unlock), so commands under one name take turns
# in its clone instead of working in it at once. The lock is a file in the state folder's locks/<clone id>/ (where no
# clone name can reach it), created with noclobber, naming its holder: "<pid> <epoch it took the lock> <host> <the
# holder's start, from ad_started>". A holder on this host that's gone, or a pid now another process's (its start
# differs), is broken at once; a lock that can't be read is broken once it's a minute old; a holder on another host (a
# state folder shared between machines, or this one's name since changed) can't be checked, so it's waited for, and the
# message says which file to delete if nothing is running there. Breaking a lock takes a guard file first, so two
# waiters never both break it. A command waits up to AGENT_MAILBOX_LOCK_WAIT seconds (120), then stops, naming the
# holder.
# ceiling: a breaker killed while holding the guard leaves it; it's taken as abandoned, and removed, once a minute old
# ad_started <pid>: when that process started, in a form that reads the same every time. Where /proc has it (Linux), its
# start in clock ticks since boot (field 22 of /proc/<pid>/stat, counted after the name's closing parenthesis, since a
# name can hold spaces) and the boot's id: a clock step moves ps's start time for every process, but not these, and a
# lock from an earlier boot reads as another process's. Elsewhere, ps's start time, in UTC and the C locale
ad_started() {
  if [ -r "/proc/$1/stat" ]; then
    st=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; st=${st##*')'}
    set -f; set -- $st; set +f; [ $# -ge 20 ] || return 0
    # (without a boot id, the ticks alone, with no trailing space: a waiter reads the lock's fields split on spaces)
    eval "st=\${20}"; bi=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); printf '%s\n' "$st${bi:+ $bi}"; return 0
  fi
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'
}
# ad_same_start <one> <other>: two ad_started values name the same start. When both are /proc's ticks and one has no
# boot id (its side couldn't read it, in a sandbox that hides /proc/sys, say), the ticks alone decide
ad_same_start() {
  [ "$1" = "$2" ] && return 0
  case "${1%% *}" in (''|*[!0-9]*) return 1 ;; esac; case "${2%% *}" in (''|*[!0-9]*) return 1 ;; esac
  { [ "${1#* }" = "$1" ] || [ "${2#* }" = "$2" ]; } && [ "${1%% *}" = "${2%% *}" ]
}
AD_LOCK="" AD_LOCKED=""
ad_lock() {
  ld="$STATE/locks/$AD_ID"; mkdir -p "$ld" 2>/dev/null || die "can't create $ld"
  lk="$ld/lock" host=$(uname -n 2>/dev/null | tr -cd 'A-Za-z0-9._-'); host=${host:-unknown}
  mine="$$ $(date +%s) $host $(ad_started $$)"
  lw=${AGENT_MAILBOX_LOCK_WAIT:-120}; case "$lw" in (''|*[!0-9]*) lw=120 ;; esac; [ "${#lw}" -le 5 ] || lw=120
  t0=$(date +%s)
  while :; do
    stale=""
    (set -C; printf '%s\n' "$mine" > "$lk") 2>/dev/null && break
    # (no lock there, so it couldn't be created: try once more, in case one was released just then)
    if [ ! -e "$lk" ] && [ ! -L "$lk" ]; then
      (set -C; printf '%s\n' "$mine" > "$lk") 2>/dev/null && break
      [ -e "$lk" ] || [ -L "$lk" ] || die "can't create the lock $lk"
    fi
    held=$(cat "$lk" 2>/dev/null); hp="" he="" hh="" hs=""
    set -f; set -- $held; set +f; hp=${1:-} he=${2:-} hh=${3:-}; [ $# -lt 3 ] || { shift 3; hs="$*"; }
    case "$hp$he" in
      (''|*[!0-9]*) [ -z "$(find "$lk" -prune -mmin +1 2>/dev/null)" ] || stale=1 ;;
      (*) [ "$hh" != "$host" ] || { kill -0 "$hp" 2>/dev/null && ad_same_start "$(ad_started "$hp")" "$hs"; } || stale=1 ;;
    esac
    if [ -n "$stale" ]; then
      # (a guard just released by another waiter is tried once more)
      if (set -C; : > "$ld/break") 2>/dev/null || { [ ! -e "$ld/break" ] && (set -C; : > "$ld/break") 2>/dev/null; }; then
        # (removed only while it still holds what was found stale)
        if [ "$(cat "$lk" 2>/dev/null)" = "$held" ]; then
          rm -f "$lk" 2>/dev/null || { rm -f "$ld/break"; die "can't remove the stale lock $lk"; }
        fi
        rm -f "$ld/break"; continue
      fi
      # (still no guard there, and the folder can't be written: the stale lock can't be removed either. One that can
      # be is only another waiter's guard, come and gone: wait, and try again)
      [ -e "$ld/break" ] || [ -w "$ld" ] || die "can't remove the stale lock $lk"
      [ -z "$(find "$ld/break" -prune -mmin +1 2>/dev/null)" ] || rm -f "$ld/break"
    fi
    [ $(( $(date +%s) - t0 )) -lt "$lw" ] || {
      case "$he" in (''|*[!0-9]*) age="" ;; (*) age=" for $(( $(date +%s) - he ))s" ;; esac
      if [ -n "$hh" ] && [ "$hh" != "$host" ]; then
        die "another agent-mailbox command (pid ${hp:-unknown} on $hh) has been working in this name's copy of the store$age: if none is running on $hh (or this machine's name has changed), delete $lk, then run this again"
      fi
      die "another agent-mailbox command (pid ${hp:-unknown}) has been working in this name's copy of the store$age: let it finish, or stop it, then run this again (its lock: $lk)"; }
    sleep 1
  done
  AD_LOCK=$lk AD_LOCKED=$mine
  trap ad_unlock EXIT; trap 'exit 130' INT TERM HUP
}
# ad_unlock: release the lock, if this command still holds it
ad_unlock() { [ -n "$AD_LOCK" ] || return 0; [ "$(cat "$AD_LOCK" 2>/dev/null)" != "$AD_LOCKED" ] || rm -f "$AD_LOCK"; AD_LOCK=""; }

ad_sync() {
  # under the lock, nothing else works in this clone, so what a command cut off part-way left is debris: a rebase it
  # was in, git's own lock on the index, and changes it never committed (a message written but not added, a consumed
  # one removed but not committed). Commits it made but couldn't push are kept, and published below
  if [ -d "$AD_DIR/.git/rebase-merge" ] || [ -d "$AD_DIR/.git/rebase-apply" ]; then
    ad_git rebase --abort >/dev/null 2>&1 || rm -rf "$AD_DIR/.git/rebase-merge" "$AD_DIR/.git/rebase-apply"; fi
  rm -f "$AD_DIR/.git/index.lock"
  if ad_git rev-parse -q --verify HEAD >/dev/null; then ad_git reset -q --hard HEAD 2>/dev/null; fi
  # (-x: files the store's own .gitignore names are debris too)
  ad_git clean -fdqx -- "$ROOT" 2>/dev/null
  err=$(AD_UNSTICK=1; ad_pull) || die "can't update from the store: $(printf '%s\n' "$err" | ad_gist)"
  # publish anything an earlier command committed but couldn't push; on a store with no mailbox branch yet, that's every
  # commit this clone has (an init whose push failed)
  if ad_remote_has_branch; then
    [ -z "$(ad_git log --format=%h "origin/$BRANCH..HEAD" 2>/dev/null)" ] && return
    warn "publishing $(ad_git rev-list --count "origin/$BRANCH..HEAD") commit(s) left from an earlier command"
  else
    ad_git rev-parse -q --verify HEAD >/dev/null || return 0
    warn "publishing $(ad_git rev-list --count HEAD) commit(s) left from an earlier command, to a store with no $BRANCH yet"
  fi
  AD_LEFTOVER=1; ad_push; AD_LEFTOVER= AD_PUBLISHED=1
}

# ad_commit <message> <path>...: publish exactly these paths (added, changed or removed), nothing else
ad_commit() {
  msg=$1; shift; keep=""; AD_UNCHANGED=""
  for p in "$@"; do
    if [ -e "$AD_DIR/$p" ] || ad_git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then keep="$keep $p"; fi
  done
  [ -n "$keep" ] || return 0
  # shellcheck disable=SC2086
  ad_git add -A -f -- $keep || die "git add failed"
  # nothing staged (the files came out as they were: an ed25519 signature of the same bytes is the same bytes) is
  # nothing to publish, not a failure; AD_UNCHANGED tells the caller
  # shellcheck disable=SC2086
  if ad_git diff --cached --quiet -- $keep; then AD_UNCHANGED=1; return 0; fi
  # shellcheck disable=SC2086
  ad_git commit -q -m "$msg" -- $keep >/dev/null || die "git commit failed"
  ad_push
}

# ad_ls_branch: the store's mailbox branch tip, or exit 2 when the store has no such branch (any other failure is git's
# own exit). ls-remote matches a pattern against the end of ref names, so refs/heads/x/refs/heads/main matches main too:
# only the exact name counts
ad_ls_branch() {
  lb=$(ad_git ls-remote origin "refs/heads/$BRANCH") || return
  printf '%s\n' "$lb" | awk -F'\t' -v r="refs/heads/$BRANCH" '$2 == r { print $1; f = 1 } END { exit f ? 0 : 2 }'
}

# a cheap token that changes whenever the store changes: the branch tip, from one small network round trip; empty
# while the store has no mailbox branch
ad_poll() { ad_ls_branch; pr=$?; [ "$pr" -ne 2 ] || pr=0; return "$pr"; }

# ad_peek <dir>: files under <dir> in the store's latest state, without touching the working tree
ad_peek() {
  ad_git fetch -q --refmap= origin "+refs/heads/$BRANCH:refs/agent-mailbox/peek" 2>/dev/null || return 1
  pl=$(ad_git ls-tree refs/agent-mailbox/peek "$1/" 2>/dev/null) || return 1
  [ -z "$pl" ] || printf '%s\n' "$pl" | awk -F'\t' '$1 ~ /^100(644|755) blob / { print $2 }'
}

# ad_history <dir> [<ERE>]: "<ref> <path>" for every version of every file that was ever under <dir>, oldest first
# (consumed files included), however it got there. holds builds a security gate on this, so no git history filter
# may hide a version: --full-history and -m visit every commit and both sides of every merge (history
# simplification could skip a commit), with log.diffMerges pinned so a user's setting can't turn -m off;
# --no-renames counts a renamed file as added; A, M and T count added, rewritten and retyped files. A pattern (git
# log -G, an extended regex, searching every file as plain text) narrows only the added versions, whose whole content
# is in the diff; a rewritten version is always listed, since its diff shows only the lines that changed. Rows are
# unique per path, content and signature (the <path>.sig at that commit), so merges can't multiply the work and no
# copy of a file under another signature can stand in for it; the CLI checks every listed file. A history it can't
# read in full (a failed fetch, which also means the store can't be reached, or a failed git log), is reported as the
# single row "! !", never as fewer rows: holds stops
# on it rather than decide from part of the history. A gitlink isn't a file, so it's never listed.
ad_history() {
  # a fetch of its own proves the store is reachable, and the walk reads what it fetched (never a stale HEAD). It
  # fetches into a ref of its own, as ad_peek does, so the clone's tracking ref still says where the clone last synced:
  # ad_pull reads it to tell what this clone published, and a store re-created in between mustn't move it
  u=; [ "$(ad_git rev-parse --is-shallow-repository)" = true ] && u=--unshallow
  ad_git fetch -q $u --refmap= origin "+refs/heads/$BRANCH:refs/agent-mailbox/history" 2>/dev/null || { echo '! !'; return 0; }
  tip=$(ad_git rev-parse -q --verify refs/agent-mailbox/history) || { echo '! !'; return 0; }
  AD_ROWS=$({ if [ -n "${2:-}" ]; then ad_git -c log.diffMerges=separate log --full-history -m --no-renames --diff-filter=A --raw --no-abbrev \
      --format='C %H' --text --no-textconv "-G$2" "$tip" -- "$1/" 2>/dev/null || echo '!'; fi | sed 's/^/G /'
    ad_git -c log.diffMerges=separate log --reverse --full-history -m --no-renames --diff-filter=AMT --raw --no-abbrev \
      --format='C %H' "$tip" -- "$1/" 2>/dev/null || echo '!'; } |
    awk -v g="${2:+1}" '
      $1 == "!" || ($1 == "G" && $2 == "!") { print "!"; next }
      $1 == "G" { if ($2 == "C") c = $3; else if ($2 ~ /^:/) { i = index($0, "\t"); m[c " " substr($0, i + 1)] = 1 }; next }
      $1 == "C" && NF == 2 { c = $2; next }
      /^:/ { i = index($0, "\t"); p = substr($0, i + 1); split(substr($0, 1, i - 1), f, " ")
             if (f[2] == "160000" || (g && f[5] == "A" && !((c " " p) in m))) next; if (!seen[c " " p]++) print c "\t" p "\t" f[4] }')
  [ -n "$AD_ROWS" ] || return 0
  # every row starts with a commit id, so a row starting with "!" is a failure marker: report it, and nothing else
  if printf '%s\n' "$AD_ROWS" | grep -q '^!'; then echo '! !'; return 0; fi
  # the signature blob of each row, one line per row ("<name> missing" when there is none); a row left without
  # one (cat-file failed) is still listed
  { printf '%s\n' "$AD_ROWS"; echo =
    printf '%s\n' "$AD_ROWS" | awk -F'\t' '{ print $1 ":" $2 ".sig" }' | ad_git cat-file --batch-check='%(objectname)'; } |
    awk -F'\t' '!s { if ($0 == "=") s = 1; else r[++m] = $0; next }
                 { split(r[++n], f, "\t"); b = /^[0-9a-f]+$/ ? $0 : "-"; if (!seen[f[2] "\t" f[3] "\t" b]++) print f[1], f[2] }
                 END { while (n < m) { split(r[++n], f, "\t"); print f[1], f[2] } }'
}
# ad_show <ref> <path>: a file's content as of <ref>
ad_show() { ad_git show "$1:$2" 2>/dev/null; }
