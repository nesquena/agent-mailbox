# dir.sh: the directory adapter. The store is a plain folder that every agent can read and write: agents on one
# machine, or a shared or synced folder. There's no network and no history: `holds` sees only mail still in the
# inbox, so consumed releases are forgotten. Good for local setups and tests; use git when agents span machines.
# Contract: adapters/README.md.

ad_open() {
  AD_DIR="$STORE"
  [ -d "$AD_DIR" ] || mkdir -p "$AD_DIR" || die "can't create the store folder $AD_DIR"
}
ad_sync() { :; }
# writes already landed in place (the CLI writes each file to a temp name, then renames it), so there's nothing
# to publish. ceiling: no lock, so two writers can race on the same new file name; use git for many writers.
ad_commit() { :; }
ad_poll() { find "$AD_DIR/$ROOT" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort | cksum | cut -d' ' -f1-2 | tr ' ' '-'; }
ad_peek() { [ -d "$AD_DIR/$1" ] || return 0; ( cd "$AD_DIR" && find "$1" -maxdepth 1 -type f | LC_ALL=C sort ); }
ad_history() { ad_peek "$1" | while read -r p; do echo "- $p"; done; }
ad_show() { cat "$AD_DIR/$2" 2>/dev/null; }
