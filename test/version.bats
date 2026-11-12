#!/usr/bin/env bats
# The CLI's version, and updating it: --version names the commit of a clone of the CLI, and only of one.

load helpers

setup_file() {
  # the tests share one clone, and the last two change it: never run them side by side
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  export T; T=$(workdir)
  mkdir -p "$T/seed" "$T/copy/bin" "$T/nogit" "$T/dotseed/tools" "$T/lone/bin"
  # a clone of the CLI with an upstream, made from this checkout's files so the tests run the code as it is now; its
  # folder's name has a space and a quote
  export C="$T/O'Neil clone"
  cp -R "$ROOTDIR/bin" "$ROOTDIR/adapters" "$T/seed/"; cp "$ROOTDIR/bin/agent-mailbox" "$T/copy/bin/"
  # repositories that track a copy but aren't clones of the CLI: one vendors it below its top, one has no adapters
  cp -R "$ROOTDIR/bin" "$ROOTDIR/adapters" "$T/dotseed/tools/"; cp "$ROOTDIR/bin/agent-mailbox" "$T/lone/bin/"
  for r in seed dotseed lone; do
    (cd "$T/$r" && git init -q && git config user.email s@s && git config user.name s && git add -A && git commit -qm v1)
  done
  git clone -q --bare "$T/seed" "$T/up.git"; git clone -q "$T/up.git" "$C"
  git clone -q --bare "$T/dotseed" "$T/dots.git"; git clone -q "$T/dots.git" "$T/dots"
  ln -s "$C/bin/agent-mailbox" "$T/link"
  for c in dirname basename readlink; do ln -s "$(command -v $c)" "$T/nogit/$c"; done
  export U="$C/bin/agent-mailbox"
  export sha; sha=$(git -C "$C" rev-parse --short HEAD)
  export plain='^agent-mailbox [0-9][0-9.]*(-[a-z0-9.]+)? \(protocol [0-9]+\)$'
}

@test "--version from a clone names its commit" {
  expect 0 "^agent-mailbox [0-9][0-9.]*(-[a-z0-9.]+)? \(protocol [0-9]+, $sha\)$" "$SH" "$U" --version
}

@test "and through a link to it" {
  expect 0 "\(protocol [0-9]+, $sha\)$" "$SH" "$T/link" --version
}

@test "--version marks local changes" {
  echo "# a local change" >> "$C/adapters/dir.sh"
  run "$SH" "$U" --version
  git -C "$C" checkout -q -- adapters/dir.sh
  expect 0 "\(protocol [0-9]+, $sha\+changes\)$" printf '%s\n' "$output"
}

@test "a copy outside any clone prints the plain version" {
  expect 0 "$plain" "$SH" "$T/copy/bin/agent-mailbox" --version
}

@test "even run from inside a clone" {
  expect 0 "$plain" sh -c 'cd "$1" && shift && exec "$@"' sh "$C/bin" "$SH" "$T/copy/bin/agent-mailbox" --version
}

@test "or with GIT_DIR naming one" {
  expect 0 "$plain" env GIT_DIR="$C/.git" GIT_WORK_TREE="$T/copy" "$SH" "$T/copy/bin/agent-mailbox" --version
}

@test "a copy inside a clone that doesn't track it prints the plain version" {
  mkdir -p "$C/extra"; cp "$U" "$C/extra/"
  run "$SH" "$C/extra/agent-mailbox" --version
  rm -rf "$C/extra"
  expect 0 "$plain" printf '%s\n' "$output"
}

@test "a copy another repository tracks below its top prints the plain version" {
  expect 0 "$plain" "$SH" "$T/dots/tools/bin/agent-mailbox" --version
}

@test "and so does a tracked bin/agent-mailbox without adapters/git.sh" {
  expect 0 "$plain" "$SH" "$T/lone/bin/agent-mailbox" --version
}

@test "without git, --version prints the plain version and nothing else" {
  want=$("$SH" "$T/copy/bin/agent-mailbox" --version)
  run env PATH="$T/nogit" "$(command -v "$SH")" "$U" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ] || { printf 'got:\n%s\nwanted:\n%s\n' "$output" "$want" >&2; return 1; }
}

# the update steps in README.md: fast-forward the clone, then --version names the new commit. These two change the
# clone, so they come last.
@test "the documented update fast-forwards the clone" {
  echo news > "$T/seed/NEWS"; (cd "$T/seed" && git add NEWS && git commit -qm v2 && git push -q "$T/up.git" HEAD)
  expect 0 - git -C "$C" pull -q --ff-only
}

@test "after the update, --version names the new commit" {
  expect 0 "\(protocol [0-9]+, $(git -C "$T/seed" rev-parse --short HEAD)\)$" "$SH" "$U" --version
}
