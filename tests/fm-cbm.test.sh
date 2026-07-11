#!/usr/bin/env bash
# Behavior tests for optional codebase-memory-mcp integration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-cbm-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
INDEX="$ROOT/bin/fm-cbm-index.sh"

# --- library unit behavior ---

test_lib_disabled_when_forced_off() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/config" "$dir/bin"
  cat > "$dir/config/cbm.env" <<'EOF'
FM_CBM_ENABLED=0
EOF
  # even with a fake binary on PATH, force-off wins
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  (
    # shellcheck disable=SC2030,SC2031
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    if fm_cbm_enabled; then
      fail "CBM should be disabled when FM_CBM_ENABLED=0"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-lib: FM_CBM_ENABLED=0 disables CBM even if binary exists"
}

test_lib_auto_on_with_binary() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/bin" "$dir/config"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    unset FM_CBM_ENABLED FM_CBM_BIN
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_enabled || fail "auto mode should enable when binary is on PATH"
    prefix=$(fm_cbm_launch_env_prefix) || fail "launch prefix should succeed"
    printf '%s' "$prefix" | grep -q 'CBM_CACHE_DIR=' || fail "prefix missing CBM_CACHE_DIR"
    printf '%s' "$prefix" | grep -q 'CBM_MEM_BUDGET_MB=' || fail "prefix missing mem budget"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: auto enables with binary and builds launch prefix"
}

test_lib_project_eligibility_defaults() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/config"
  (
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_project_eligible "/tmp/.openclaw" || fail ".openclaw should be eligible by default"
    fm_cbm_project_eligible "/tmp/firstmate" || fail "firstmate should be eligible by default"
    if fm_cbm_project_eligible "/tmp/random-app"; then
      fail "random app should not be eligible by default"
    fi
    fm_cbm_project_eligible "/x/workspace/projects/active/JT-Control-Room" || fail "JT-Control-Room path should match"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: default project allowlist"
}

test_lib_project_eligibility_file() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/config"
  printf '%s\n' 'only-this' > "$dir/config/cbm-projects"
  (
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_project_eligible "/tmp/only-this" || fail "allowlisted name should match"
    if fm_cbm_project_eligible "/tmp/.openclaw"; then
      fail "default allowlist must not apply when file exists"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-lib: config/cbm-projects overrides defaults"
}

test_lib_append_brief_policy() {
  local dir brief
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/bin" "$dir/config" "$dir/data/t1"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  brief="$dir/data/t1/brief.md"
  printf '%s\n' '# Task' 'do things' > "$brief"
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    unset FM_CBM_ENABLED
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_append_brief_policy "$brief" "/repo/.openclaw" scout
    grep -q 'firstmate:cbm-orientation:start' "$brief" || fail "brief missing CBM marker"
    grep -q 'Optional code orientation' "$brief" || fail "brief missing CBM section"
    # idempotent
    fm_cbm_append_brief_policy "$brief" "/repo/.openclaw" scout
    count=$(grep -c 'firstmate:cbm-orientation:start' "$brief" || true)
    [ "$count" = 1 ] || fail "brief policy should append once, got $count"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: append brief policy is idempotent for eligible projects"
}

test_lib_append_skips_ineligible() {
  local dir brief
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/bin" "$dir/config" "$dir/data/t1"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  brief="$dir/data/t1/brief.md"
  printf '%s\n' '# Task' > "$brief"
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_append_brief_policy "$brief" "/repo/unrelated" scout
    if grep -q 'firstmate:cbm-orientation:start' "$brief"; then
      fail "ineligible project must not get CBM brief block"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-lib: skips brief policy for ineligible projects"
}

test_spawn_sources_cbm_and_exports() {
  # Structural contract: spawn must source cbm lib, append policy, and export CBM env.
  grep -F 'fm-cbm-lib.sh' "$SPAWN" >/dev/null \
    || fail "fm-spawn must source fm-cbm-lib.sh"
  grep -F 'fm_cbm_append_brief_policy' "$SPAWN" >/dev/null \
    || fail "fm-spawn must call fm_cbm_append_brief_policy"
  grep -F 'fm_cbm_launch_env_prefix' "$SPAWN" >/dev/null \
    || fail "fm-spawn must use fm_cbm_launch_env_prefix"
  grep -F 'export CBM_CACHE_DIR=' "$SPAWN" >/dev/null \
    || fail "fm-spawn must export CBM_CACHE_DIR into the pane"
  pass "fm-spawn: CBM integration contract lines present"
}

test_index_helper_exists_and_help() {
  [ -x "$INDEX" ] || fail "fm-cbm-index.sh must be executable"
  out=$("$INDEX" --help 2>&1 || true)
  printf '%s' "$out" | grep -q 'status|list|index' \
    || fail "fm-cbm-index help should list commands"
  pass "fm-cbm-index.sh: help works"
}

test_lib_disabled_when_forced_off
test_lib_auto_on_with_binary
test_lib_project_eligibility_defaults
test_lib_project_eligibility_file
test_lib_append_brief_policy
test_lib_append_skips_ineligible
test_spawn_sources_cbm_and_exports
test_index_helper_exists_and_help
