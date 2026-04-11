#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKTREE_DIR="${PROJECT_DIR}/tmp/iTerm2-Color-Schemes"
SOURCE_REPO_URL="https://github.com/mbadolato/iTerm2-Color-Schemes.git"
SOURCE_THEME_DIR="${WORKTREE_DIR}/ghostty"
SOURCE_LICENSE_FILE="${WORKTREE_DIR}/LICENSE"
THEMES_DEST_DIR="${PROJECT_DIR}/ZenttyResources/ghostty/themes"
LICENSE_DEST_DIR="${PROJECT_DIR}/ZenttyResources/licenses/iTerm2-Color-Schemes"
LICENSE_DEST_FILE="${LICENSE_DEST_DIR}/LICENSE"

echo "Syncing Ghostty-compatible themes from ${SOURCE_REPO_URL}"

if [ ! -d "${WORKTREE_DIR}/.git" ]; then
  git clone --depth 1 --filter=blob:none --sparse "${SOURCE_REPO_URL}" "${WORKTREE_DIR}"
else
  git -C "${WORKTREE_DIR}" remote set-url origin "${SOURCE_REPO_URL}"
  git -C "${WORKTREE_DIR}" fetch --depth 1 origin
fi

git -C "${WORKTREE_DIR}" sparse-checkout init --no-cone
git -C "${WORKTREE_DIR}" sparse-checkout set --no-cone /ghostty /LICENSE

DEFAULT_BRANCH="$(git -C "${WORKTREE_DIR}" symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')"
if [ -z "${DEFAULT_BRANCH}" ]; then
  echo "error: failed to determine upstream default branch" >&2
  exit 1
fi

git -C "${WORKTREE_DIR}" checkout --force "${DEFAULT_BRANCH}"
git -C "${WORKTREE_DIR}" reset --hard "origin/${DEFAULT_BRANCH}"
git -C "${WORKTREE_DIR}" clean -fdx

if [ ! -d "${SOURCE_THEME_DIR}" ]; then
  echo "error: expected theme directory not found at ${SOURCE_THEME_DIR}" >&2
  exit 1
fi

if [ ! -f "${SOURCE_LICENSE_FILE}" ]; then
  echo "error: expected license file not found at ${SOURCE_LICENSE_FILE}" >&2
  exit 1
fi

mkdir -p "${THEMES_DEST_DIR}" "${LICENSE_DEST_DIR}"
rsync -a --delete "${SOURCE_THEME_DIR}/" "${THEMES_DEST_DIR}/"
install -m 644 "${SOURCE_LICENSE_FILE}" "${LICENSE_DEST_FILE}"

xcrun swift "${PROJECT_DIR}/scripts/generate_third_party_licenses.swift"

echo "Updated vendored Ghostty themes and attribution data."
