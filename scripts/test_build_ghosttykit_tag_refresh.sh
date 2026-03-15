#!/usr/bin/env bash

set -euo pipefail

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REMOTE_REPO="$TMP_DIR/remote.git"
WORK_REPO="$TMP_DIR/work"
CACHE_REPO="$TMP_DIR/cache"

git init --bare "$REMOTE_REPO" >/dev/null
git clone "$REMOTE_REPO" "$WORK_REPO" >/dev/null 2>&1

cd "$WORK_REPO"
git config user.name "Codex"
git config user.email "codex@example.com"

echo "one" > file.txt
git add file.txt
git commit -m "first" >/dev/null
git tag -a tip -m "tip v1"
git push origin HEAD refs/tags/tip >/dev/null

git clone "$REMOTE_REPO" "$CACHE_REPO" >/dev/null 2>&1

echo "two" > file.txt
git add file.txt
git commit -m "second" >/dev/null
git tag -fa tip -m "tip v2" >/dev/null
git push origin HEAD >/dev/null
git push --force origin refs/tags/tip >/dev/null

set +e
git -C "$CACHE_REPO" fetch --tags --prune origin >/dev/null 2>&1
WITHOUT_FORCE_EXIT=$?
set -e

if [[ "$WITHOUT_FORCE_EXIT" -eq 0 ]]; then
  echo "Expected git fetch --tags --prune origin to fail when tag tip changes"
  exit 1
fi

git -C "$CACHE_REPO" fetch --tags --prune --force origin >/dev/null

LOCAL_TAG_TARGET="$(git -C "$CACHE_REPO" rev-parse refs/tags/tip^{})"
REMOTE_TAG_TARGET="$(git -C "$WORK_REPO" rev-parse refs/tags/tip^{})"

if [[ "$LOCAL_TAG_TARGET" != "$REMOTE_TAG_TARGET" ]]; then
  echo "Expected forced tag refresh to update local cache tag"
  echo "local:  $LOCAL_TAG_TARGET"
  echo "remote: $REMOTE_TAG_TARGET"
  exit 1
fi

echo "build_ghosttykit tag refresh regression passed"
