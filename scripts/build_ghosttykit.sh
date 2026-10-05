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
if ! command -v brew >/dev/null 2>&1 && ! command -v port >/dev/null 2>&1; then
  echo "Missing package manager: brew or port. Install Homebrew or MacPorts." >&2
  exit 1
fi
require_command xcode-select "Install full Xcode."
require_command xcodebuild "Install full Xcode."
require_command xcrun "Install full Xcode."

resolve_zig_command() {
  if [[ -z "${zig_version:-}" ]]; then
    require_command zig "Install Zig, for example via: brew install zig"
    echo "zig"
    return
  fi

  if command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == "${zig_version}" ]]; then
    echo "zig"
    return
  fi

  local major_minor="${zig_version%.*}"
  local formula="zig@${major_minor}"
  local formula_prefix
  if command -v brew >/dev/null 2>&1 && formula_prefix="$(brew --prefix "${formula}" 2>/dev/null)"; then
    local candidate="${formula_prefix}/bin/zig"
    if [[ -x "${candidate}" && "$("${candidate}" version)" == "${zig_version}" ]]; then
      echo "${candidate}"
      return
    fi
  fi

  if command -v port >/dev/null 2>&1; then
    local candidate="/opt/local/bin/zig"
    if [[ -x "${candidate}" ]]; then
      local current_version
      current_version=$("${candidate}" version)
      if [[ "${current_version}" == "${zig_version}" ]]; then
        echo "${candidate}"
        return
      fi
    fi
  fi

  echo "Missing required Zig version ${zig_version}." >&2
  echo "Install it with: brew install zig OR sudo port install zig" >&2
  exit 1
}

ZIG_COMMAND="$(resolve_zig_command)"

XCODE_PATH="$(xcode-select --print-path)"
if [[ "${XCODE_PATH}" != */Xcode*.app/Contents/Developer ]]; then
  echo "Full Xcode is not selected. Current developer dir: ${XCODE_PATH}" >&2
  echo "Select full Xcode with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

# Newer Xcode releases ship the Metal compiler as a separately installed
# toolchain. Select it explicitly when available; otherwise xcrun may resolve
# the XcodeDefault shim, which reports that the installed toolchain is missing.
METAL_TOOLCHAINS="${TOOLCHAINS:-}"
if METAL_COMPONENT_INFO="$(xcodebuild -showComponent MetalToolchain 2>/dev/null)"; then
  METAL_TOOLCHAIN_ID=""
  while IFS= read -r line; do
    if [[ "${line}" == "Toolchain Identifier: "* ]]; then
      METAL_TOOLCHAIN_ID="${line#Toolchain Identifier: }"
      break
    fi
  done <<< "${METAL_COMPONENT_INFO}"

  if [[ -n "${METAL_TOOLCHAIN_ID}" ]]; then
    METAL_TOOLCHAINS="${METAL_TOOLCHAIN_ID}${METAL_TOOLCHAINS:+ ${METAL_TOOLCHAINS}}"
  fi
fi

# Always keep at least `env` in the array: expanding an empty array with
# "${BUILD_ENV[@]}" trips `set -u` on macOS's bash 3.2.
BUILD_ENV=(env)
if [[ -n "${METAL_TOOLCHAINS}" ]]; then
  BUILD_ENV+=("TOOLCHAINS=${METAL_TOOLCHAINS}")
fi

has_gettext=0
if command -v brew >/dev/null 2>&1 && brew list gettext >/dev/null 2>&1; then
  has_gettext=1
elif command -v port >/dev/null 2>&1 && port installed gettext | grep -q "active"; then
  has_gettext=1
elif command -v msgfmt >/dev/null 2>&1; then
  has_gettext=1
fi

if [[ "$has_gettext" -eq 0 ]]; then
  echo "Missing required package: gettext. Install with: brew install gettext OR sudo port install gettext" >&2
  exit 1
fi

if ! "${BUILD_ENV[@]}" xcrun --find metal >/dev/null 2>&1; then
  echo "Missing Metal Toolchain. Install with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

mkdir -p "${CACHE_ROOT}" "${OUTPUT_DIR}"

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  git clone "${repo}" "${SOURCE_DIR}"
else
  CURRENT_ORIGIN="$(git -C "${SOURCE_DIR}" remote get-url origin)"
  if [[ "${CURRENT_ORIGIN}" != "${repo}" ]]; then
    git -C "${SOURCE_DIR}" remote set-url origin "${repo}"
  fi
fi

# Ghostty updates the moving `tip` tag, so cached clones need forced tag refreshes.
git -C "${SOURCE_DIR}" fetch --tags --prune --force origin
git -C "${SOURCE_DIR}" checkout --force --detach "${revision}"

# Ghostty uses kCVPixelFormatType_30RGB_r210 (macOS 14+ CoreVideo constant); patch to the
# equivalent raw FourCC so GhosttyKit compiles with a macOS 13 minimum target.
pixel_format_file="${SOURCE_DIR}/pkg/macos/video/pixel_format.zig"
if grep -q "kCVPixelFormatType_30RGB_r210" "${pixel_format_file}"; then
  sed -i '' 's/c.kCVPixelFormatType_30RGB_r210/0x72323130/g' "${pixel_format_file}"
  grep -q "0x72323130" "${pixel_format_file}" || { echo "pixel_format patch failed" >&2; exit 1; }
fi

(
  cd "${SOURCE_DIR}"
  "${BUILD_ENV[@]}" "${ZIG_COMMAND}" build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target="${build_target}"
)

if [[ ! -d "${ARTIFACT_SOURCE}" ]]; then
  echo "GhosttyKit.xcframework was not produced at ${ARTIFACT_SOURCE}" >&2
  exit 1
fi

mkdir -p "${ARTIFACT_DEST}"
rsync -a --delete "${ARTIFACT_SOURCE}/" "${ARTIFACT_DEST}/"

echo "Built GhosttyKit.xcframework"
echo "Revision: ${revision}"
echo "Zig: $("${ZIG_COMMAND}" version)"
echo "Source: ${SOURCE_DIR}"
echo "Output: ${ARTIFACT_DEST}"
