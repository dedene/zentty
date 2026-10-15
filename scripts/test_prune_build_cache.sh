#!/usr/bin/env bash
#
# Regression test for scripts/prune-build-cache against a throwaway repo,
# DerivedData and Archives tree, with a stub `trash` that only records moves.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prune-build-cache"

TMP_DIR="$(cd "$(mktemp -d)" && pwd -P)"
holder_pid=""
cleanup() {
  if [[ -n "$holder_pid" ]]; then kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null; fi || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

REPO="$TMP_DIR/repo"
WTS="$TMP_DIR/worktrees"
DD="$TMP_DIR/DerivedData"
ARCHIVES="$TMP_DIR/Archives"
TRASHED="$TMP_DIR/trashed"
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$WTS" "$DD" "$ARCHIVES" "$TRASHED" "$STUB_BIN"

cat >"$STUB_BIN/trash" <<STUB
#!/usr/bin/env bash
for item in "\$@"; do
  dest="\$(mktemp -d "$TRASHED/item.XXXXXX")"
  mv "\$item" "\$dest/"
  echo "\$item" >>"$TRASHED/log"
done
STUB
chmod +x "$STUB_BIN/trash"

git init -q -b main "$REPO"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config user.email "test@example.com"
echo base >"$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm base

# merged: has its own commit, merged into main with a merge commit.
add_merged_worktree() {
  local name="$1"
  git -C "$REPO" worktree add -q -b "$name" "$WTS/$name"
  echo "$name" >"$WTS/$name/$name.txt"
  git -C "$WTS/$name" add "$name.txt"
  git -C "$WTS/$name" commit -qm "$name"
  git -C "$REPO" merge -q --no-ff --no-edit "$name"
}

add_merged_worktree merged
add_merged_worktree dirty
echo scratch >"$WTS/dirty/untracked.txt"
add_merged_worktree busy

git -C "$REPO" worktree add -q -b fresh "$WTS/fresh"

git -C "$REPO" worktree add -q -b unmerged "$WTS/unmerged"
echo wip >"$WTS/unmerged/wip.txt"
git -C "$WTS/unmerged" add wip.txt
git -C "$WTS/unmerged" commit -qm wip

git -C "$REPO" worktree add -q --detach "$WTS/detached"

add_merged_worktree locked
git -C "$REPO" worktree lock "$WTS/locked"

add_merged_worktree vanished
rm -rf "$WTS/vanished"

# Ignored build output must not block pruning a merged worktree.
echo "FrameworksLocal/" >>"$(git -C "$REPO" rev-parse --path-format=absolute --git-path info/exclude)"
mkdir -p "$WTS/merged/FrameworksLocal"
echo blob >"$WTS/merged/FrameworksLocal/GhosttyKit"

(cd "$WTS/busy" && exec sleep 300) &
holder_pid=$!

make_dd() {
  local dir="$DD/$1"
  mkdir -p "$dir/Build"
  echo data >"$dir/Build/blob"
  plutil -create xml1 "$dir/info.plist"
  plutil -insert WorkspacePath -string "$2" "$dir/info.plist"
}
make_dd Zentty-main "$REPO/Zentty.xcodeproj"
make_dd Zentty-gone "$TMP_DIR/deleted-checkout/Zentty.xcodeproj"
make_dd Zentty-merged "$WTS/merged/Zentty.xcodeproj"
make_dd Zentty-unmerged "$WTS/unmerged/Zentty.xcodeproj"
make_dd Other-gone "$TMP_DIR/other/Other.xcodeproj"
mkdir -p "$REPO/Zentty.xcodeproj" "$WTS/unmerged/Zentty.xcodeproj"

for day in 01 02 03 04 05; do
  mkdir -p "$ARCHIVES/2026-10-$day/Zentty 2026-10-$day 12.00.00.xcarchive"
  touch -t "202610${day}1200" "$ARCHIVES/2026-10-$day/Zentty 2026-10-$day 12.00.00.xcarchive"
done
mkdir -p "$ARCHIVES/2026-09-01/Bingo 2026-09-01 12.00.00.xcarchive"

run_prune() {
  (cd "$TMP_DIR" && PATH="$STUB_BIN:$PATH" \
    ZENTTY_PRUNE_REPO="$REPO" ZENTTY_DERIVED_DATA_DIR="$DD" ZENTTY_XCODE_ARCHIVES_DIR="$ARCHIVES" \
    "$SCRIPT" --no-gh "$@")
}

# --- Dry run touches nothing -------------------------------------------------

output="$(run_prune)"
[[ ! -e "$TRASHED/log" ]] || fail "dry run moved items to the Trash"
for expected in "$WTS/merged" "$DD/Zentty-gone" "$DD/Zentty-merged" "2026-10-02 12.00.00.xcarchive" "Dry run:"; do
  grep -qF "$expected" <<<"$output" || fail "dry run output misses $expected"$'\n'"$output"
done

# --- Apply moves exactly the expected items ----------------------------------

run_prune --apply >/dev/null

expected_trashed="$(printf '%s\n' \
  "$WTS/merged" \
  "$DD/Zentty-gone" \
  "$DD/Zentty-merged" \
  "$ARCHIVES/2026-10-01/Zentty 2026-10-01 12.00.00.xcarchive" \
  "$ARCHIVES/2026-10-02/Zentty 2026-10-02 12.00.00.xcarchive" | sort)"
actual_trashed="$(sort "$TRASHED/log")"
if [[ "$actual_trashed" != "$expected_trashed" ]]; then
  fail "trashed items differ"$'\n'"expected:"$'\n'"$expected_trashed"$'\n'"actual:"$'\n'"$actual_trashed"
fi

for kept in dirty busy fresh unmerged detached locked; do
  [[ -d "$WTS/$kept" ]] || fail "worktree $kept was removed"
done
for kept in Zentty-main Zentty-unmerged Other-gone; do
  [[ -d "$DD/$kept" ]] || fail "DerivedData $kept was removed"
done
[[ -d "$ARCHIVES/2026-09-01/Bingo 2026-09-01 12.00.00.xcarchive" ]] || fail "non-Zentty archive was removed"

worktrees="$(git -C "$REPO" worktree list --porcelain)"
grep -qF "worktree $WTS/merged" <<<"$worktrees" && fail "pruned worktree is still registered"
grep -qF "worktree $WTS/vanished" <<<"$worktrees" && fail "stale worktree record was not pruned"
git -C "$REPO" show-ref --verify --quiet refs/heads/merged || fail "branch of pruned worktree was deleted"

# --- Second run finds nothing left -------------------------------------------

output="$(run_prune)"
grep -qF "Dry run: 0K can be freed" <<<"$output" || fail "second run still finds work"$'\n'"$output"

echo "prune-build-cache regression passed"
