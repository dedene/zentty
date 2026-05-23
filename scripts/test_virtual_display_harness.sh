#!/usr/bin/env zsh
set -euo pipefail
unsetopt BG_NICE

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zentty-virtual-display-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"
zdot_dir="$tmp_dir/zdot"
mkdir -p "$zdot_dir"
: > "$zdot_dir/.zshenv"

fake_betterdisplay="$tmp_dir/fake-betterdisplay"
fake_curl="$bin_dir/curl"
fake_screen_probe="$tmp_dir/screen-exists"
xcodebuild_log="$tmp_dir/xcodebuild.log"
betterdisplay_log="$tmp_dir/betterdisplay.log"
curl_log="$tmp_dir/curl.log"
display_state="$tmp_dir/display-created"

cat > "$fake_betterdisplay" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail

print -r -- "$*" >> "$ZENTTY_FAKE_BETTERDISPLAY_LOG"

case "${1:-}" in
  create)
    sleep 0.2
    touch "$ZENTTY_FAKE_DISPLAY_STATE"
    ;;
  set)
    [[ -f "$ZENTTY_FAKE_DISPLAY_STATE" ]]
    ;;
  discard)
    rm -f "$ZENTTY_FAKE_DISPLAY_STATE"
    exit 0
    ;;
esac
EOF
chmod +x "$fake_betterdisplay"
ln -s "$fake_betterdisplay" "$bin_dir/betterdisplaycli"

cat > "$fake_curl" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail

print -r -- "$*" >> "$ZENTTY_FAKE_CURL_LOG"

case "$*" in
  *"/help"*)
    exit 0
    ;;
  *"/create"*)
    if [[ "${ZENTTY_FAKE_CURL_CREATE_STATUS:-}" == "404" ]]; then
      print -u2 "curl: (22) The requested URL returned error: 404"
      exit 22
    fi
    touch "$ZENTTY_FAKE_DISPLAY_STATE"
    exit 0
    ;;
  *"/set"*)
    [[ -f "$ZENTTY_FAKE_DISPLAY_STATE" ]]
    exit 0
    ;;
  *"/discard"*)
    rm -f "$ZENTTY_FAKE_DISPLAY_STATE"
    exit 0
    ;;
esac

exit 1
EOF
chmod +x "$fake_curl"

cat > "$fake_screen_probe" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail
[[ -f "$ZENTTY_FAKE_DISPLAY_STATE" ]]
EOF
chmod +x "$fake_screen_probe"

cat > "$bin_dir/xcodebuild" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail
print -r -- "$*" >> "$ZENTTY_FAKE_XCODEBUILD_LOG"
[[ -f "$ZENTTY_FAKE_DISPLAY_STATE" ]]
sleep 0.2
[[ -f "$ZENTTY_FAKE_DISPLAY_STATE" ]]
EOF
chmod +x "$bin_dir/xcodebuild"

run_harness() {
  PATH="$bin_dir:$PATH" \
    ZDOTDIR="$zdot_dir" \
    ZENTTY_TEST_DISPLAY_PROVIDER=betterdisplay \
    ZENTTY_BETTERDISPLAY_COMMAND="$fake_betterdisplay" \
    ZENTTY_TEST_SCREEN_EXISTS_COMMAND="$fake_screen_probe" \
    ZENTTY_FAKE_BETTERDISPLAY_LOG="$betterdisplay_log" \
    ZENTTY_FAKE_DISPLAY_STATE="$display_state" \
    ZENTTY_FAKE_XCODEBUILD_LOG="$xcodebuild_log" \
    "$repo_root/scripts/test-on-virtual-display" -only-testing:ZenttyLogicTests \
    > "$tmp_dir/harness.$1.out" 2> "$tmp_dir/harness.$1.err"
}

run_http_harness() {
  PATH="$bin_dir:$PATH" \
    ZDOTDIR="$zdot_dir" \
    ZENTTY_TEST_DISPLAY_PROVIDER=betterdisplay \
    ZENTTY_BETTERDISPLAY_HTTP_BASE="http://example.test" \
    ZENTTY_TEST_SCREEN_EXISTS_COMMAND="$fake_screen_probe" \
    ZENTTY_FAKE_CURL_LOG="$curl_log" \
    ZENTTY_FAKE_DISPLAY_STATE="$display_state" \
    ZENTTY_FAKE_XCODEBUILD_LOG="$xcodebuild_log" \
    "$repo_root/scripts/test-on-virtual-display" -only-testing:ZenttyLogicTests \
    > "$tmp_dir/harness.http.out" 2> "$tmp_dir/harness.http.err"
}

run_http_404_harness() {
  PATH="$bin_dir:$PATH" \
    ZDOTDIR="$zdot_dir" \
    ZENTTY_TEST_DISPLAY_PROVIDER=betterdisplay \
    ZENTTY_BETTERDISPLAY_HTTP_BASE="http://example.test" \
    ZENTTY_TEST_SCREEN_EXISTS_COMMAND="$fake_screen_probe" \
    ZENTTY_FAKE_CURL_LOG="$curl_log" \
    ZENTTY_FAKE_CURL_CREATE_STATUS=404 \
    ZENTTY_FAKE_BETTERDISPLAY_LOG="$betterdisplay_log" \
    ZENTTY_FAKE_DISPLAY_STATE="$display_state" \
    ZENTTY_FAKE_XCODEBUILD_LOG="$xcodebuild_log" \
    "$repo_root/scripts/test-on-virtual-display" -only-testing:ZenttyLogicTests \
    > "$tmp_dir/harness.http-404.out" 2> "$tmp_dir/harness.http-404.err"
}

run_harness one &
pid_one=$!
run_harness two &
pid_two=$!

wait "$pid_one"
wait "$pid_two"

create_count="$(grep -c '^create ' "$betterdisplay_log" 2>/dev/null || true)"
if [[ "$create_count" != "1" ]]; then
  print -u2 "expected exactly one BetterDisplay create, got $create_count"
  print -u2 -- "--- BetterDisplay log ---"
  cat "$betterdisplay_log" >&2
  exit 1
fi

discard_count="$(grep -c '^discard ' "$betterdisplay_log" 2>/dev/null || true)"
if [[ "$discard_count" != "1" ]]; then
  print -u2 "expected the last harness run to discard the shared virtual display once, got $discard_count discard calls"
  cat "$betterdisplay_log" >&2
  exit 1
fi

xcodebuild_count="$(wc -l < "$xcodebuild_log" | tr -d '[:space:]')"
if [[ "$xcodebuild_count" != "2" ]]; then
  print -u2 "expected both harness runs to invoke xcodebuild, got $xcodebuild_count"
  cat "$xcodebuild_log" >&2
  exit 1
fi

: > "$xcodebuild_log"
: > "$curl_log"
rm -f "$display_state"

if ! run_http_harness; then
  print -u2 "HTTP fallback harness run failed"
  print -u2 -- "--- stdout ---"
  cat "$tmp_dir/harness.http.out" >&2
  print -u2 -- "--- stderr ---"
  cat "$tmp_dir/harness.http.err" >&2
  print -u2 -- "--- curl log ---"
  cat "$curl_log" >&2 2>/dev/null || true
  exit 1
fi

help_count="$(grep -c '/help' "$curl_log" 2>/dev/null || true)"
if [[ "$help_count" != "1" ]]; then
  print -u2 "expected BetterDisplay HTTP fallback to probe /help once, got $help_count"
  cat "$curl_log" >&2
  exit 1
fi

if ! grep -q '/create' "$curl_log"; then
  print -u2 "expected BetterDisplay HTTP fallback to create the virtual display"
  cat "$curl_log" >&2
  exit 1
fi

if ! grep -q -- '--data-urlencode type=VirtualScreen' "$curl_log"; then
  print -u2 "expected BetterDisplay HTTP fallback to use current virtual screen parameters"
  cat "$curl_log" >&2
  exit 1
fi

http_xcodebuild_count="$(wc -l < "$xcodebuild_log" | tr -d '[:space:]')"
if [[ "$http_xcodebuild_count" != "1" ]]; then
  print -u2 "expected HTTP fallback harness run to invoke xcodebuild once, got $http_xcodebuild_count"
  cat "$xcodebuild_log" >&2
  exit 1
fi

: > "$xcodebuild_log"
: > "$curl_log"
: > "$betterdisplay_log"
rm -f "$display_state"

if ! run_http_404_harness; then
  print -u2 "HTTP 404 fallback harness run failed"
  print -u2 -- "--- stdout ---"
  cat "$tmp_dir/harness.http-404.out" >&2
  print -u2 -- "--- stderr ---"
  cat "$tmp_dir/harness.http-404.err" >&2
  print -u2 -- "--- curl log ---"
  cat "$curl_log" >&2 2>/dev/null || true
  print -u2 -- "--- BetterDisplay log ---"
  cat "$betterdisplay_log" >&2 2>/dev/null || true
  exit 1
fi

if ! grep -q '/create' "$curl_log"; then
  print -u2 "expected HTTP 404 fallback harness run to attempt HTTP create first"
  cat "$curl_log" >&2
  exit 1
fi

if ! grep -q '^create ' "$betterdisplay_log"; then
  print -u2 "expected HTTP 404 fallback harness run to recover with BetterDisplay command transport"
  cat "$betterdisplay_log" >&2
  exit 1
fi

http_404_xcodebuild_count="$(wc -l < "$xcodebuild_log" | tr -d '[:space:]')"
if [[ "$http_404_xcodebuild_count" != "1" ]]; then
  print -u2 "expected HTTP 404 fallback harness run to invoke xcodebuild once, got $http_404_xcodebuild_count"
  cat "$xcodebuild_log" >&2
  exit 1
fi
