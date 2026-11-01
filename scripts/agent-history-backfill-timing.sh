#!/usr/bin/env bash
#
# Times a full Agent History backfill on this Mac's real agent history (spec §10 release
# gate: < 10 min at utility QoS). Builds and installs Zentty Dev, tells you how to turn Agent
# History on, then follows the app's AgentHistory log until the indexer reports `watching`.
#
# The script never reads agent history or the index itself: it only builds the app and
# watches its log (state names and counts, no paths or text). Run it from production Zentty
# or another terminal, not from a Zentty Dev pane (installing quits Zentty Dev).

set -euo pipefail
# awk prints and parses seconds with a decimal point whatever the user's locale.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSYSTEM="be.zenjoy.zentty"
CATEGORY="AgentHistory"

process_name="Zentty Dev"
timeout_seconds=3600
do_build=1
dry_run=0

usage() {
  cat <<USAGE
Usage: scripts/agent-history-backfill-timing.sh [options]

Builds and installs "Zentty Dev" (scripts/build-dev-release), then follows the
${SUBSYSTEM}:${CATEGORY} log and reports how long the indexer took from start
to 'backfilling' and to 'watching' (backfill done).

Options:
  --no-build           Skip the build; time the Zentty Dev that is installed.
  --process <name>     App process to follow (default: "${process_name}").
  --timeout <seconds>  Give up after this long (default: ${timeout_seconds}).
  --dry-run            Print what would run and exit.
  -h, --help           Show this help.

For a cold run, delete the index first (Settings > Agent History > Delete Index)
before starting the script.
USAGE
}

die() { echo "error: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) do_build=0 ;;
    --dry-run) dry_run=1 ;;
    --process)
      [[ $# -ge 2 && -n "$2" ]] || die "--process needs a name"
      process_name="$2"
      shift
      ;;
    --process=*)
      process_name="${1#--process=}"
      [[ -n "$process_name" ]] || die "--process needs a name"
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout needs a number of seconds"
      timeout_seconds="$2"
      shift
      ;;
    --timeout=*) timeout_seconds="${1#--timeout=}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -gt 0 ]] || die "--timeout must be a positive whole number"
[[ "$process_name" != *'"'* ]] || die "--process must not contain double quotes"

predicate="subsystem == \"${SUBSYSTEM}\" AND category == \"${CATEGORY}\" AND process == \"${process_name}\""

if (( dry_run )); then
  if (( do_build )); then
    echo "would run: ${SCRIPT_DIR}/build-dev-release"
  else
    echo "would skip the build (--no-build)"
  fi
  echo "would run: log stream --style compact --info --predicate '${predicate}'"
  echo "would stop at the first 'watching' state or after ${timeout_seconds} s"
  exit 0
fi

if (( do_build )); then
  echo "==> Building and installing Zentty Dev"
  "${SCRIPT_DIR}/build-dev-release"
fi

work_dir="$(mktemp -d)"
log_pid=""
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  if [[ -n "$log_pid" ]]; then
    kill "$log_pid" 2>/dev/null || true
    wait "$log_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkfifo "${work_dir}/log"
log stream --style compact --info --predicate "$predicate" > "${work_dir}/log" 2>&1 &
log_pid=$!
exec 3< "${work_dir}/log"

cat <<STEPS

==> Following ${process_name}'s Agent History log. Now:
    1. Open ${process_name}.
    2. Turn Agent History on: Settings > Agent History, or open Agent History and
       accept the consent card. Leave the app running in the foreground.
    3. Wait. The script stops when the indexer reports 'watching'.
    (A Mac on Low Power Mode or running hot pauses the backfill; that time counts.)

STEPS

# "2026-11-01 09:00:01.234 I  Zentty Dev[1:2] [be.zenjoy.zentty:AgentHistory] message"
# -> seconds since midnight of the log line.
line_seconds() {
  awk '{ split($2, t, ":"); printf "%.3f", t[1] * 3600 + t[2] * 60 + t[3] }' <<<"$1"
}

elapsed_since() {
  awk -v a="$1" -v b="$2" 'BEGIN { d = b - a; if (d < 0) d += 86400; printf "%.1f", d }'
}

started_at=""
backfilling_at=""
deadline=$(( SECONDS + timeout_seconds ))
while (( SECONDS < deadline )); do
  # A timed-out read fails like EOF on bash 3.2 (> 128 only from bash 4), so EOF is told
  # apart by whether `log stream` is still running.
  if ! IFS= read -r -t 5 line <&3; then
    if kill -0 "$log_pid" 2>/dev/null; then
      continue
    fi
    echo "error: log stream ended" >&2
    exit 1
  fi
  [[ "$line" == *"[${SUBSYSTEM}:${CATEGORY}]"* ]] || continue
  message="${line#*"[${SUBSYSTEM}:${CATEGORY}]" }"
  echo "    log: ${message}"
  now="$(line_seconds "$line")"
  case "$message" in
    *"controller started the indexer"*|*"indexer state off -> starting"*)
      if [[ -z "$started_at" ]]; then
        started_at="$now"
      fi
      ;;
    *"-> backfilling"*)
      if [[ -z "$backfilling_at" && -n "$started_at" ]]; then
        backfilling_at="$now"
        echo "==> Backfilling $(elapsed_since "$started_at" "$now") s after start"
      fi
      ;;
    *"-> paused."*)
      echo "==> Paused (${message##*-> }); the clock keeps running"
      ;;
    *"-> failed"*)
      echo "error: the indexer failed; see Settings > Agent History" >&2
      exit 1
      ;;
    *"-> watching"*)
      if [[ -n "$started_at" ]]; then
        total="$(elapsed_since "$started_at" "$now")"
        echo "==> Watching: full backfill took ${total} s ($(awk -v s="$total" 'BEGIN { printf "%.1f", s / 60 }') min)"
        echo "    Budget (spec §10): < 600 s for the full corpus."
        exit 0
      fi
      ;;
  esac
done

echo "error: no 'watching' state within ${timeout_seconds} s" >&2
exit 1
