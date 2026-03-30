#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${SCRIPT_DIR}/ghosttykit.lock"

if [[ ! -f "${LOCK_FILE}" ]]; then
  echo "GhosttyKit lock file not found at ${LOCK_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${LOCK_FILE}"

: "${repo:?Missing repo in ${LOCK_FILE}}"
: "${revision:?Missing revision in ${LOCK_FILE}}"
: "${build_target:?Missing build_target in ${LOCK_FILE}}"

CACHE_ROOT="${HOME}/Library/Caches/zentty"
SOURCE_DIR="${CACHE_ROOT}/ghostty-src"
OUTPUT_DIR="${REPO_ROOT}/FrameworksLocal"
ARTIFACT_SOURCE="${SOURCE_DIR}/macos/GhosttyKit.xcframework"
ARTIFACT_DEST="${OUTPUT_DIR}/GhosttyKit.xcframework"

require_command() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}. ${install_hint}" >&2
    exit 1
  fi
}

require_command git "Install Xcode command line tools."
require_command rsync "Install rsync."
require_command zig "Install Zig, for example via: brew install zig"
require_command brew "Install Homebrew."
require_command xcode-select "Install full Xcode."
require_command xcrun "Install full Xcode."

XCODE_PATH="$(xcode-select --print-path)"
if [[ "${XCODE_PATH}" != */Xcode*.app/Contents/Developer ]]; then
  echo "Full Xcode is not selected. Current developer dir: ${XCODE_PATH}" >&2
  echo "Select full Xcode with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if ! brew list gettext >/dev/null 2>&1; then
  echo "Missing required Homebrew package: gettext. Install with: brew install gettext" >&2
  exit 1
fi

if ! xcrun --find metal >/dev/null 2>&1; then
  echo "Missing Metal Toolchain. Install with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

mkdir -p "${CACHE_ROOT}" "${OUTPUT_DIR}"

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  git clone "${repo}" "${SOURCE_DIR}"
fi

# Ghostty updates the moving `tip` tag, so cached clones need forced tag refreshes.
git -C "${SOURCE_DIR}" fetch --tags --prune --force origin
git -C "${SOURCE_DIR}" checkout --detach "${revision}"

(
  cd "${SOURCE_DIR}"
  zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target="${build_target}"
)

if [[ ! -d "${ARTIFACT_SOURCE}" ]]; then
  echo "GhosttyKit.xcframework was not produced at ${ARTIFACT_SOURCE}" >&2
  exit 1
fi

mkdir -p "${ARTIFACT_DEST}"
rsync -a --delete "${ARTIFACT_SOURCE}/" "${ARTIFACT_DEST}/"

echo "Built GhosttyKit.xcframework"
echo "Revision: ${revision}"
echo "Source: ${SOURCE_DIR}"
echo "Output: ${ARTIFACT_DEST}"
