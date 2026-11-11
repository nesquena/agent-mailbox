# dir.sh: the directory adapter. The store is a plain folder that every agent can read and write: agents on one
# machine, or a shared or synced folder. There's no network and no history: `holds` sees only mail still in the
# inbox, so consumed releases are forgotten. Good for local setups and tests; use git when agents span machines.
# Contract: adapters/README.md.

ad_open() {
  # a relative store path starting with '-' would be read as an option by mkdir and find
  case "$STORE" in (-*) AD_DIR="./$STORE" ;; (*) AD_DIR="$STORE" ;; esac
  [ -d "$AD_DIR" ] || mkdir -p "$AD_DIR" || die "can't create the store folder $AD_DIR"
}
ad_sync() { :; }
# no clone of its own to guard: each write lands in place (a rename, or a hard link for a new message)
ad_unlock() { :; }
# writes already landed in place (the CLI writes each file to a temp name, then renames it into place, or, for a new
# message, hard-links it there so a name another send took first isn't replaced), so there's nothing to publish.
# ceiling: no lock, so two writers replacing the same file (a registry record) race, and a file system without hard
# links falls back to the rename for messages too; use git for many writers.
ad_commit() { :; }
# a mailbox folder (or its store.md) that's gone, say the store folder was moved away, fails the poll and the peek:
# cksum of no files still prints a value, and a missing folder would otherwise read as "no mail". An inbox folder that
# doesn't exist yet, in a mailbox that does, is no mail
ad_poll() { [ -f "$AD_DIR/$ROOT/store.md" ] || return 1
  find "$AD_DIR/$ROOT" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort | cksum | cut -d' ' -f1-2 | tr ' ' '-'; }
# (the peek checks store.md before and after listing, so a store moved away, or whose store.md goes before the listing
# ends, fails it rather than reading as no mail, or as fewer messages)
ad_peek() { [ -f "$AD_DIR/$ROOT/store.md" ] || return 1; pl=""
  if [ -d "$AD_DIR/$1" ] && [ ! -L "$AD_DIR/$1" ]; then
    pl=$(CDPATH= cd -P -- "$AD_DIR" && find "$1" -maxdepth 1 -type f ! -name "*$NL*") || return 1; fi
  [ -f "$AD_DIR/$ROOT/store.md" ] || return 1
  [ -z "$pl" ] || printf '%s\n' "$pl" | LC_ALL=C sort; }
# (a failed peek is the `! !` row, never fewer rows: holds then stops rather than read a gone store as an empty one)
ad_history() { p=$(ad_peek "$1") || { echo '! !'; return 0; }
  [ -z "$p" ] || printf '%s\n' "$p" | while IFS= read -r l; do printf '%s %s\n' - "$l"; done; }
# (a plain file only: a link is no file of the store's, as read and verify also hold)
ad_show() { [ -f "$AD_DIR/$2" ] && [ ! -L "$AD_DIR/$2" ] && cat "$AD_DIR/$2" 2>/dev/null; }
