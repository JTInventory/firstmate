#!/usr/bin/env bash
# Behavior tests for the Understand Anything orientation helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNDERSTAND="$ROOT/bin/fm-understand-anything.sh"
TMP_ROOT=$(fm_test_tmproot fm-understand-anything)

test_stale_dashboard_pid_does_not_report_running() {
  local dir fakebin out rc pid_file url_file evidence_dir evidence_count
  dir="$TMP_ROOT/stale-pid"
  fakebin=$(fm_fakebin "$dir")
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  evidence_dir="$dir/evidence"
  mkdir -p "$evidence_dir"
  printf '10\n' > "$pid_file"
  printf 'http://127.0.0.1:5174/?token=secret-token\n' > "$url_file"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-p" ] && [ "$2" = "10" ] && [ "$3" = "-o" ] && [ "$4" = "command=" ]; then
  printf '%s\n' 'kworker'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/ps"

  set +e
  out=$(PATH="$fakebin:$PATH" "$UNDERSTAND" dashboard-status \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    --evidence-dir "$evidence_dir" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "stale dashboard pid status"
  assert_contains "$out" "dashboard_status=stale" "stale pid should report stale"
  assert_contains "$out" "stale_pid=10" "stale pid should be surfaced"
  assert_contains "$out" "stale_process=kworker" "unrelated process should be surfaced as evidence"
  assert_not_contains "$out" "dashboard_status=running" "stale pid must not report running"
  assert_not_contains "$out" "secret-token" "status output must not print raw dashboard token"
  assert_contains "$out" "token=<redacted>" "status output should redact dashboard token"
  evidence_count=$(find "$evidence_dir" -type f | wc -l | tr -d ' ')
  [ "$evidence_count" -ge 1 ] || fail "stale pid evidence was not preserved"
  pass "understand dashboard status fails closed on reused stale pid"
}

test_dashboard_status_accepts_pid_only_when_cwd_matches_dashboard_dir() {
  local dir dashboard_dir pid_file url_file identity_file out rc pid identity
  dir="$TMP_ROOT/running-cwd"
  dashboard_dir="$dir/dashboard"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  identity_file="$pid_file.identity"
  mkdir -p "$dashboard_dir"
  ( cd "$dashboard_dir" && sleep 30 ) &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  printf 'http://127.0.0.1:5174/?token=live-token\n' > "$url_file"
  identity=$(ps -p "$pid" -o lstart= -o command= | head -n 1)
  printf '%s\n' "$identity" > "$identity_file"

  set +e
  out=$("$UNDERSTAND" dashboard-status \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    --dashboard-dir "$dashboard_dir" 2>&1)
  rc=$?
  set -e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 0 "$rc" "running dashboard pid with matching cwd"
  assert_contains "$out" "dashboard_status=running" "matching dashboard cwd should report running"
  assert_contains "$out" "pid=$pid" "running pid should be surfaced"
  assert_contains "$out" "token=<redacted>" "running status should redact tokenized URL"
  assert_not_contains "$out" "live-token" "running status must not print raw token"
  pass "understand dashboard status verifies pid cwd before reporting running"
}

test_dashboard_status_accepts_custom_identity_file() {
  local dir dashboard_dir pid_file url_file identity_file out rc pid identity
  dir="$TMP_ROOT/running-custom-identity"
  dashboard_dir="$dir/dashboard"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  identity_file="$dir/custom/dashboard.identity"
  mkdir -p "$dashboard_dir" "$(dirname "$identity_file")"
  ( cd "$dashboard_dir" && sleep 30 ) &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  printf 'http://127.0.0.1:5174/?token=custom-identity-token\n' > "$url_file"
  identity=$(ps -p "$pid" -o lstart= -o command= | head -n 1)
  printf '%s\n' "$identity" > "$identity_file"

  set +e
  out=$("$UNDERSTAND" dashboard-status \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    --identity-file "$identity_file" \
    --dashboard-dir "$dashboard_dir" 2>&1)
  rc=$?
  set -e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 0 "$rc" "running dashboard pid with custom identity file"
  assert_contains "$out" "dashboard_status=running" "custom identity file should be honored"
  assert_contains "$out" "pid=$pid" "running pid should be surfaced"
  assert_not_contains "$out" "custom-identity-token" "status must redact saved token"
  pass "understand dashboard status honors custom identity file"
}

test_dashboard_status_rejects_matching_cwd_without_identity() {
  local dir dashboard_dir pid_file url_file out rc pid
  dir="$TMP_ROOT/reused-cwd-no-identity"
  dashboard_dir="$dir/dashboard"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  mkdir -p "$dashboard_dir"
  ( cd "$dashboard_dir" && sleep 30 ) &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  printf 'http://127.0.0.1:5174/?token=cwd-reuse-token\n' > "$url_file"

  set +e
  out=$("$UNDERSTAND" dashboard-status \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    --dashboard-dir "$dashboard_dir" 2>&1)
  rc=$?
  set -e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 1 "$rc" "matching cwd without identity"
  assert_contains "$out" "dashboard_status=stale" "cwd without identity should fail closed"
  assert_not_contains "$out" "dashboard_status=running" "cwd alone must not report running"
  assert_not_contains "$out" "cwd-reuse-token" "stale status should redact URL token"
  pass "understand dashboard status requires matching start-time process identity"
}

test_dashboard_status_rejects_understand_command_without_dashboard_cwd() {
  local dir fakebin out rc pid_file url_file evidence_dir
  dir="$TMP_ROOT/reused-understand-command"
  fakebin=$(fm_fakebin "$dir")
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  evidence_dir="$dir/evidence"
  mkdir -p "$evidence_dir"
  printf '11\n' > "$pid_file"
  printf 'http://127.0.0.1:5174/?token=reused-token\n' > "$url_file"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-p" ] && [ "$2" = "11" ] && [ "$3" = "-o" ] && [ "$4" = "command=" ]; then
  printf '%s\n' '/tmp/not-the-dashboard/understand-helper --idle'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/ps"

  set +e
  out=$(PATH="$fakebin:$PATH" "$UNDERSTAND" dashboard-status \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    --evidence-dir "$evidence_dir" \
    --dashboard-dir "$dir/real-dashboard" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "reused understand process without dashboard cwd"
  assert_contains "$out" "dashboard_status=stale" "understand-looking command without cwd proof should be stale"
  assert_not_contains "$out" "dashboard_status=running" "command name alone must not report running"
  assert_not_contains "$out" "reused-token" "stale status must redact token"
  pass "understand dashboard status rejects command-name fallback without cwd proof"
}

test_dashboard_start_uses_writable_cache_env_and_redacts_tokens() {
  local dir cache env_capture fake out rc log_file
  dir="$TMP_ROOT/start-env"
  cache="$dir/cache"
  env_capture="$dir/env.txt"
  log_file="$dir/dashboard.log"
  fake="$dir/fake-dashboard"
  mkdir -p "$dir"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
{
  printf 'TMPDIR=%s\n' "$TMPDIR"
  printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME"
  printf 'npm_config_cache=%s\n' "$npm_config_cache"
  printf 'VITE_CACHE_DIR=%s\n' "$VITE_CACHE_DIR"
  printf 'VITE_TEMP_DIR=%s\n' "$VITE_TEMP_DIR"
} > "$FM_TEST_ENV_CAPTURE"
printf '%s\n' 'Dashboard URL: http://127.0.0.1:5174/?token=secret-token'
SH
  chmod +x "$fake"

  set +e
  out=$(FM_TEST_ENV_CAPTURE="$env_capture" "$UNDERSTAND" dashboard-start \
    --foreground \
    --cache-dir "$cache" \
    --log-file "$log_file" \
    -- "$fake" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dashboard start foreground"
  assert_contains "$out" "dashboard_start=foreground" "foreground start should be reported"
  assert_contains "$out" "token=<redacted>" "dashboard start output should redact token"
  assert_not_contains "$out" "secret-token" "dashboard start must not print raw token"
  assert_grep "TMPDIR=$cache/tmp" "$env_capture" "TMPDIR should use writable cache root"
  assert_grep "XDG_CACHE_HOME=$cache/xdg-cache" "$env_capture" "XDG cache should use writable cache root"
  assert_grep "npm_config_cache=$cache/npm-cache" "$env_capture" "npm cache should use writable cache root"
  assert_grep "VITE_CACHE_DIR=$cache/vite-cache" "$env_capture" "Vite cache should use writable cache root"
  assert_grep "VITE_TEMP_DIR=$cache/vite-temp" "$env_capture" "Vite temp should use writable cache root"
  assert_no_grep "/root/.understand-anything" "$env_capture" "cache env must not point at plugin install root"
  pass "understand dashboard start uses writable cache env and redacts tokenized URLs"
}

test_default_dashboard_start_uses_generated_vite_config_cache_dir() {
  local dir dashboard_dir cache fakebin args_file out rc config_file
  dir="$TMP_ROOT/default-vite-cache"
  dashboard_dir="$dir/dashboard"
  cache="$dir/cache"
  fakebin=$(fm_fakebin "$dir")
  args_file="$dir/npx-args.txt"
  mkdir -p "$dashboard_dir"
  printf 'export default { server: { host: "127.0.0.1" } };\n' > "$dashboard_dir/vite.config.js"
  cat > "$fakebin/npx" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$args_file"
printf '%s\\n' 'Dashboard URL: http://127.0.0.1:5174/?token=default-token'
SH
  chmod +x "$fakebin/npx"

  set +e
  out=$(PATH="$fakebin:$PATH" "$UNDERSTAND" dashboard-start \
    --foreground \
    --dashboard-dir "$dashboard_dir" \
    --cache-dir "$cache" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "default dashboard start"
  config_file="$cache/vite.config.mjs"
  assert_grep "--config $config_file" "$args_file" "default start should pass generated Vite config"
  assert_grep "\"$cache/vite-cache\"" "$config_file" "generated Vite config should set cacheDir"
  assert_no_grep "from 'vite'" "$config_file" "generated Vite config should not import bare vite from cache"
  assert_not_contains "$out" "default-token" "default start must not print raw token"
  pass "understand default dashboard start sets real Vite cacheDir outside plugin root"
}

test_background_dashboard_start_saves_url_file_without_printing_token() {
  local dir dashboard_dir fake log_file pid_file url_file out rc pid status
  dir="$TMP_ROOT/background-url"
  dashboard_dir="$dir/dashboard"
  fake="$dir/fake-background-dashboard"
  log_file="$dir/dashboard.log"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  mkdir -p "$dashboard_dir"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Dashboard URL: http://127.0.0.1:5174/?token=background-token'
sleep 30
SH
  chmod +x "$fake"

  set +e
  out=$("$UNDERSTAND" dashboard-start \
    --dashboard-dir "$dashboard_dir" \
    --log-file "$log_file" \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    -- "$fake" 2>&1)
  rc=$?
  set -e
  pid=$(cat "$pid_file")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 0 "$rc" "background dashboard start"
  assert_present "$url_file" "background start should save dashboard URL file"
  assert_grep "background-token" "$url_file" "URL file keeps the usable tokenized dashboard URL"
  assert_contains "$out" "dashboard_url=http://127.0.0.1:5174/?token=<redacted>" "background start should report redacted URL"
  assert_not_contains "$out" "background-token" "background start must not print raw token"
  set +e
  status=$("$UNDERSTAND" dashboard-status \
    --dashboard-dir "$dashboard_dir" \
    --pid-file "$pid_file" \
    --url-file "$url_file" 2>&1)
  set -e
  assert_not_contains "$status" "background-token" "status must redact saved tokenized URL"
  pass "understand background dashboard start saves URL file without token leakage"
}

test_background_dashboard_start_fails_without_current_url() {
  local dir dashboard_dir fake log_file pid_file url_file out rc
  dir="$TMP_ROOT/background-no-url"
  dashboard_dir="$dir/dashboard"
  fake="$dir/fake-no-url-dashboard"
  log_file="$dir/dashboard.log"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  mkdir -p "$dashboard_dir"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'startup failed before token'
exit 3
SH
  chmod +x "$fake"

  set +e
  out=$(FM_UNDERSTAND_DASHBOARD_URL_WAIT_SECONDS=1 "$UNDERSTAND" dashboard-start \
    --dashboard-dir "$dashboard_dir" \
    --log-file "$log_file" \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    -- "$fake" 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "background start without current url"
  assert_contains "$out" "dashboard_start=failed" "missing URL should fail background start"
  assert_not_contains "$out" "dashboard_start=background" "failed start must not report background success"
  assert_contains "$out" "reason=dashboard_url_not_confirmed" "failure should name URL confirmation"
  assert_absent "$pid_file" "failed background start should not leave pid file"
  assert_absent "$url_file" "failed background start should not leave URL file"
  pass "understand background dashboard start fails if no current URL is confirmed"
}

test_background_dashboard_start_kills_child_without_current_url() {
  local dir dashboard_dir fake log_file pid_file url_file out rc pid
  dir="$TMP_ROOT/background-no-url-live-child"
  dashboard_dir="$dir/dashboard"
  fake="$dir/fake-live-no-url-dashboard"
  log_file="$dir/dashboard.log"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  mkdir -p "$dashboard_dir"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'dashboard started but no token yet'
sleep 30
SH
  chmod +x "$fake"

  set +e
  out=$(FM_UNDERSTAND_DASHBOARD_URL_WAIT_SECONDS=1 "$UNDERSTAND" dashboard-start \
    --dashboard-dir "$dashboard_dir" \
    --log-file "$log_file" \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    -- "$fake" 2>&1)
  rc=$?
  set -e
  pid=$(printf '%s\n' "$out" | sed -n 's/^pid=//p' | head -n 1)

  expect_code 1 "$rc" "live child without current url"
  assert_contains "$out" "dashboard_start=failed" "unconfirmed live child should fail"
  assert_not_contains "$out" "dashboard_start=background" "unconfirmed child must not report background success"
  [ -n "$pid" ] || fail "failed start should still report the launched pid"
  ! kill -0 "$pid" 2>/dev/null || fail "unconfirmed dashboard child was left running"
  assert_absent "$pid_file" "unconfirmed child should not leave pid file"
  pass "understand background dashboard start kills unconfirmed child"
}

test_background_dashboard_start_creates_identity_parent() {
  local dir dashboard_dir fake log_file pid_file url_file identity_file out rc pid
  dir="$TMP_ROOT/background-identity-parent"
  dashboard_dir="$dir/dashboard"
  fake="$dir/fake-identity-parent-dashboard"
  log_file="$dir/dashboard.log"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  identity_file="$dir/missing/identity/dashboard.identity"
  mkdir -p "$dashboard_dir"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Dashboard URL: http://127.0.0.1:5174/?token=identity-token'
sleep 30
SH
  chmod +x "$fake"

  set +e
  out=$("$UNDERSTAND" dashboard-start \
    --dashboard-dir "$dashboard_dir" \
    --log-file "$log_file" \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    --identity-file "$identity_file" \
    -- "$fake" 2>&1)
  rc=$?
  set -e
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  expect_code 0 "$rc" "background start with nested identity file"
  assert_present "$identity_file" "dashboard start should create identity file parent"
  assert_contains "$out" "token=<redacted>" "identity parent start should redact URL"
  assert_not_contains "$out" "identity-token" "identity token should not print"
  pass "understand background dashboard start creates identity file parent"
}

test_background_dashboard_start_replaces_stale_url_file() {
  local dir dashboard_dir fake log_file pid_file url_file out rc pid
  dir="$TMP_ROOT/background-replaces-url"
  dashboard_dir="$dir/dashboard"
  fake="$dir/fake-replace-dashboard"
  log_file="$dir/dashboard.log"
  pid_file="$dir/dashboard.pid"
  url_file="$dir/dashboard.url"
  mkdir -p "$dashboard_dir"
  printf 'http://127.0.0.1:5173/?token=old-token\n' > "$url_file"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Dashboard URL: http://127.0.0.1:5174/?token=new-token'
sleep 30
SH
  chmod +x "$fake"

  set +e
  out=$("$UNDERSTAND" dashboard-start \
    --dashboard-dir "$dashboard_dir" \
    --log-file "$log_file" \
    --pid-file "$pid_file" \
    --url-file "$url_file" \
    -- "$fake" 2>&1)
  rc=$?
  set -e
  pid=$(cat "$pid_file")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 0 "$rc" "background start replaces old url"
  assert_no_grep "old-token" "$url_file" "old URL token must not survive launch"
  assert_grep "new-token" "$url_file" "current URL token should be saved"
  assert_contains "$out" "token=<redacted>" "reported URL should be redacted"
  assert_not_contains "$out" "new-token" "new raw token should not print"
  assert_not_contains "$out" "old-token" "old raw token should not print"
  pass "understand background dashboard start replaces stale URL evidence"
}

test_openclaw_graph_status_prints_orientation_caveat() {
  local dir metadata out rc
  dir="$TMP_ROOT/graph-status"
  mkdir -p "$dir"
  metadata="$dir/graph-status.json"
  cat > "$metadata" <<'JSON'
{
  "status": "success",
  "nodes": 1941,
  "edges": 2026,
  "analyzedFiles": 95,
  "head": "abc1234",
  "root": "/root/.openclaw"
}
JSON

  set +e
  out=$("$UNDERSTAND" graph-status --metadata-file "$metadata" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "graph status"
  assert_contains "$out" "graph_status=success" "graph status should be printed"
  assert_contains "$out" "nodes=1941" "node count should be printed"
  assert_contains "$out" "edges=2026" "edge count should be printed"
  assert_contains "$out" "analyzed_files=95" "analyzed file count should be printed"
  assert_contains "$out" "graph_head=abc1234" "graph HEAD should be printed"
  assert_contains "$out" "graph_root=/root/.openclaw" "graph root should be printed"
  assert_contains "$out" "orientation_only=true" "OpenClaw graph should be marked orientation-only"
  assert_contains "$out" "workers_must_prove_own_worktree_head=true" "workers should be directed to prove their worktree HEAD"
  pass "understand graph status warns that canonical OpenClaw HEAD is orientation only"
}

test_real_meta_graph_status_infers_root_and_git_commit_hash() {
  local project_dir metadata out rc
  project_dir="$TMP_ROOT/real-meta-project"
  mkdir -p "$project_dir/.understand-anything"
  metadata="$project_dir/.understand-anything/meta.json"
  cat > "$metadata" <<'JSON'
{
  "status": "success",
  "analyzedFiles": 12,
  "gitCommitHash": "def5678"
}
JSON

  set +e
  out=$("$UNDERSTAND" graph-status --metadata-file "$metadata" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "real meta graph status"
  assert_contains "$out" "graph_status=success" "real meta status should be printed"
  assert_contains "$out" "analyzed_files=12" "real meta analyzedFiles should be printed"
  assert_contains "$out" "graph_head=def5678" "real meta gitCommitHash should be printed"
  assert_contains "$out" "graph_root=$project_dir" "real meta root should be inferred from metadata path"
  pass "understand graph status reads real meta.json shape"
}

test_stale_dashboard_pid_does_not_report_running
test_dashboard_status_accepts_pid_only_when_cwd_matches_dashboard_dir
test_dashboard_status_accepts_custom_identity_file
test_dashboard_status_rejects_matching_cwd_without_identity
test_dashboard_status_rejects_understand_command_without_dashboard_cwd
test_dashboard_start_uses_writable_cache_env_and_redacts_tokens
test_default_dashboard_start_uses_generated_vite_config_cache_dir
test_background_dashboard_start_saves_url_file_without_printing_token
test_background_dashboard_start_fails_without_current_url
test_background_dashboard_start_kills_child_without_current_url
test_background_dashboard_start_creates_identity_parent
test_background_dashboard_start_replaces_stale_url_file
test_openclaw_graph_status_prints_orientation_caveat
test_real_meta_graph_status_infers_root_and_git_commit_hash
