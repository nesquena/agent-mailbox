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
# - Commits carry the agent's mailbox name as author, never a person's name or email.
# - Symlinks in the store are checked out as plain files (core.symlinks=false), and `ad_peek` lists only regular
#   files, so a link a writer plants can't redirect writes or wake a watcher.

AD_SPEC="+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
ad_git() { git -C "$AD_DIR" "$@"; }
ad_jitter() { sleep "$(od -An -N1 -tu1 /dev/urandom | awk 'NF {printf "%.2f", 0.2 + $1 / 255 * 1.8; exit}')"; }
ad_gist() { sed -E 's#//[^@/]*@#//***@#g' | grep -v '^hint:' | tail -n 3 | tr '\n' ' '; }
ad_remote_has_branch() { ad_git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null; }

ad_open() {
  command -v git >/dev/null 2>&1 || die "the git adapter needs git"
  AD_DIR="$STATE/checkouts/$STORE_ID"
  if [ ! -d "$AD_DIR/.git" ]; then
    mkdir -p "$STATE/checkouts" || die "can't create $STATE/checkouts"
    err=$(git clone -q --no-checkout -- "$STORE" "$AD_DIR" 2>&1) || { rm -rf "$AD_DIR"; die "can't clone the store: $(printf '%s\n' "$err" | ad_gist)"; }
    ad_git config core.symlinks false
    # check out the mailbox branch itself, whatever the store's default branch is; a new store gets an empty one
    ad_git fetch -q origin "$AD_SPEC" 2>/dev/null
    if ad_remote_has_branch; then ad_git checkout -q -B "$BRANCH" "origin/$BRANCH"
    else ad_git checkout -q --orphan "$BRANCH"; fi
  fi
  # an older clone may hold links checked out before this rule: replace them with plain files
  if [ "$(ad_git config core.symlinks)" != false ]; then
    ad_git config core.symlinks false
    ad_git ls-files -s | awk '$1 == "120000" { sub(/^[^\t]*\t/, ""); print }' | while IFS= read -r l; do
      rm -f "$AD_DIR/$l" && ad_git checkout -q -- "$l"; done
  fi
  ad_git config user.name "${ME:-agent-mailbox}"
  ad_git config user.email "${ME:-agent-mailbox}@agent-mailbox.invalid"
}

# fetch, then rebase local commits onto origin/<branch>; prints git's error on failure
ad_pull() {
  ferr=$(ad_git fetch -q origin "$AD_SPEC" 2>&1) || {
    # an empty store has no branch yet: that's not an error
    ad_git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1 && { printf '%s\n' "$ferr"; return 1; }
    return 0; }
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
    [ $n -lt 10 ] || { warn "written locally, not published (push failed 10 times: $(printf '%s\n' "$perr" | ad_gist)); re-run any command to publish it, don't resend"; exit 4; }
    ad_jitter
    rerr=$(ad_pull) || { warn "written locally, not published: $(printf '%s\n' "$rerr" | ad_gist); re-run any command, don't resend"; exit 4; }
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
  ad_git add -A -- $keep || die "git add failed"
  # shellcheck disable=SC2086
  ad_git commit -q -m "$msg" -- $keep >/dev/null || die "git commit failed"
  ad_push
}

# a cheap token that changes whenever the store changes: the branch tip, from one small network round trip
ad_poll() { ad_git ls-remote origin "refs/heads/$BRANCH" | cut -f1; }

# ad_peek <dir>: files under <dir> in the store's latest state, without touching the working tree
ad_peek() {
  ad_git fetch -q origin "+refs/heads/$BRANCH:refs/agent-mailbox/peek" 2>/dev/null || return 1
  ad_git ls-tree refs/agent-mailbox/peek "$1/" 2>/dev/null | awk -F'\t' '$1 ~ /^100(644|755) blob / { print $2 }'
}

# ad_history <dir> [<ERE>]: "<ref> <path>" for every version of every file that was ever under <dir>, oldest first
# (consumed files included), however it got there. holds builds a security gate on this, so no git history filter
# may hide a version: --full-history and -m visit every commit and both sides of every merge (history
# simplification could skip a commit), --no-renames counts a renamed file as added, A and M count added and rewritten
# files, and --text --no-textconv search every file as plain text (an attribute or a NUL byte could otherwise make
# git skip it as binary). With a pattern, only versions whose change adds a line matching it (git log -G, an
# extended regex) are listed; every listed file is still checked by the CLI. log.diffMerges is pinned, so a user's
# setting can't turn off -m's merge diffs; rows are unique per path and content, so merges can't multiply the work.
ad_history() {
  [ "$(ad_git rev-parse --is-shallow-repository)" = true ] && ad_git fetch -q --unshallow origin "$AD_SPEC" 2>/dev/null
  ad_git -c log.diffMerges=separate log --reverse --full-history -m --no-renames --diff-filter=AMT --raw --no-abbrev --format='C %H' \
    ${2:+--text --no-textconv "-G$2"} HEAD -- "$1/" 2>/dev/null |
    awk '$1 == "C" && NF == 2 { c = $2; next }
         /^:/ { i = index($0, "\t"); p = substr($0, i + 1); split(substr($0, 1, i - 1), f, " "); if (!seen[p " " f[4]]++) print c, p }'
}
# ad_show <ref> <path>: a file's content as of <ref>
ad_show() { ad_git show "$1:$2" 2>/dev/null; }
