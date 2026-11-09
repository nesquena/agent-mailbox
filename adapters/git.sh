# git.sh: the git adapter. The store is any git repository you can push to (a dedicated private repo is best);
# the mailbox lives under $ROOT/ on $BRANCH. The CLI keeps its own clone of it under $STATE/checkouts/, so it never
# touches a working tree you use for anything else. Contract: adapters/README.md.
#
# Reliability rules this adapter keeps (each one was a real failure):
# - Never `git pull`: it reads FETCH_HEAD, which a watcher fetching in the same clone can rewrite mid-pull. Fetch
#   into origin/<branch> explicitly, then rebase onto that ref.
# - A rejected push (someone pushed first) fetches, rebases and retries, with a random pause.
# - A commit left unpublished by an earlier failure is published by the next command; nothing is resent.
# - A rebase that stops part-way is aborted, so the clone is never left mid-rebase.
# - The watcher's peek fetch writes only its own ref (`--refmap=`): git updates a ref only from the value it read, so a
#   peek that also moved origin/<branch> made a send's fetch or push in this clone fail.
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
ad_g() { GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git -c submodule.recurse=false -c core.hooksPath=/dev/null \
  -c core.fsmonitor= "$@"; }
ad_git() { ad_g -C "$AD_DIR" "$@"; }
ad_jitter() { sleep "$(od -An -N1 -tu1 /dev/urandom | awk 'NF {printf "%.2f", 0.2 + $1 / 255 * 1.8; exit}')"; }
ad_gist() { sed -E 's#//[^@/]*@#//***@#g' | grep -v '^hint:' | tail -n 3 | tr '\n' ' '; }
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
  if [ ! -d "$AD_DIR/.git" ]; then
    mkdir -p "$STATE/checkouts" || die "can't create $STATE/checkouts"
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
    if ad_remote_has_branch; then ad_git checkout -q -B "$BRANCH" "origin/$BRANCH"
    else ad_git symbolic-ref HEAD "refs/heads/$BRANCH" && ad_git read-tree --empty
    fi || { rm -rf "$AD_DIR"; die "can't check out the store"; }
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
  ferr=$(ad_git fetch -q origin "$AD_SPEC" 2>&1) || {
    # an empty store has no branch yet: that's not an error (exit 2), but a store that can't be reached is, and so is
    # a branch gone from the store since this clone fetched it
    ad_git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1
    case $? in (2) ad_remote_has_branch || return 0
      printf 'the store no longer has the branch %s; if it was re-created, delete %s and run this again\n' "$BRANCH" "$AD_DIR"
      return 1 ;; esac
    printf '%s\n' "$ferr"; return 1; }
  ad_remote_has_branch || return 0
  if ad_git rev-parse -q --verify HEAD >/dev/null; then
    ad_git rebase -q --autostash "origin/$BRANCH" 2>&1 >/dev/null || { ad_git rebase --abort >/dev/null 2>&1; return 1; }
  else
    ad_git reset -q --hard "origin/$BRANCH"
  fi
}

ad_push() {
  n=0
  until perr=$(ad_git push -q origin "HEAD:refs/heads/$BRANCH" 2>&1); do
    n=$((n+1))
    [ $n -lt 10 ] || { warn "written locally, not published (push failed 10 times: $(printf '%s\n' "$perr" | ad_gist)); re-run a command with the same name to publish it, don't resend"; exit 4; }
    ad_jitter
    rerr=$(ad_pull) || { warn "written locally, not published: $(printf '%s\n' "$rerr" | ad_gist); re-run a command with the same name, don't resend"; exit 4; }
  done
}

ad_sync() {
  err=$(ad_pull) || die "can't update from the store: $(printf '%s\n' "$err" | ad_gist)"
  # publish anything an earlier command committed but couldn't push
  if ad_remote_has_branch && [ -n "$(ad_git log --format=%h "origin/$BRANCH..HEAD" 2>/dev/null)" ]; then
    warn "publishing $(ad_git rev-list --count "origin/$BRANCH..HEAD") commit(s) left from an earlier command"
    ad_push
  fi
}

# ad_commit <message> <path>...: publish exactly these paths (added, changed or removed), nothing else
ad_commit() {
  msg=$1; shift; keep=""
  for p in "$@"; do
    if [ -e "$AD_DIR/$p" ] || ad_git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then keep="$keep $p"; fi
  done
  [ -n "$keep" ] || return 0
  # shellcheck disable=SC2086
  ad_git add -A -f -- $keep || die "git add failed"
  # shellcheck disable=SC2086
  ad_git commit -q -m "$msg" -- $keep >/dev/null || die "git commit failed"
  ad_push
}

# a cheap token that changes whenever the store changes: the branch tip, from one small network round trip
ad_poll() { ad_git ls-remote origin "refs/heads/$BRANCH" | cut -f1; }

# ad_peek <dir>: files under <dir> in the store's latest state, without touching the working tree
ad_peek() {
  ad_git fetch -q --refmap= origin "+refs/heads/$BRANCH:refs/agent-mailbox/peek" 2>/dev/null || return 1
  ad_git ls-tree refs/agent-mailbox/peek "$1/" 2>/dev/null | awk -F'\t' '$1 ~ /^100(644|755) blob / { print $2 }'
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
  # a fetch of its own proves the store is reachable, and the walk reads what it fetched (never a stale HEAD)
  u=; [ "$(ad_git rev-parse --is-shallow-repository)" = true ] && u=--unshallow
  ad_git fetch -q $u origin "$AD_SPEC" 2>/dev/null || { echo '! !'; return 0; }
  tip=$(ad_git rev-parse -q --verify "refs/remotes/origin/$BRANCH") || { echo '! !'; return 0; }
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
