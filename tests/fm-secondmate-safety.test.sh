#!/usr/bin/env bash
# tests/fm-secondmate-safety.test.sh - secondmate home safety invariants:
# the path-boundary matrices (seed/spawn/teardown), registry/charter/origin
# validation, treehouse lease handling, no-mistakes initialization of new
# clones, child-worktree protection, and backlog-handoff safety. The happy-path
# operator flow lives in fm-secondmate-lifecycle-e2e.test.sh; this file keeps the
# destructive-invariant coverage that an e2e run cannot deterministically reach.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-safety)

hold_test_task_lock() {
  local state=$1 id=$2 ready=$3
  (
    exec env FM_STATE_OVERRIDE="$state" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      lock=$2
      fm_lock_try_acquire "$lock" || exit 1
      : > "$3"
      cleanup() {
        trap - EXIT TERM INT
        fm_lock_release "$lock"
        exit 0
      }
      trap cleanup EXIT TERM INT
      while :; do sleep 1; done
    ' _ "$ROOT" "$state/.spawn-$id.lock" "$ready"
  ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

start_legacy_lifecycle_process() {
  local home=$1 state=$2 ready=$3 release=$4 dir script
  dir="$TMP_ROOT/legacy-lifecycle-$RANDOM"
  script="$dir/fm-spawn.sh"
  mkdir -p "$dir" "$home" "$state"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_LEGACY_READY"
while [ ! -e "$FM_TEST_LEGACY_RELEASE" ]; do sleep 0.02; done
SH
  chmod +x "$script"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_LEGACY_READY="$ready" FM_TEST_LEGACY_RELEASE="$release" \
    "$script" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

snapshot_tree_identity() {
  local root=$1 path rel
  [ -e "$root" ] || {
    printf 'missing\t%s\n' "$root"
    return
  }
  (
    cd "$root" || exit 1
    find . -print | LC_ALL=C sort | while IFS= read -r rel; do
      path=${rel#./}
      [ -n "$path" ] || path=.
      if [ -L "$path" ]; then
        printf 'link\t%s\t%s\n' "$rel" "$(readlink "$path")"
      elif [ -d "$path" ]; then
        printf 'dir\t%s\n' "$rel"
      elif [ -f "$path" ]; then
        printf 'file\t%s\t' "$rel"
        cksum "$path"
      else
        printf 'other\t%s\n' "$rel"
      fi
    done
  )
}


test_fm_home_parameterization() {
  local brief fakebin home_one home_two out repo wt
  home_one="$TMP_ROOT/home one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "fm-project-mode did not read projects.md from FM_HOME"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "fm-project-mode did not isolate missing registry by home"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-a app >/dev/null || fail "brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-a/brief.md"
  [ -f "$brief" ] || fail "brief was not written under FM_HOME/data"
  grep -F ">> '$home_one/state/task-a.status'" "$brief" >/dev/null || fail "brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-b app --scout >/dev/null || fail "scout brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-b/brief.md"
  grep -F ">> '$home_one/state/task-b.status'" "$brief" >/dev/null || fail "scout brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" FM_SECONDMATE_CHARTER='ops domain' "$ROOT/bin/fm-brief.sh" task-c --secondmate app >/dev/null \
    || fail "secondmate brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-c/brief.md"
  grep -F ">> '$home_one/state/task-c.status'" "$brief" >/dev/null || fail "secondmate brief did not shell-quote FM_HOME state path"

  repo="$TMP_ROOT/pr-check-project"
  wt="$TMP_ROOT/pr-check-wt"
  fm_git_worktree "$repo" "$wt" "fm/task-a"
  fakebin=$(fm_fakebin "$TMP_ROOT/pr-check-fakebin")
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"--json headRefName"*) printf '%s\n' "fm/task-a"; exit 0 ;;
  *"--json headRefOid"*) git -C "$wt" rev-parse HEAD; exit 0 ;;
  *) printf '%s\n' "OPEN"; exit 0 ;;
esac
SH
  chmod +x "$fakebin/gh"
  fm_write_meta "$home_one/state/task-a.meta" \
    "project=x" \
    "worktree=$wt" \
    "kind=ship" \
    "mode=direct-PR"
  PATH="$fakebin:$PATH" FM_HOME="$home_one" FM_GUARD_GRACE=999999 "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/example/repo/pull/1 >/dev/null 2>/dev/null \
    || fail "fm-pr-check failed under FM_HOME"
  [ -f "$home_one/state/task-a.check.sh" ] || fail "pr check was not written under FM_HOME/state"
  [ ! -e "$home_two/state/task-a.check.sh" ] || fail "pr check leaked into another home"
  pass "FM_HOME parameterizes data and state paths"
}

test_lock_status_is_per_home() {
  local home_one home_two out
  home_one="$TMP_ROOT/lock-one"
  home_two="$TMP_ROOT/lock-two"
  mkdir -p "$home_one/state" "$home_two/state"
  printf '999999\n' > "$home_one/state/.lock"
  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-lock.sh" status)
  printf '%s\n' "$out" | grep -F 'lock: stale' >/dev/null || fail "home one lock status did not read its own lock"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = "lock: free" ] || fail "home two lock status was affected by home one"
  pass "fm-lock status is scoped per home"
}

test_seed_allows_overlapping_clones_and_drops_owner() {
  # A project may appear in several secondmates' (non-exclusive) clone lists; the
  # registry never uses the legacy owns: field, and the removed `owner` subcommand
  # stays gone. The full happy seed - charter copied, clones+origins, no-mistakes
  # init, modes preserved - is asserted by fm-secondmate-lifecycle-e2e.
  local home design other
  home="$TMP_ROOT/overlap-main"
  design="$TMP_ROOT/overlap-design"
  other="$TMP_ROOT/overlap-other"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/seed-overlap-alpha.git"
  fm_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/seed-overlap-beta.git"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  FM_HOME="$home" FM_SECONDMATE_CHARTER='feature design for alpha beta' \
    FM_SECONDMATE_SCOPE='feature design for alpha beta' \
    "$ROOT/bin/fm-home-seed.sh" design "$design" alpha beta >/dev/null \
    || fail "initial seed failed"
  assert_grep '- design - feature design for alpha beta' "$home/data/secondmates.md" "design registry line missing"
  assert_grep 'projects: alpha, beta' "$home/data/secondmates.md" "design project clone list missing"
  assert_no_grep 'owns:' "$home/data/secondmates.md" "registry used the legacy owns field"

  # beta is shared with a second secondmate of a different scope (overlap allowed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='issue triage for beta' \
    FM_SECONDMATE_SCOPE='issue triage for beta' \
    "$ROOT/bin/fm-home-seed.sh" other "$other" beta >/dev/null 2>&1 \
    || fail "seed refused overlapping project clones across different scopes"
  assert_grep '- other - issue triage for beta' "$home/data/secondmates.md" "overlapping registry line missing"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation rejected overlapping clones"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" owner alpha >/dev/null 2>&1; then
    fail "owner subcommand still succeeded after routing moved to scopes"
  fi
  pass "seed allows overlapping project clone lists and drops the owns/owner routing"
}

test_home_seed_validate_rejects_duplicate_homes() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/duplicate-home"
  subhome="$TMP_ROOT/duplicate-subhome"
  err="$TMP_ROOT/duplicate-home.err"
  mkdir -p "$home/data" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain mentions home: $TMP_ROOT/ignored-summary-home (home: $subhome_abs; scope: design work mentions home: $TMP_ROOT/ignored-scope-home; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $subhome_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two secondmates with the same home"
  fi
  grep -F 'duplicate secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate home assignment"
  pass "home seed validation rejects duplicate home routes"
}

test_home_seed_validate_rejects_duplicate_ids() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/duplicate-id-home"
  first="$TMP_ROOT/duplicate-id-first"
  second="$TMP_ROOT/duplicate-id-second"
  err="$TMP_ROOT/duplicate-id.err"
  mkdir -p "$home/data" "$first" "$second"
  first_abs=$(cd "$first" && pwd -P)
  second_abs=$(cd "$second" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $first_abs; scope: design work; projects: alpha; added 2026-06-22)
- design - design domain (home: $second_abs; scope: design work; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two homes for the same secondmate id"
  fi
  grep -F 'duplicate secondmate id assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate id assignment"
  pass "home seed validation rejects duplicate id routes"
}

test_home_seed_validate_rejects_nested_homes() {
  local home ancestor descendant ancestor_abs descendant_abs err
  home="$TMP_ROOT/nested-home"
  ancestor="$TMP_ROOT/nested-domain-a"
  descendant="$ancestor/domain-b"
  err="$TMP_ROOT/nested-home.err"
  mkdir -p "$home/data" "$ancestor" "$descendant"
  ancestor_abs=$(cd "$ancestor" && pwd -P)
  descendant_abs=$(cd "$descendant" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $ancestor_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $descendant_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted nested secondmate homes"
  fi
  grep -F 'overlapping secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain nested home assignment"
  pass "home seed validation rejects nested home routes"
}

test_home_seed_uses_treehouse_acquired_home() {
  local home acquired acquired_abs fakebin log lease out
  home="$TMP_ROOT/dash-home"
  acquired="$TMP_ROOT/dash-acquired-home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fake")
  log="$TMP_ROOT/dash-fake/tmux.log"
  lease="$TMP_ROOT/dash-fake/lease"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha) \
    || fail "seed failed for a treehouse-acquired home"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$acquired_abs" >/dev/null || fail "seed did not report acquired home"
  grep -F 'treehouse get --lease --lease-holder dash' "$log" >/dev/null || fail "seed did not durably lease a home under the secondmate id"
  [ -f "$lease" ] || fail "seed did not record a treehouse lease"
  [ "$(cat "$lease")" = dash ] || fail "seed did not set the lease holder to the secondmate id"
  [ -f "$acquired/.fm-secondmate-home" ] || fail "seed did not mark acquired home"
  [ "$(cat "$acquired/.fm-secondmate-home")" = dash ] || fail "seed wrote wrong acquired-home marker"
  [ -d "$acquired/projects/alpha/.git" ] || fail "seed did not clone project into acquired home"
  grep -F "home: $acquired_abs" "$home/data/secondmates.md" >/dev/null || fail "registry did not record acquired home"
  pass "home seeding durably leases treehouse-acquired dash homes under the secondmate id"
}

test_home_seed_returns_treehouse_acquired_home_on_assignment_failure() {
  local home acquired acquired_abs fakebin log err
  home="$TMP_ROOT/dash-fail-home"
  acquired="$TMP_ROOT/dash-fail-acquired-home"
  err="$TMP_ROOT/dash-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fail-fake")
  log="$TMP_ROOT/dash-fail-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another secondmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain acquired marked-home rejection"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed acquired seed did not return the home through treehouse"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- dash ' "$home/data/secondmates.md" >/dev/null; then
    fail "failed acquired seed left a registry route"
  fi
  pass "home seeding returns rejected acquired homes through treehouse"
}

test_home_seed_warns_when_acquired_home_return_fails() {
  local home acquired acquired_abs fakebin log err lease
  home="$TMP_ROOT/dash-return-fail-home"
  acquired="$TMP_ROOT/dash-return-fail-acquired-home"
  err="$TMP_ROOT/dash-return-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-return-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-return-fail-fake")
  log="$TMP_ROOT/dash-return-fail-fake/tmux.log"
  lease="$TMP_ROOT/dash-return-fail-fake/lease"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home after return failure setup"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not report original acquired-home rejection"
  grep -F "warning: failed to return treehouse-acquired home $acquired_abs during seed rollback" "$err" >/dev/null \
    || fail "seed rollback did not warn when treehouse return failed"
  [ -f "$lease" ] || fail "failed rollback return did not preserve lease evidence"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed rollback did not attempt to return the acquired home"
  pass "home seed rollback warns when treehouse-acquired return fails"
}

test_home_seed_does_not_return_unsafe_acquired_home() {
  local home descendant fakebin log err
  home="$TMP_ROOT/dash-active-home"
  descendant="$home/data/dash-descendant-home"
  err="$TMP_ROOT/dash-active.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-active-fake")
  log="$TMP_ROOT/dash-active-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home matching the active firstmate home"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active home through treehouse"
  [ -d "$home/projects/alpha" ] || fail "unsafe acquired-home rollback removed the active home"

  : > "$log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$descendant" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home inside the active firstmate home"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active descendant acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active descendant through treehouse"
  [ -d "$descendant" ] || fail "unsafe acquired-home rollback removed the active descendant"
  pass "home seeding leaves unsafe acquired active homes untouched"
}

test_home_seed_rolls_back_failed_clone() {
  local home subhome err missing_remote
  home="$TMP_ROOT/rollback-home"
  subhome="$TMP_ROOT/rollback-subhome"
  err="$TMP_ROOT/rollback-home.err"
  missing_remote="$TMP_ROOT/remotes/missing-beta.git"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/rollback-alpha.git"
  git -C "$home/projects/beta" remote add origin "file://$missing_remote"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='rollback scope' FM_SECONDMATE_SCOPE='rollback scope' \
    "$ROOT/bin/fm-home-seed.sh" rollback "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though the second project clone failed"
  fi
  grep -F 'does not appear to be a git repository' "$err" >/dev/null \
    || grep -F 'repository' "$err" >/dev/null \
    || fail "seed failure did not include the clone error"
  [ ! -e "$subhome" ] || fail "failed seed left the newly created secondmate home behind"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "failed seed left a subhome marker"
  [ ! -e "$subhome/projects/alpha" ] || fail "failed seed left a previously cloned project"
  [ ! -e "$home/data/rollback/brief.md" ] || fail "failed seed left a generated charter brief"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- rollback ' "$home/data/secondmates.md" >/dev/null; then
    fail "failed seed left a registry route"
  fi
  pass "home seeding rolls back failed clone attempts without residue"
}

test_home_seed_refuses_missing_filled_charter() {
  local home subhome err
  home="$TMP_ROOT/missing-charter-home"
  subhome="$TMP_ROOT/missing-charter-subhome"
  err="$TMP_ROOT/missing-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/missing-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a direct seed without a filled charter"
  fi
  grep -F 'no filled secondmate charter brief' "$err" >/dev/null \
    || fail "seed did not explain missing filled charter refusal"
  [ ! -e "$subhome" ] || fail "missing charter seed left a generated subhome"
  [ ! -e "$home/data/design/brief.md" ] || fail "missing charter seed generated a placeholder charter"
  pass "home seeding refuses direct seed without filled charter text"
}

test_home_seed_refuses_placeholder_charter() {
  local home subhome err
  home="$TMP_ROOT/placeholder-charter-home"
  subhome="$TMP_ROOT/placeholder-charter-subhome"
  err="$TMP_ROOT/placeholder-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/placeholder-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --secondmate alpha >/dev/null \
    || fail "placeholder charter scaffold failed"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an unfilled placeholder charter"
  fi
  grep -F 'still contains {TASK}' "$err" >/dev/null \
    || fail "seed did not explain placeholder charter refusal"
  [ ! -e "$subhome" ] || fail "placeholder charter seed left a generated subhome"
  [ ! -e "$subhome/projects/alpha" ] || fail "placeholder charter seed cloned before refusing"
  pass "home seeding refuses unfilled placeholder charters"
}

test_home_seed_refuses_empty_charter_fields() {
  local home subhome err
  home="$TMP_ROOT/empty-charter-home"
  subhome="$TMP_ROOT/empty-charter-subhome"
  err="$TMP_ROOT/empty-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/empty-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='   ' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a whitespace-only charter"
  fi
  grep -F 'empty Charter section' "$err" >/dev/null \
    || fail "seed did not explain empty charter refusal"
  [ ! -e "$subhome" ] || fail "empty charter seed left a generated subhome"

  rm -rf "$home/data/design" "$subhome" "$err"
  FM_SECONDMATE_SCOPE='   ' scaffold_secondmate_charter "$home" design 'filled charter' alpha \
    || fail "empty scope fixture scaffold failed"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an empty routing scope"
  fi
  grep -F 'empty Routing scope section' "$err" >/dev/null \
    || fail "seed did not explain empty routing scope refusal"
  [ ! -e "$subhome" ] || fail "empty routing scope seed left a generated subhome"
  pass "home seeding refuses empty normalized charter fields"
}

test_home_seed_refuses_local_only_project() {
  local home subhome err
  home="$TMP_ROOT/local-only-seed-home"
  subhome="$TMP_ROOT/local-only-seed-subhome"
  err="$TMP_ROOT/local-only-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed a local-only project into a secondmate home"
  fi
  grep -F 'project alpha is local-only; secondmate routes support only no-mistakes and direct-PR projects' "$err" >/dev/null \
    || fail "seed did not explain local-only project rejection"
  [ ! -e "$subhome" ] || fail "seed created a subhome before rejecting a local-only project"
  pass "home seeding refuses local-only projects"
}

test_home_seed_refuses_registry_delimiter_home() {
  local home subhome err
  home="$TMP_ROOT/delimiter-home"
  subhome="$TMP_ROOT/delimiter)subhome"
  err="$TMP_ROOT/delimiter-home.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/delimiter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='delimiter charter' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home path with registry delimiters"
  fi
  grep -F 'secondmate home path contains registry delimiters' "$err" >/dev/null \
    || fail "seed did not explain delimiter home refusal"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "delimiter home seed wrote a marker"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- design ' "$home/data/secondmates.md" >/dev/null; then
    fail "delimiter home seed wrote a registry route"
  fi
  pass "home seeding refuses registry delimiter home paths"
}

test_home_seed_refuses_active_home_and_root() {
  local home err active_ancestor active_descendant root_clone root_descendant root_ancestor root_inside
  active_ancestor="$TMP_ROOT/active-seed-ancestor"
  home="$active_ancestor/main-home"
  err="$TMP_ROOT/active-seed.err"
  active_descendant="$home/nested/design-home"
  root_clone="$TMP_ROOT/active-seed-root"
  root_descendant="$root_clone/tmp/design-home"
  root_ancestor="$TMP_ROOT/active-seed-root-ancestor"
  root_inside="$root_ancestor/nested-root"
  git clone --quiet "$ROOT" "$active_ancestor"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for active-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to reuse active FM_HOME"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$active_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home inside active FM_HOME"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME descendant rejection"
  [ ! -e "$home/nested" ] || fail "seed created a directory inside active FM_HOME before descendant rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$active_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to contain active FM_HOME"
  fi
  grep -F 'secondmate home cannot be an ancestor of the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME ancestor rejection"
  [ ! -f "$active_ancestor/.fm-secondmate-home" ] || fail "seed marked an ancestor of active FM_HOME"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$ROOT" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to reuse FM_ROOT"
  fi
  grep -F 'secondmate home cannot be the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT rejection"

  git clone --quiet "$ROOT" "$root_clone"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_clone" "$ROOT/bin/fm-home-seed.sh" design "$root_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home inside FM_ROOT"
  fi
  grep -F 'secondmate home cannot be inside the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT descendant rejection"
  [ ! -e "$root_clone/tmp" ] || fail "seed created a directory inside FM_ROOT before descendant rejection"

  git clone --quiet "$ROOT" "$root_ancestor"
  git clone --quiet "$ROOT" "$root_inside"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_inside" "$ROOT/bin/fm-home-seed.sh" design "$root_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to contain FM_ROOT"
  fi
  grep -F 'secondmate home cannot be an ancestor of the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT ancestor rejection"
  [ ! -f "$root_ancestor/.fm-secondmate-home" ] || fail "seed marked an ancestor of FM_ROOT"
  pass "home seeding refuses active home and repo root"
}

test_home_seed_refuses_home_marked_for_another_id() {
  local home subhome err
  home="$TMP_ROOT/marked-seed-home"
  subhome="$TMP_ROOT/marked-seed-subhome"
  err="$TMP_ROOT/marked-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/marked-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  printf 'other\n' > "$subhome/.fm-secondmate-home"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for marked-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home marked for another secondmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain marked-home rejection"
  [ "$(cat "$subhome/.fm-secondmate-home")" = "other" ] || fail "seed overwrote another secondmate marker"
  pass "home seeding refuses homes marked for another id"
}

test_home_seed_refuses_home_registered_to_another_id() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/registered-seed-home"
  subhome="$TMP_ROOT/registered-seed-subhome"
  err="$TMP_ROOT/registered-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/registered-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' '- other - other domain (home: '"$subhome_abs"'; scope: other domain; projects: beta; added 2026-06-22)' > "$home/data/secondmates.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for registered-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home registered to another secondmate"
  fi
  grep -F 'already registered to other' "$err" >/dev/null || fail "seed did not explain registered-home rejection"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "seed wrote a marker before rejecting a registered home"
  pass "home seeding refuses homes registered to another id"
}

test_home_seed_refuses_reassigning_existing_id_to_different_home() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/reassign-id-home"
  first="$TMP_ROOT/reassign-id-first"
  second="$TMP_ROOT/reassign-id-second"
  err="$TMP_ROOT/reassign-id.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/reassign-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$first" alpha >/dev/null \
    || fail "initial seed failed for reassigning-id test"
  first_abs=$(cd "$first" && pwd -P)

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$second" alpha >/dev/null 2>"$err"; then
    fail "seed reassigned an existing secondmate id to a different home"
  fi
  grep -F "secondmate id design is already registered to home $first_abs" "$err" >/dev/null \
    || fail "seed did not explain same-id different-home rejection"
  [ ! -e "$second" ] || fail "failed id reassignment created the new subhome"
  [ "$(cat "$first/.fm-secondmate-home")" = design ] || fail "failed id reassignment changed the original marker"
  grep -F "home: $first_abs" "$home/data/secondmates.md" >/dev/null \
    || fail "failed id reassignment did not preserve the original registry route"
  second_abs=$(cd "$(dirname "$second")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$second")")
  grep -F "home: $second_abs" "$home/data/secondmates.md" >/dev/null \
    && fail "failed id reassignment recorded the rejected home"
  pass "home seeding refuses same-id reassignment to a different home"
}

test_home_seed_refuses_home_overlapping_registered_home() {
  local home registered_parent registered_child nested parent err
  home="$TMP_ROOT/overlap-seed-home"
  registered_parent="$TMP_ROOT/overlap-registered-parent"
  registered_child="$TMP_ROOT/overlap-registered-child-parent/child"
  nested="$registered_parent/nested"
  parent="$TMP_ROOT/overlap-registered-child-parent"
  err="$TMP_ROOT/overlap-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/overlap-alpha.git"
  git clone --quiet "$ROOT" "$registered_parent"
  git clone --quiet "$ROOT" "$registered_child"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  cat > "$home/data/secondmates.md" <<EOF
- parent - parent domain (home: $registered_parent; scope: parent domain; projects: beta; added 2026-06-22)
- child - child domain (home: $registered_child; scope: child domain; projects: gamma; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$nested" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home inside a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered ancestor overlap"
  [ ! -e "$nested" ] || fail "seed created a nested home inside a registered home"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$parent" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home containing a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered descendant overlap"
  [ ! -f "$parent/.fm-secondmate-home" ] || fail "seed marked a home containing a registered home"
  pass "home seeding refuses registered home overlaps"
}

test_home_seed_refuses_remote_backed_project_without_origin() {
  local home subhome err
  home="$TMP_ROOT/no-origin-home"
  subhome="$TMP_ROOT/no-origin-subhome"
  err="$TMP_ROOT/no-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for no-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed remote-backed project without origin"
  fi
  grep -F 'project alpha is direct-PR but has no origin remote' "$err" >/dev/null || fail "seed did not explain missing origin for remote-backed project"
  pass "remote-backed subhome seeding requires a source origin"
}

test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin() {
  local home subhome subhome_abs err expected
  home="$TMP_ROOT/wrong-origin-home"
  subhome="$TMP_ROOT/wrong-origin-subhome"
  err="$TMP_ROOT/wrong-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/wrong-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  mkdir -p "$subhome/projects"
  git clone --quiet "$home/projects/alpha" "$subhome/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for wrong-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted existing remote-backed project with wrong origin"
  fi
  expected=$(git -C "$home/projects/alpha" remote get-url origin)
  grep -F "seeded project alpha at $subhome_abs/projects/alpha has origin" "$err" >/dev/null \
    || fail "seed did not identify wrong origin for existing remote-backed project"
  grep -F "expected $expected" "$err" >/dev/null \
    || fail "seed did not report expected origin for existing remote-backed project"
  pass "remote-backed subhome seeding validates existing destination origins"
}

test_home_seed_resolves_relative_source_origins() {
  local home subhome subhome_abs expected out actual
  home="$TMP_ROOT/relative-origin-home"
  subhome="$TMP_ROOT/relative-origin-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$home/remotes"
  fm_git_init_commit "$home/projects/alpha"
  git clone --quiet --bare "$home/projects/alpha" "$home/remotes/relative-alpha.git"
  git -C "$home/projects/alpha" remote add origin ../../remotes/relative-alpha.git
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for relative origin seed test"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha)
  subhome_abs=$(cd "$subhome" && pwd -P)
  expected=$(cd "$home/remotes/relative-alpha.git" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$subhome_abs" >/dev/null || fail "seed did not report relative-origin subhome"
  [ -d "$subhome/projects/alpha/.git" ] || fail "relative source origin was not cloned"
  actual=$(git -C "$subhome/projects/alpha" remote get-url origin)
  [ "$actual" = "$expected" ] || fail "relative source origin was not cloned through the resolved path"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null \
    || fail "relative source origin did not compare equal on reseed"
  pass "home seeding resolves relative source origins against the source project"
}

test_home_seed_skips_initialized_existing_no_mistakes_projects() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-initialized-home"
  subhome="$TMP_ROOT/existing-initialized-subhome"
  err="$TMP_ROOT/existing-initialized.err"
  log="$TMP_ROOT/existing-initialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/existing-alpha.git"
  fm_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/existing-beta.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  git -C "$subhome/projects/alpha" remote add no-mistakes "$TMP_ROOT/no-mistakes-alpha.git"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' '- beta - beta project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-initialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" FM_FAKE_NO_MISTAKES_FAIL_PROJECT=beta \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing init rollback scope' FM_SECONDMATE_SCOPE='existing init rollback scope' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though later no-mistakes initialization failed"
  fi
  grep -F 'failed to initialize no-mistakes for beta' "$err" >/dev/null \
    || fail "seed did not explain later no-mistakes initialization failure"
  grep -F "$subhome/projects/alpha" "$log" >/dev/null \
    && fail "seed ran no-mistakes against an initialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated initialized existing clone with no-mistakes init"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-doctor" ] || fail "seed mutated initialized existing clone with no-mistakes doctor"
  [ ! -e "$subhome/projects/beta" ] || fail "failed seed left a newly cloned project after no-mistakes failure"
  pass "home seeding skips initialized existing no-mistakes clones"
}

test_home_seed_refuses_uninitialized_existing_no_mistakes_project() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-uninitialized-home"
  subhome="$TMP_ROOT/existing-uninitialized-subhome"
  err="$TMP_ROOT/existing-uninitialized.err"
  log="$TMP_ROOT/existing-uninitialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/uninitialized-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-uninitialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing uninitialized scope' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed initialized a preexisting no-mistakes clone"
  fi
  grep -F 'refusing to mutate preexisting clone' "$err" >/dev/null \
    || fail "seed did not explain uninitialized existing no-mistakes clone refusal"
  [ ! -s "$log" ] || fail "seed ran no-mistakes before refusing an uninitialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated uninitialized existing clone"
  pass "home seeding refuses uninitialized existing no-mistakes clones"
}

test_home_seed_refuses_project_destinations_outside_subhome() {
  local home subhome sink err
  home="$TMP_ROOT/symlink-project-home"
  subhome="$TMP_ROOT/symlink-project-subhome"
  sink="$home/data/symlink-projects"
  err="$TMP_ROOT/symlink-project.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$sink"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  rm -rf "$subhome/projects"
  ln -s "$sink" "$subhome/projects"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink destination seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed followed a subhome projects symlink outside the subhome"
  fi
  grep -F 'secondmate projects directory must resolve inside the secondmate home' "$err" >/dev/null \
    || fail "seed did not explain unsafe project destination rejection"
  [ ! -e "$sink/alpha" ] || fail "seed cloned a project through an unsafe projects symlink"
  [ ! -f "$subhome/.fm-secondmate-home" ] || fail "seed marked subhome after unsafe project destination rejection"
  pass "home seeding refuses project destinations outside the subhome"
}

test_home_seed_refuses_operational_dirs_outside_subhome() {
  local home subhome sink err opdir
  home="$TMP_ROOT/symlink-opdir-home"
  err="$TMP_ROOT/symlink-opdir.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-opdir-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink operational dir seed test"

  for opdir in data state config; do
    subhome="$TMP_ROOT/symlink-opdir-subhome-$opdir"
    sink="$home/data/symlink-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$sink"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "secondmate $opdir directory must resolve inside the secondmate home" "$err" >/dev/null \
      || fail "seed did not explain unsafe $opdir directory rejection"
    [ ! -f "$subhome/.fm-secondmate-home" ] || fail "seed marked subhome after unsafe $opdir directory rejection"
  done
  pass "home seeding refuses operational directories outside the subhome"
}

test_home_seed_refuses_symlinked_leaf_files() {
  local home subhome sink err leaf target expected
  home="$TMP_ROOT/symlink-leaf-home"
  err="$TMP_ROOT/symlink-leaf.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-leaf-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink leaf seed test"

  for leaf in data/projects.md data/charter.md .fm-secondmate-home; do
    subhome="$TMP_ROOT/symlink-leaf-subhome-${leaf//\//-}"
    sink="$home/data/symlink-leaf-${leaf//\//-}"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$(dirname "$subhome/$leaf")" "$(dirname "$sink")"
    expected=outside
    if [ "$leaf" = ".fm-secondmate-home" ]; then
      expected=design
    fi
    printf '%s\n' "$expected" > "$sink"
    ln -s "$sink" "$subhome/$leaf"
    if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted symlinked leaf file $leaf"
    fi
    grep -F 'secondmate leaf file must not be a symlink:' "$err" >/dev/null \
      || fail "seed did not explain symlinked leaf refusal for $leaf"
    target=$(cat "$sink")
    [ "$target" = "$expected" ] || fail "seed overwrote outside symlink target for $leaf"
    [ ! -f "$subhome/.fm-secondmate-home" ] || [ "$leaf" = ".fm-secondmate-home" ] || fail "seed marked subhome after symlinked leaf refusal"
  done
  pass "home seeding refuses symlinked leaf files"
}

test_secondmate_spawn_requires_seeded_matching_home() {
  local home subhome wronghome marker_only active_descendant active_ancestor ancestor_active_home fakeroot root_descendant root_ancestor root_inside fakebin log err
  home="$TMP_ROOT/spawn-validate-home"
  subhome="$TMP_ROOT/spawn-validate-subhome"
  wronghome="$TMP_ROOT/spawn-validate-wronghome"
  marker_only="$TMP_ROOT/spawn-validate-marker-only"
  active_descendant="$home/data/spawn-descendant-home"
  active_ancestor="$TMP_ROOT/spawn-active-ancestor"
  ancestor_active_home="$active_ancestor/main-home"
  fakeroot="$TMP_ROOT/spawn-validate-root"
  root_descendant="$fakeroot/tmp/spawn-descendant-home"
  root_ancestor="$TMP_ROOT/spawn-root-ancestor"
  root_inside="$root_ancestor/repo"
  mkdir -p "$home/data" "$home/state" "$subhome/data" "$wronghome/data" "$marker_only/data" "$active_descendant/data" "$root_descendant/data" "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/fm-guard.sh"
  mkdir -p "$ancestor_active_home/data" "$ancestor_active_home/state" "$active_ancestor/data" "$root_ancestor/data" "$root_inside/bin"
  cat > "$root_inside/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root_inside/bin/fm-guard.sh"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-validate-fake")
  log="$TMP_ROOT/spawn-validate-fake/tmux.log"
  err="$TMP_ROOT/spawn-validate.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$subhome" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted an unseeded home"
  fi
  grep -F 'not a seeded secondmate home' "$err" >/dev/null || fail "spawn did not explain missing seed marker"
  # Canonical ordering proof: validation runs before any tmux side-effect. Every rejection
  # reason below shares this one linear pre-launch path, so they each assert only their own
  # refusal message rather than re-proving "no window created before validation" each time.
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before validation"

  printf 'other\n' > "$wronghome/.fm-secondmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$wronghome" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home marked for another secondmate"
  fi
  grep -F 'marked for secondmate other, expected domain' "$err" >/dev/null || fail "spawn did not explain marker mismatch"

  printf 'domain\n' > "$marker_only/.fm-secondmate-home"
  printf 'charter\n' > "$marker_only/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$marker_only" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a marked home missing AGENTS.md"
  fi
  grep -F 'not a firstmate home (missing AGENTS.md)' "$err" >/dev/null || fail "spawn did not explain missing AGENTS.md"

  printf '# Firstmate\n' > "$marker_only/AGENTS.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$marker_only" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a marked home missing bin"
  fi
  grep -F 'not a firstmate home (missing bin/)' "$err" >/dev/null || fail "spawn did not explain missing bin"

  printf 'domain\n' > "$home/.fm-secondmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$home" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted the active home"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$ROOT" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted the firstmate repo root"
  fi
  grep -F 'secondmate home cannot be the firstmate repo' "$err" >/dev/null || fail "spawn did not reject firstmate repo root"

  printf 'domain\n' > "$active_descendant/.fm-secondmate-home"
  printf 'charter\n' > "$active_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$active_descendant" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home inside the active firstmate home"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home descendant"

  printf 'domain\n' > "$active_ancestor/.fm-secondmate-home"
  printf 'charter\n' > "$active_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$ancestor_active_home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$active_ancestor" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home containing the active firstmate home"
  fi
  grep -F 'secondmate home cannot be an ancestor of the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home ancestor"

  printf 'domain\n' > "$root_descendant/.fm-secondmate-home"
  printf 'charter\n' > "$root_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$root_descendant" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home inside the firstmate repo"
  fi
  grep -F 'secondmate home cannot be inside the firstmate repo' "$err" >/dev/null || fail "spawn did not reject repo root descendant"

  printf 'domain\n' > "$root_ancestor/.fm-secondmate-home"
  printf 'charter\n' > "$root_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root_inside" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$root_ancestor" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home containing the firstmate repo"
  fi
  grep -F 'secondmate home cannot be an ancestor of the firstmate repo' "$err" >/dev/null || fail "spawn did not reject repo ancestor"

  pass "secondmate spawn validates homes before launch"
}

test_secondmate_spawn_refuses_operational_dirs_outside_subhome() {
  local home subhome sink fakebin log err opdir
  home="$TMP_ROOT/spawn-opdir-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-opdir-fake")
  log="$TMP_ROOT/spawn-opdir-fake/tmux.log"
  err="$TMP_ROOT/spawn-opdir.err"
  mkdir -p "$home/data" "$home/state"

  for opdir in data state config projects; do
    subhome="$TMP_ROOT/spawn-opdir-subhome-$opdir"
    sink="$home/data/spawn-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    mkdir -p "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects" "$sink"
    printf 'domain\n' > "$subhome/.fm-secondmate-home"
    printf 'charter\n' > "$subhome/data/charter.md"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if [ "$opdir" = data ]; then
      printf 'charter\n' > "$sink/charter.md"
    fi
    : > "$log"
    if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-opdir-fake/pane.txt" \
      "$ROOT/bin/fm-spawn.sh" domain "$subhome" codex --secondmate >/dev/null 2>"$err"; then
      fail "secondmate spawn accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "secondmate $opdir directory must resolve inside the secondmate home" "$err" >/dev/null \
      || fail "spawn did not explain unsafe $opdir directory rejection"
    grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before unsafe $opdir directory validation"
  done
  pass "secondmate spawn refuses operational directories outside the subhome"
}

test_secondmate_spawn_allows_plain_clone_home_without_stamp() {
  local home subhome fakebin log out rc
  home="$TMP_ROOT/plain-clone-spawn-home"
  subhome="$TMP_ROOT/plain-clone-spawn-subhome"
  mkdir -p "$home/data/admission" "$home/state" "$home/config" "$home/projects"
  printf 'brief\n' > "$home/data/admission/brief.md"
  make_firstmate_git_root "$subhome"
  mkdir -p "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects"
  printf 'admission\n' > "$subhome/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/plain-clone-spawn-fake")
  log="$TMP_ROOT/plain-clone-spawn-fake/tmux.log"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/plain-clone-spawn-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" admission "$subhome" codex --secondmate 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "plain-clone secondmate spawn failed"$'\n'"$out"
  [ -f "$home/state/admission.meta" ] || fail "plain-clone secondmate spawn did not publish metadata"
  [ ! -e "$home/state/.spawn-admission.lock" ] \
    || fail "successful plain-clone spawn left its task lock held"
  [ ! -e "$home/state/.locks/spawn-admission.lock" ] \
    || fail "successful plain-clone spawn left its admission lock held"
  if ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$subhome" task >/dev/null 2>&1 ); then
    fail "plain-clone secondmate spawn wrote a pooled-slot stamp"
  fi
  pass "plain-clone secondmate homes launch without pooled-slot ownership stamps"
}

test_fm_send_refuses_bare_window_without_home_meta() {
  # The happy path (a bare fm-<id> resolves the window recorded in THIS home's
  # meta and never a foreign same-named window) is asserted in the lifecycle e2e.
  # Here: with NO meta for the id, send must refuse rather than fall back to a
  # foreign same-named window that list-windows happens to return.
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_fake_tmux "$TMP_ROOT/send-fake")
  log="$TMP_ROOT/send-fake/tmux.log"
  err="$TMP_ROOT/send-fake/send.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-missing" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" fm-missing 'wrong home' >/dev/null 2>"$err"; then
    fail "fm-send sent to a bare firstmate window without home metadata"
  fi
  grep -F "no metadata for fm-missing in $home/state" "$err" >/dev/null \
    || fail "fm-send did not explain missing home metadata"
  grep -F 'send-keys -t other-session:fm-missing' "$log" >/dev/null \
    && fail "fm-send fell back to a foreign same-name window"
  pass "fm-send refuses a bare firstmate window with no metadata in this home"
}

test_secondmate_teardown_retires_empty_home() {
  local home subhome subhome_abs fakebin log lease fmroot agent_pid rc
  home="$TMP_ROOT/teardown-home"
  subhome="$TMP_ROOT/teardown-subhome"
  fmroot="$TMP_ROOT/teardown-fmroot"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-fake")
  log="$TMP_ROOT/teardown-fake/tmux.log"
  lease="$TMP_ROOT/teardown-fake/lease"
  printf 'domain\n' > "$lease"
  ( cd "$subhome" \
    && FM_AGENT_ROLE=secondmate FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$subhome_abs" \
      exec sleep 300 ) >/dev/null 2>&1 &
  agent_pid=$!
  for _ in $(seq 1 50); do
    [ -e "/proc/$agent_pid/cwd" ] && break
    sleep 0.02
  done
  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null
  rc=$?
  set -e
  kill "$agent_pid" 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "teardown treated its live secondmate as a foreign slot occupant"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not release the secondmate home lease via treehouse return"
  [ ! -e "$lease" ] || fail "teardown left the secondmate home lease held after retirement"
  [ ! -d "$subhome" ] || fail "teardown did not remove the retired secondmate home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "teardown did not remove secondmate registry route"
  pass "secondmate teardown retires empty homes and releases routing"
}

test_secondmate_teardown_serializes_against_spawn() {
  local home subhome fakebin log fmroot ready holder err rc
  home="$TMP_ROOT/teardown-lock-home"
  subhome="$TMP_ROOT/teardown-lock-subhome"
  fmroot="$TMP_ROOT/teardown-lock-fmroot"
  ready="$TMP_ROOT/teardown-lock.ready"
  err="$TMP_ROOT/teardown-lock.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-lock-fake")
  log="$TMP_ROOT/teardown-lock-fake/tmux.log"
  holder=$(hold_test_task_lock "$home/state" domain "$ready")
  for _ in $(seq 1 50); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || fail "task-lock holder did not start"
  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-lock-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "teardown raced through an active spawn task lock"
  grep -F 'an older spawn or teardown is still changing' "$err" >/dev/null \
    || fail "teardown legacy task-lock refusal lost its reason"
  grep -F 'kill-window' "$log" >/dev/null \
    && fail "teardown closed the endpoint while spawn held the task lock"
  [ -d "$subhome" ] && [ -e "$home/state/domain.meta" ] \
    || fail "teardown mutated secondmate state while spawn held the task lock"
  pass "secondmate spawn and teardown serialize on one task identity lock"
}

test_secondmate_teardown_blocks_prelock_legacy_spawn() {
  local home subhome fakebin log fmroot ready release holder err rc
  home="$TMP_ROOT/legacy-prelock-home"
  subhome="$TMP_ROOT/legacy-prelock-subhome"
  fmroot="$TMP_ROOT/legacy-prelock-fmroot"
  ready="$TMP_ROOT/legacy-prelock.ready"
  release="$TMP_ROOT/legacy-prelock.release"
  err="$TMP_ROOT/legacy-prelock.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/legacy-prelock-fake")
  log="$TMP_ROOT/legacy-prelock-fake/tmux.log"
  holder=$(start_legacy_lifecycle_process "$home" "$home/state" "$ready" "$release")
  for _ in $(seq 1 50); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || fail "legacy pre-lock process did not start"
  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/legacy-prelock-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"
  rc=$?
  set -e
  touch "$release"
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "teardown crossed a legacy spawn before its task lock"
  grep -F 'older spawn or teardown is still starting' "$err" >/dev/null \
    || fail "legacy pre-lock refusal lost its reason"
  [ ! -s "$log" ] || fail "legacy pre-lock refusal closed an endpoint"
  [ -d "$subhome" ] && [ -e "$home/state/domain.meta" ] \
    || fail "legacy pre-lock refusal mutated lifecycle state"
  pass "secondmate teardown blocks a scoped legacy spawn before task locking"
}

test_secondmate_teardown_quiescence_catches_late_legacy_spawn() {
  local home subhome fakebin log fmroot ready release holder err rc teardown_pid
  home="$TMP_ROOT/legacy-late-home"
  subhome="$TMP_ROOT/legacy-late-subhome"
  fmroot="$TMP_ROOT/legacy-late-fmroot"
  ready="$TMP_ROOT/legacy-late.ready"
  release="$TMP_ROOT/legacy-late.release"
  err="$TMP_ROOT/legacy-late.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/legacy-late-fake")
  log="$TMP_ROOT/legacy-late-fake/tmux.log"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
    FM_LEGACY_LIFECYCLE_QUIESCENCE_PASSES=3 \
    FM_LEGACY_LIFECYCLE_QUIESCENCE_WAIT=0.2 \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/legacy-late-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err" &
  teardown_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$home/state/.locks/spawn-admission.lock" ] && break
    sleep 0.01
  done
  [ -e "$home/state/.locks/spawn-admission.lock" ] \
    || fail "teardown did not establish admission before late-process test"
  sleep 0.05
  holder=$(start_legacy_lifecycle_process "$home" "$home/state" "$ready" "$release")
  for _ in $(seq 1 50); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || fail "late legacy spawn did not start"
  rc=0
  wait "$teardown_pid" || rc=$?
  touch "$release"
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "teardown crossed a legacy spawn that started after admission"
  grep -F 'older spawn or teardown is still starting' "$err" >/dev/null \
    || fail "late legacy spawn refusal lost its reason"
  [ ! -s "$log" ] || fail "late legacy spawn refusal closed an endpoint"
  [ -d "$subhome" ] && [ -e "$home/state/domain.meta" ] \
    || fail "late legacy spawn refusal mutated lifecycle state"
  pass "secondmate teardown requires a stable empty legacy lifecycle interval"
}

test_secondmate_teardown_blocks_child_publication_during_census() {
  local home subhome childhome fakebin log fmroot ready release err spawn_err teardown_pid rc
  home="$TMP_ROOT/teardown-admission-home"
  subhome="$TMP_ROOT/teardown-admission-subhome"
  childhome="$TMP_ROOT/teardown-admission-childhome"
  fmroot="$TMP_ROOT/teardown-admission-fmroot"
  ready="$TMP_ROOT/teardown-admission.ready"
  release="$TMP_ROOT/teardown-admission.release"
  err="$TMP_ROOT/teardown-admission.err"
  spawn_err="$TMP_ROOT/teardown-admission-spawn.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  make_firstmate_git_root "$childhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/data/newchild" \
    "$subhome/config" "$subhome/projects" "$childhome/data" "$childhome/state" \
    "$childhome/config" "$childhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'newchild\n' > "$childhome/.fm-secondmate-home"
  printf 'brief\n' > "$subhome/data/newchild/brief.md"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  fm_write_meta "$subhome/state/blocker.meta" \
    "window=firstmate:fm-blocker" "worktree=" "project=" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=unknown"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-admission-fake")
  log="$TMP_ROOT/teardown-admission-fake/tmux.log"
  cat > "$fakebin/basename" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "${FM_TEST_BLOCK_META:-}" ]; then
  : > "$FM_TEST_ADMISSION_READY"
  while [ ! -e "$FM_TEST_ADMISSION_RELEASE" ]; do sleep 0.02; done
fi
exec /usr/bin/basename "$@"
SH
  chmod +x "$fakebin/basename"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-admission-fake/pane.txt" \
    FM_TEST_BLOCK_META="$subhome/state/blocker.meta" FM_TEST_ADMISSION_READY="$ready" \
    FM_TEST_ADMISSION_RELEASE="$release" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err" &
  teardown_pid=$!
  for _ in $(seq 1 250); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || {
    kill "$teardown_pid" 2>/dev/null || true
    fail "teardown did not reach its locked child census"
  }
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$subhome" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-admission-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" newchild "$childhome" codex --secondmate \
    >/dev/null 2>"$spawn_err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "real child spawn published while teardown held admission"
  [ ! -e "$subhome/state/newchild.meta" ] || fail "blocked real child spawn published metadata"
  grep -F 'teardown is already retiring this firstmate home' "$spawn_err" >/dev/null \
    || fail "real child spawn did not report the admission boundary"
  : > "$release"
  set +e
  wait "$teardown_pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown fixture did not stop at the unsupported child"
  PATH="$fakebin:$PATH" FM_HOME="$subhome" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-admission-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" newchild "$childhome" codex --secondmate \
    >/dev/null 2>"$spawn_err" \
    || fail "real child spawn did not publish after teardown released admission"$'\n'"$(cat "$spawn_err")"
  [ -e "$subhome/state/newchild.meta" ] || fail "real child spawn omitted metadata after admission release"
  pass "real child publication waits for the teardown census boundary to release"
}

# A leased secondmate home sits in the same reusable pool as a task worktree, so
# its lease is gated by the same ownership evidence (bin/fm-slot-owner-lib.sh,
# docs/worker-isolation.md). Here the refusal is outright rather than a retired
# lease: continuing would clear the routing entry and metadata while leaving the
# home - and the secondmate's own state and backlog inside it - on disk unowned.
test_secondmate_teardown_refuses_home_referenced_by_another_task() {
  local home subhome subhome_abs fakebin log lease fmroot rc err stamp
  home="$TMP_ROOT/teardown-contested-home"
  subhome="$TMP_ROOT/teardown-contested-subhome"
  fmroot="$TMP_ROOT/teardown-contested-fmroot"
  err="$TMP_ROOT/teardown-contested.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  # A second recorded task naming the same pooled slot - the 2026-07-25 shape.
  cat > "$home/state/paused-domain.meta" <<EOF
window=firstmate:fm-paused-domain
worktree=$subhome
project=$subhome
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$subhome" domain "$home" ) \
    || fail "the contested secondmate home fixture could not be stamped"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-contested-fake")
  log="$TMP_ROOT/teardown-contested-fake/tmux.log"
  lease="$TMP_ROOT/teardown-contested-fake/lease"
  printf 'domain\n' > "$lease"
  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-contested-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "secondmate teardown should refuse a home another task still records"
  grep -F "lease RETAINED" "$err" >/dev/null || fail "the refusal did not report the retained lease"$'\n'"$(cat "$err")"
  grep -F "paused-domain" "$err" >/dev/null || fail "the refusal did not name the other holder"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null \
    && fail "a contested secondmate home lease was returned to the pool"
  [ -d "$subhome" ] || fail "a contested secondmate home was removed"
  [ -e "$lease" ] || fail "a contested secondmate home lease was released"
  grep -F 'kill-window' "$log" >/dev/null \
    && fail "a contested secondmate teardown closed an endpoint before ownership refusal"
  [ -e "$home/state/domain.meta" ] || fail "a refused secondmate teardown cleared its own metadata"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null \
    || fail "a refused secondmate teardown removed the routing entry"
  # A refused operation mutates nothing: the ownership stamp is the rule-2
  # evidence that stops a stale sibling disposing of this still-owned home.
  # shellcheck source=/dev/null
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$subhome" task || printf 'none' )
  [ "$stamp" = domain ] \
    || fail "a refused secondmate teardown erased its own ownership stamp: $stamp"
  pass "secondmate teardown refuses a home still recorded by another task"
}

# A NESTED child secondmate home was recorded and stamped by its own parent
# secondmate, so its ownership evidence names the parent's state directory and
# the parent's home - never the primary's. Judging it against the primary's
# scope compares against a home that never owned it, retains every time, and
# blocks the whole force teardown; the child's records would then be the only
# thing that could be cleared, stranding the home, its state, and its backlog.
test_secondmate_force_teardown_scopes_a_nested_child_home_to_its_parent() {
  # Named primary_home, not home: bin/fm-slot-owner-lib.sh is sourced below and
  # carries its own `home` local, which makes shellcheck read the two as one.
  local primary_home subhome nested nested_abs fakebin log fmroot
  primary_home="$TMP_ROOT/nested-scope-home"
  subhome="$TMP_ROOT/nested-scope-subhome"
  nested="$TMP_ROOT/nested-scope-child"
  fmroot="$TMP_ROOT/nested-scope-fmroot"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  git -C "$fmroot" worktree add --quiet --detach "$nested" HEAD
  mkdir -p "$primary_home/state" "$primary_home/data" "$subhome/state" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'child\n' > "$nested/.fm-secondmate-home"
  nested_abs=$(cd "$nested" && pwd -P)
  cat > "$primary_home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$nested
project=$nested
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$nested
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$primary_home/data/secondmates.md"
  # Stamped the way each home's own spawn stamps it: the child by the parent
  # secondmate's home, the parent by the primary's.
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$nested" child "$subhome" \
    && fm_slot_stamp_write "$subhome" domain "$primary_home" ) \
    || fail "the nested home fixture could not be stamped"
  fakebin=$(make_fake_tmux "$TMP_ROOT/nested-scope-fake")
  log="$TMP_ROOT/nested-scope-fake/tmux.log"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$primary_home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/nested-scope-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>/dev/null \
    || fail "force teardown refused a nested child home its own parent owned"
  grep -F "treehouse return --force $nested_abs" "$log" >/dev/null \
    || fail "the nested child home lease was never returned to the pool"
  [ ! -d "$nested" ] || fail "force teardown left the nested child home on disk"
  [ ! -e "$subhome" ] || fail "force teardown left the parent secondmate home on disk"
  [ ! -e "$primary_home/state/domain.meta" ] || fail "force teardown did not clear parent meta"
  pass "a nested child secondmate home is judged against its own parent's scope, not the primary's"
}

test_secondmate_force_teardown_preflights_nested_home_ownership() {
  local primary_home subhome nested fakebin log fmroot err
  primary_home="$TMP_ROOT/nested-preflight-home"
  subhome="$TMP_ROOT/nested-preflight-subhome"
  nested="$TMP_ROOT/nested-preflight-child"
  fmroot="$TMP_ROOT/nested-preflight-fmroot"
  err="$TMP_ROOT/nested-preflight.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  git -C "$fmroot" worktree add --quiet --detach "$nested" HEAD
  mkdir -p "$primary_home/state" "$primary_home/data" "$subhome/state" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'child\n' > "$nested/.fm-secondmate-home"
  fm_write_meta "$primary_home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  fm_write_meta "$subhome/state/child.meta" \
    "window=firstmate:fm-child" "worktree=$nested" "project=$nested" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$nested" "projects=alpha"
  fm_write_meta "$subhome/state/paused-child.meta" \
    "window=firstmate:fm-paused-child" "worktree=$nested" "project=$nested" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$primary_home/data/secondmates.md"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$nested" child "$subhome" \
    && fm_slot_stamp_write "$subhome" domain "$primary_home" ) \
    || fail "the nested ownership-preflight fixture could not be stamped"
  fakebin=$(make_fake_tmux "$TMP_ROOT/nested-preflight-fake")
  log="$TMP_ROOT/nested-preflight-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$primary_home" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/nested-preflight-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown mutated the tree before refusing contested nested ownership"
  fi
  [ -d "$subhome" ] && [ -d "$nested" ] \
    || fail "nested ownership refusal removed a secondmate home"
  [ -e "$primary_home/state/domain.meta" ] && [ -e "$subhome/state/child.meta" ] \
    || fail "nested ownership refusal cleared lifecycle metadata"
  grep -F 'kill-window' "$log" >/dev/null \
    && fail "nested ownership refusal killed an endpoint before recursive preflight completed"
  grep -F 'slot is also recorded by task(s) paused-child' "$err" >/dev/null \
    || fail "nested ownership refusal did not report the contested pooled slot"
  pass "force teardown recursively preflights every nested pooled-home owner before mutation"
}

test_secondmate_teardown_refuses_failed_leased_home_return() {
  local home subhome subhome_abs fakebin log fmroot err rc stamp
  home="$TMP_ROOT/teardown-return-fail-home"
  subhome="$TMP_ROOT/teardown-return-fail-subhome"
  fmroot="$TMP_ROOT/teardown-return-fail-fmroot"
  err="$TMP_ROOT/teardown-return-fail.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$subhome" domain "$home" ) \
    || fail "failed-return fixture could not publish its ownership stamp"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-return-fail-fake")
  log="$TMP_ROOT/teardown-return-fail-fake/tmux.log"

  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-return-fail-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown succeeded despite failed treehouse return"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not try to return the leased home"
  grep -F 'treehouse return failed for secondmate home' "$err" >/dev/null || fail "teardown did not report failed leased home return"
  [ -d "$subhome" ] || fail "teardown removed a leased home after return failed"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared meta after leased home return failed"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$subhome" task || printf 'none' )
  [ "$stamp" = domain ] || fail "teardown cleared ownership evidence before leased-home return succeeded"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null || fail "teardown removed registry route after leased home return failed"
  pass "secondmate teardown refuses to hide failed leased-home return"
}

test_secondmate_teardown_removes_plain_clone_home_without_treehouse_return() {
  local home subhome subhome_abs fakebin log
  home="$TMP_ROOT/plain-clone-teardown-home"
  subhome="$TMP_ROOT/plain-clone-teardown-subhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  mark_firstmate_home "$subhome"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/plain-clone-teardown-fake")
  log="$TMP_ROOT/plain-clone-teardown-fake/tmux.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/plain-clone-teardown-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for plain-clone secondmate home"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null && fail "teardown tried to return a plain-clone home through treehouse"
  [ ! -d "$subhome" ] || fail "teardown did not remove the plain-clone secondmate home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta for plain-clone home"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "teardown did not remove plain-clone registry route"
  pass "secondmate teardown raw-removes plain-clone homes"
}

test_secondmate_force_teardown_discards_child_work() {
  local home subhome childproj childwt fakebin log
  home="$TMP_ROOT/force-teardown-home"
  subhome="$TMP_ROOT/force-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/force-child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  fm_git_worktree "$childproj" "$childwt" force-child
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/force-teardown-fake")
  log="$TMP_ROOT/force-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>&1; then
    fail "teardown allowed a secondmate with in-flight child work"
  fi
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>/dev/null \
    || fail "force teardown failed to discard child work"
  [ ! -d "$subhome" ] || fail "force teardown did not remove the retired secondmate home"
  [ ! -d "$childwt" ] || fail "force teardown did not remove child worktree"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "force teardown did not remove secondmate registry route"
  grep -F 'kill-window -t firstmate:fm-child' "$log" >/dev/null || fail "force teardown did not kill child window"
  grep -F 'kill-window -t firstmate:fm-domain' "$log" >/dev/null || fail "force teardown did not kill parent window"
  pass "secondmate force teardown discards child work"
}

test_secondmate_force_teardown_preserves_linked_child_without_treehouse() {
  local home subhome childproj childwt fakebin log err rc stamp
  home="$TMP_ROOT/no-treehouse-home"
  subhome="$TMP_ROOT/no-treehouse-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/no-treehouse-child-worktree"
  err="$TMP_ROOT/no-treehouse.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  fm_git_worktree "$childproj" "$childwt" no-treehouse-child
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  fm_write_meta "$subhome/state/child.meta" \
    "window=firstmate:fm-child" "worktree=$childwt" "project=$childproj" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$childwt" child "$subhome" ) \
    || fail "no-treehouse child fixture could not be stamped"
  fakebin=$(make_fake_tmux "$TMP_ROOT/no-treehouse-fake")
  log="$TMP_ROOT/no-treehouse-fake/tmux.log"
  rm -f "$fakebin/treehouse"
  set +e
  PATH="$fakebin:/usr/bin:/bin" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/no-treehouse-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "force teardown raw-deleted a linked child without treehouse"
  grep -F 'treehouse command not found; preserving child worktree' "$err" >/dev/null \
    || fail "missing-treehouse refusal lost its reason"
  [ ! -s "$log" ] || fail "missing-treehouse preflight closed an endpoint before refusing"
  [ -e "$home/state/domain.meta" ] || fail "missing-treehouse preflight removed parent metadata"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null \
    || fail "missing-treehouse preflight removed the secondmate route"
  [ -d "$childwt" ] || fail "missing treehouse removed the linked child worktree"
  [ -e "$subhome/state/child.meta" ] || fail "missing treehouse removed child metadata"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$childwt" task || printf 'none' )
  [ "$stamp" = child ] || fail "missing treehouse cleared linked-child ownership evidence"
  pass "force teardown preserves linked child ownership when treehouse is unavailable"
}

test_secondmate_force_teardown_recursively_preserves_without_treehouse() {
  local home subhome nested grandproj grandwt fmroot fakebin log err rc
  local home_before home_after sub_before sub_after nested_before nested_after
  local grand_stamp
  home="$TMP_ROOT/no-treehouse-recursive-home"
  subhome="$TMP_ROOT/no-treehouse-recursive-subhome"
  nested="$TMP_ROOT/no-treehouse-recursive-nested"
  grandproj="$nested/projects/alpha"
  grandwt="$TMP_ROOT/no-treehouse-recursive-grandchild"
  fmroot="$TMP_ROOT/no-treehouse-recursive-fmroot"
  err="$TMP_ROOT/no-treehouse-recursive.err"
  make_firstmate_git_root "$fmroot"
  make_firstmate_git_root "$subhome"
  make_firstmate_git_root "$nested"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$nested/state"
  fm_git_worktree "$grandproj" "$grandwt" no-treehouse-grandchild
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'child\n' > "$nested/.fm-secondmate-home"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  fm_write_meta "$subhome/state/child.meta" \
    "window=firstmate:fm-child" "worktree=$nested" "project=$nested" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$nested" "projects=alpha"
  fm_write_meta "$nested/state/grand.meta" \
    "window=firstmate:fm-grand" "worktree=$grandwt" "project=$grandproj" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$grandwt" grand "$nested" ) \
    || fail "recursive missing-treehouse fixture could not be stamped"
  home_before=$(snapshot_tree_identity "$home")
  sub_before=$(snapshot_tree_identity "$subhome")
  nested_before=$(snapshot_tree_identity "$nested")
  fakebin=$(make_fake_tmux "$TMP_ROOT/no-treehouse-recursive-fake")
  log="$TMP_ROOT/no-treehouse-recursive-fake/tmux.log"
  rm -f "$fakebin/treehouse"
  set +e
  PATH="$fakebin:/usr/bin:/bin" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/no-treehouse-recursive-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recursive teardown crossed missing Treehouse capability"
  home_after=$(snapshot_tree_identity "$home")
  sub_after=$(snapshot_tree_identity "$subhome")
  nested_after=$(snapshot_tree_identity "$nested")
  [ "$home_after" = "$home_before" ] || fail "recursive preflight changed the parent home tree"
  [ "$sub_after" = "$sub_before" ] || fail "recursive preflight changed the child home tree"
  [ "$nested_after" = "$nested_before" ] || fail "recursive preflight changed the nested home tree"
  [ ! -s "$log" ] || fail "recursive preflight closed an endpoint"
  [ -d "$subhome" ] && [ -d "$nested" ] && [ -d "$grandwt" ] \
    || fail "recursive preflight removed a home or worktree"
  grand_stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$grandwt" task )
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_path "$subhome" ) 2>/dev/null \
    && fail "recursive preflight added a stamp to the plain parent home"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_path "$nested" ) 2>/dev/null \
    && fail "recursive preflight added a stamp to the plain nested home"
  [ "$grand_stamp" = grand ] \
    || fail "recursive preflight changed pooled ownership stamps"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null \
    || fail "recursive preflight removed the parent route"
  pass "recursive missing-Treehouse preflight preserves every nested lifecycle surface"
}
test_secondmate_force_teardown_allows_operational_dir_symlinks_inside_home() {
  local opdir home subhome target fakebin err log
  for opdir in data state config projects; do
    home="$TMP_ROOT/symlink-inside-teardown-home-$opdir"
    subhome="$TMP_ROOT/symlink-inside-teardown-subhome-$opdir"
    target="$subhome/internal-$opdir"
    err="$TMP_ROOT/symlink-inside-teardown-$opdir.err"
    rm -rf "$home" "$subhome"
    mkdir -p "$home/state" "$home/data" "$subhome" "$target"
    printf 'domain\n' > "$subhome/.fm-secondmate-home"
    ln -s "$target" "$subhome/$opdir"
    cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
    printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
    fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-inside-teardown-fake-$opdir")
    log="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/tmux.log"
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/pane.txt" \
      "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err" \
      || fail "force teardown refused $opdir symlinked inside the secondmate home"
    [ ! -e "$subhome" ] || fail "force teardown did not remove subhome with inside $opdir symlink"
    [ ! -e "$home/state/domain.meta" ] || fail "force teardown did not clear parent meta for inside $opdir symlink"
    grep -F 'kill-window -t firstmate:fm-domain' "$log" >/dev/null || fail "force teardown did not kill parent window for inside $opdir symlink"
  done
  pass "force teardown allows operational directory symlinks inside the subhome"
}

test_secondmate_force_teardown_refuses_operational_dir_symlink_outside_home() {
  local home subhome external_state fakebin err log
  home="$TMP_ROOT/symlink-state-teardown-home"
  subhome="$TMP_ROOT/symlink-state-teardown-subhome"
  external_state="$home/data/external-state"
  err="$TMP_ROOT/symlink-state-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome" "$external_state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  ln -s "$external_state" "$subhome/state"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-state-teardown-fake")
  log="$TMP_ROOT/symlink-state-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-state-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown accepted a symlinked secondmate state directory"
  fi
  [ -d "$subhome" ] || fail "force teardown removed subhome after symlinked state refusal"
  [ -d "$external_state" ] || fail "force teardown removed external symlink target"
  grep -F 'state directory' "$err" >/dev/null || fail "teardown did not explain symlinked state refusal"
  grep -F 'resolves outside the secondmate home' "$err" >/dev/null || fail "teardown did not identify unsafe state symlink"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before symlinked state refusal"
  pass "force teardown refuses operational directory symlinks outside the subhome"
}

test_secondmate_teardown_path_boundary_matrix() {
  # The teardown path-boundary matrix: a secondmate home is refused (and left
  # fully intact, with no window killed before validation) when it is unmarked,
  # an ancestor of the active firstmate home, inside the active firstmate home,
  # or inside the firstmate repo. One row per hazard, one shared assertion block.
  local row base home subhome fmroot fakebin log err expect tid
  while IFS='|' read -r row expect; do
    [ -n "$row" ] || continue
    base="$TMP_ROOT/td-pb-$row"
    fmroot="$ROOT"   # real firstmate repo unless a row overrides it
    tid=domain
    case "$row" in
      unmarked)
        home="$base/main"; subhome="$base/sub"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        # No .fm-secondmate-home marker on purpose.
        ;;
      ancestor)
        # The home being torn down is an ANCESTOR of the active firstmate home.
        subhome="$base/anc"; home="$subhome/main-home"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        printf 'domain\n' > "$subhome/.fm-secondmate-home"
        ;;
      active-descendant)
        home="$base/desc"; subhome="$home/data/domain-home"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        printf 'domain\n' > "$subhome/.fm-secondmate-home"
        ;;
      repo-descendant)
        home="$base/home"; fmroot="$base/root"; subhome="$fmroot/tmp/domain-home"; tid='repo-domain'
        mkdir -p "$home/state" "$home/data" "$subhome/state" "$fmroot/bin"
        cat > "$fmroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
        chmod +x "$fmroot/bin/fm-guard.sh"
        printf 'repo-domain\n' > "$subhome/.fm-secondmate-home"
        ;;
    esac
    fm_write_secondmate_meta "$home/state/$tid.meta" "$subhome"
    printf -- '- %s - design domain (home: %s; scope: design domain; projects: alpha; added 2026-06-22)\n' \
      "$tid" "$subhome" > "$home/data/secondmates.md"
    fakebin=$(make_fake_tmux "$base/fake")
    log="$base/fake/tmux.log"
    err="$base/teardown.err"
    if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
      FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$base/fake/pane.txt" \
      "$ROOT/bin/fm-teardown.sh" "$tid" >/dev/null 2>"$err"; then
      fail "teardown ($row) accepted a hazardous secondmate home"
    fi
    grep -F "$expect" "$err" >/dev/null || fail "teardown ($row) did not explain the refusal (expected '$expect'): $(cat "$err")"
    [ -d "$subhome" ] || fail "teardown ($row) removed the protected home after refusal"
    [ -e "$home/state/$tid.meta" ] || fail "teardown ($row) cleared the parent meta after refusal"
    grep -F -- "- $tid " "$home/data/secondmates.md" >/dev/null || fail "teardown ($row) removed the registry route after refusal"
    grep -F 'kill-window' "$log" >/dev/null && fail "teardown ($row) killed a window before validation"
  done <<'ROWS'
unmarked|not a seeded secondmate home
ancestor|ancestor of the active firstmate home
active-descendant|inside the active firstmate home
repo-descendant|inside the firstmate repo
ROWS
  pass "secondmate teardown path-boundary matrix refuses unmarked/ancestor/active-descendant/repo-descendant homes"
}

test_secondmate_teardown_refuses_registered_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/nested-teardown-home"
  subhome="$TMP_ROOT/nested-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/nested-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'nested\n' > "$nested/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  cat > "$home/state/nested.meta" <<EOF
window=firstmate:fm-nested
worktree=$nested
project=$nested
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$nested
projects=beta
EOF
  cat > "$home/data/secondmates.md" <<EOF
- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)
- nested - nested domain mentions home: $TMP_ROOT/ignored-summary-home (home: $nested; scope: nested domain mentions home: $TMP_ROOT/ignored-scope-home; projects: beta; added 2026-06-22)
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/nested-teardown-fake")
  log="$TMP_ROOT/nested-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/nested-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing another registered secondmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed registered ancestor home after refusal"
  [ -d "$nested" ] || fail "teardown removed registered nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared ancestor meta after nested-home refusal"
  [ -e "$home/state/nested.meta" ] || fail "teardown cleared nested meta after nested-home refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before nested-home refusal"
  grep -F 'contains registered secondmate home' "$err" >/dev/null || fail "teardown did not explain registered nested-home refusal"
  pass "secondmate teardown refuses homes containing registered nested homes"
}

test_secondmate_teardown_refuses_child_registry_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/child-registry-teardown-home"
  subhome="$TMP_ROOT/child-registry-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/child-registry-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/data" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'nested\n' > "$nested/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  printf '%s\n' '- nested - nested domain (home: '"$nested"'; scope: nested domain; projects: beta; added 2026-06-22)' > "$subhome/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-registry-teardown-fake")
  log="$TMP_ROOT/child-registry-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-registry-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing a child-registry secondmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed ancestor home after child-registry refusal"
  [ -d "$nested" ] || fail "teardown removed child-registry nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared parent meta after child-registry refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before child-registry refusal"
  grep -F 'contains registered secondmate home' "$err" >/dev/null || fail "teardown did not explain child-registry nested-home refusal"
  pass "secondmate teardown refuses nested homes from the child registry"
}

test_secondmate_force_teardown_prevalidates_before_child_cleanup() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/prevalidate-teardown-home"
  subhome="$TMP_ROOT/prevalidate-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/prevalidate-child-worktree"
  err="$TMP_ROOT/prevalidate-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/prevalidate-teardown-fake")
  log="$TMP_ROOT/prevalidate-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/prevalidate-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown discarded child work before validating subhome"
  fi
  [ -d "$subhome" ] || fail "force teardown removed unmarked subhome after refusal"
  [ -d "$childwt" ] || fail "force teardown removed child worktree before validation"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta before validation"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta before validation"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before subhome validation"
  grep -F 'not a seeded secondmate home' "$err" >/dev/null || fail "force teardown did not explain missing seed marker"
  pass "force teardown validates subhome before child cleanup"
}

test_secondmate_force_teardown_refuses_unknown_child_backend() {
  local home subhome fakebin err log
  home="$TMP_ROOT/unknown-backend-teardown-home"
  subhome="$TMP_ROOT/unknown-backend-teardown-subhome"
  err="$TMP_ROOT/unknown-backend-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/data"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$TMP_ROOT/unknown-backend-child-worktree
project=$TMP_ROOT/unknown-backend-child-project
harness=echo
kind=ship
mode=no-mistakes
yolo=off
backend=orca
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/unknown-backend-teardown-fake")
  log="$TMP_ROOT/unknown-backend-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/unknown-backend-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown accepted a child with an unknown backend"
  fi
  [ -d "$subhome" ] || fail "force teardown removed the subhome after unsupported-backend refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown removed child metadata after unknown-backend refusal"
  grep -F "REFUSED: child child uses unsupported backend 'orca'" "$err" >/dev/null \
    || fail "force teardown did not explain unsupported child backend"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed a window before unknown-backend refusal"
  pass "force teardown refuses unknown child backends before cleanup"
}

test_secondmate_force_teardown_refuses_child_active_home_descendant() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/child-active-descendant-home"
  subhome="$TMP_ROOT/child-active-descendant-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$home/data"
  err="$TMP_ROOT/child-active-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-active-descendant-fake")
  log="$TMP_ROOT/child-active-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-active-descendant-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside active FM_HOME"
  fi
  [ -d "$home/data" ] || fail "force teardown removed active home data"
  [ -d "$subhome" ] || fail "force teardown removed subhome after child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before child validation refusal"
  grep -F 'inside the active firstmate home' "$err" >/dev/null || fail "force teardown did not explain active home descendant rejection"
  pass "force teardown refuses child worktrees inside the active home"
}

test_secondmate_force_teardown_refuses_child_repo_descendant() {
  local home subhome childproj childwt fakeroot fakebin err log
  home="$TMP_ROOT/child-repo-descendant-home"
  subhome="$TMP_ROOT/child-repo-descendant-subhome"
  childproj="$subhome/projects/alpha"
  fakeroot="$TMP_ROOT/child-repo-descendant-root"
  childwt="$fakeroot/data"
  err="$TMP_ROOT/child-repo-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj"
  make_firstmate_git_root "$fakeroot"
  mkdir -p "$childwt"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-repo-descendant-fake")
  log="$TMP_ROOT/child-repo-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-repo-descendant-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside FM_ROOT"
  fi
  [ -d "$childwt" ] || fail "force teardown removed repo descendant worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after repo child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after repo child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after repo child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before repo child validation refusal"
  grep -F 'inside the firstmate repo' "$err" >/dev/null || fail "force teardown did not explain repo descendant rejection"
  pass "force teardown refuses child worktrees inside the firstmate repo"
}

test_secondmate_force_teardown_refuses_unregistered_child_worktree() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/unregistered-child-home"
  subhome="$TMP_ROOT/unregistered-child-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/unregistered-child-worktree"
  err="$TMP_ROOT/unregistered-child.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  fm_git_init_commit "$childproj"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/unregistered-child-fake")
  log="$TMP_ROOT/unregistered-child-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/unregistered-child-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed an unregistered child worktree"
  fi
  [ -d "$childwt" ] || fail "force teardown removed unregistered child worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after unregistered child refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after unregistered child refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after unregistered child refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before unregistered child refusal"
  grep -F 'unregistered git worktree registration' "$err" >/dev/null \
    || fail "force teardown did not explain unregistered child rejection"
  pass "force teardown refuses unregistered child worktree paths"
}

test_secondmate_idle_pane_is_not_stale() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state"
  window="firstmate:fm-domain"
  cat > "$home/state/domain.meta" <<EOF
window=$window
worktree=$TMP_ROOT/watch-subhome
project=$TMP_ROOT/watch-subhome
harness=echo
kind=secondmate
home=$TMP_ROOT/watch-subhome
projects=alpha
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/watch-fake")
  out="$TMP_ROOT/watch-fake/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_LOG="$TMP_ROOT/watch-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/watch-fake/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    wait "$pid" || true
    grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
    fail "watcher exited unexpectedly while supervising idle secondmate"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
  pass "idle kind=secondmate pane is healthy and not stale"
}

test_secondmate_charter_brief_is_idle_by_default() {
  local home brief
  home="$TMP_ROOT/idle-charter-home"
  mkdir -p "$home/data" "$home/state"
  scaffold_secondmate_charter "$home" idle-sm 'feature work for alpha' alpha
  brief="$home/data/idle-sm/brief.md"
  [ -f "$brief" ] || fail "secondmate charter brief was not scaffolded"
  # Idle contract: waits for routed work, never self-initiates.
  grep -F 'go idle and wait silently for the main firstmate' "$brief" >/dev/null \
    || fail "charter brief does not tell the secondmate to go idle and wait for routed work"
  grep -F 'Act only on tasks the main firstmate routes to you' "$brief" >/dev/null \
    || fail "charter brief does not restrict work to routed tasks"
  grep -F 'never spawn a survey, audit, or any self-directed' "$brief" >/dev/null \
    || fail "charter brief does not forbid self-initiated survey/audit work"
  # Reconcile-on-startup must remain: bootstrap and recovery still run, scoped to own work.
  grep -F 'run normal firstmate bootstrap and recovery' "$brief" >/dev/null \
    || fail "charter brief dropped the bootstrap/recovery reconciliation step"
  grep -F 'only to RECONCILE work that is already yours' "$brief" >/dev/null \
    || fail "charter brief does not scope startup work to reconciling existing work"
  # Regression guard: the over-broad phrasing that got misread as "go find work" is gone.
  if grep -F 'then supervise work that matches your scope' "$brief" >/dev/null; then
    fail "charter brief still uses the over-broad 'supervise work that matches your scope' phrasing"
  fi
  pass "secondmate charter brief is idle by default and does not self-initiate work"
}

test_backlog_handoff_aborts_safely() {
  # The happy move (verbatim into the Queued section, out-of-scope left alone,
  # idempotent re-run) is asserted in the lifecycle e2e. Here: every refusal path
  # aborts atomically and mutates neither backlog.
  local home subhome subhome_abs before
  home="$TMP_ROOT/handoff-main"
  subhome="$TMP_ROOT/handoff-sub"
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$subhome" design
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - shipped thing - local main (merged 2026-06-19)
EOF

  # A key matching neither backlog aborts atomically: nothing moves.
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design bug-z no-such-key >/dev/null 2>&1; then
    fail "handoff succeeded despite an unmatched key"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an unmatched key still mutated the main backlog"
  grep -F 'bug-z' "$home/data/backlog.md" >/dev/null || fail "atomic abort lost the valid bug-z item"

  # An in-flight item is refused (active ownership lives in tmux + state too).
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design live-task >/dev/null 2>&1; then
    fail "handoff accepted an in-flight backlog item"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an in-flight key mutated the main backlog"
  grep -F 'live-task' "$home/data/backlog.md" >/dev/null || fail "in-flight refusal lost the live task"
  [ ! -e "$subhome/data/backlog.md" ] || ! grep -F 'live-task' "$subhome/data/backlog.md" >/dev/null     || fail "in-flight refusal copied the live task into the secondmate backlog"

  # An unregistered secondmate id is refused.
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" ghost bug-z >/dev/null 2>&1; then
    fail "handoff accepted an unregistered secondmate id"
  fi
  pass "fm-backlog-handoff aborts atomically on unmatched, in-flight, and unregistered targets"
}

test_backlog_handoff_creates_absent_section_and_refuses_non_secondmate_home() {
  local home subhome subhome_abs projhome projhome_abs markerhome markerhome_abs symlinkhome symlinkhome_abs outside
  home="$TMP_ROOT/handoff-safety-main"
  subhome="$TMP_ROOT/handoff-safety-sub"
  projhome="$TMP_ROOT/handoff-safety-proj"
  markerhome="$TMP_ROOT/handoff-safety-marker"
  symlinkhome="$TMP_ROOT/handoff-safety-symlink"
  outside="$TMP_ROOT/handoff-safety-outside"
  mkdir -p "$home/data" "$home/state"

  # A Done item handed into a secondmate backlog lacking a Done section gets one.
  seed_secondmate_home_marker "$subhome" archive
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '## Queued\n- [ ] keep-me - stays (repo: alpha)\n' > "$subhome/data/backlog.md"
  printf -- '- archive - archival (home: %s; scope: archival; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] shipped-task - shipped thing - local main (merged 2026-06-19)
EOF
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" archive shipped-task >/dev/null \
    || fail "handoff of a Done item failed"
  grep -F '## Done' "$subhome/data/backlog.md" >/dev/null \
    || fail "handoff did not create the missing Done section in the secondmate backlog"
  awk '/^## Done/{d=1;next} /^## /{d=0} d && /shipped-task/{found=1} END{exit found?0:1}' "$subhome/data/backlog.md" \
    || fail "Done item did not land under the created Done section"
  grep -F 'keep-me' "$subhome/data/backlog.md" >/dev/null || fail "handoff clobbered the existing secondmate backlog content"

  # A registered home that is not a seeded secondmate home (e.g. a project clone)
  # is refused, and nothing is written into it.
  fm_git_init_commit "$projhome"
  projhome_abs=$(cd "$projhome" && pwd -P)
  printf -- '- proj-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$projhome_abs" >> "$home/data/secondmates.md"
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" proj-sm shipped-task >/dev/null 2>&1; then
    fail "handoff wrote into a destination that is not a seeded secondmate home"
  fi
  [ ! -e "$projhome/data/backlog.md" ] || fail "handoff created a backlog inside a non-secondmate home"

  mkdir -p "$markerhome/data"
  markerhome_abs=$(cd "$markerhome" && pwd -P)
  printf 'marker-sm\n' > "$markerhome/.fm-secondmate-home"
  printf -- '- marker-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$markerhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] marker-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" marker-sm marker-task >/dev/null 2>&1; then
    fail "handoff accepted a marker-only directory as a secondmate home"
  fi
  [ ! -e "$markerhome/data/backlog.md" ] || fail "handoff wrote into a marker-only directory"
  grep -F 'marker-task' "$home/data/backlog.md" >/dev/null || fail "marker-only refusal lost the main backlog item"

  seed_secondmate_home_marker "$symlinkhome" symlink-sm
  symlinkhome_abs=$(cd "$symlinkhome" && pwd -P)
  mkdir -p "$outside"
  rm -rf "$symlinkhome/data"
  ln -s "$outside" "$symlinkhome/data"
  printf -- '- symlink-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$symlinkhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] symlink-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" symlink-sm symlink-task >/dev/null 2>&1; then
    fail "handoff accepted a secondmate home with data outside the home"
  fi
  [ ! -e "$outside/backlog.md" ] || fail "handoff wrote through a symlinked secondmate data directory"
  grep -F 'symlink-task' "$home/data/backlog.md" >/dev/null || fail "symlink refusal lost the main backlog item"
  pass "fm-backlog-handoff creates absent sections and refuses unsafe homes"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_seed_allows_overlapping_clones_and_drops_owner
test_home_seed_validate_rejects_duplicate_homes
test_home_seed_validate_rejects_duplicate_ids
test_home_seed_validate_rejects_nested_homes
test_home_seed_uses_treehouse_acquired_home
test_home_seed_returns_treehouse_acquired_home_on_assignment_failure
test_home_seed_warns_when_acquired_home_return_fails
test_home_seed_does_not_return_unsafe_acquired_home
test_home_seed_rolls_back_failed_clone
test_home_seed_refuses_missing_filled_charter
test_home_seed_refuses_placeholder_charter
test_home_seed_refuses_empty_charter_fields
test_home_seed_refuses_local_only_project
test_home_seed_refuses_registry_delimiter_home
test_home_seed_refuses_active_home_and_root
test_home_seed_refuses_home_marked_for_another_id
test_home_seed_refuses_home_registered_to_another_id
test_home_seed_refuses_reassigning_existing_id_to_different_home
test_home_seed_refuses_home_overlapping_registered_home
test_home_seed_refuses_remote_backed_project_without_origin
test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin
test_home_seed_resolves_relative_source_origins
test_home_seed_skips_initialized_existing_no_mistakes_projects
test_home_seed_refuses_uninitialized_existing_no_mistakes_project
test_home_seed_refuses_project_destinations_outside_subhome
test_home_seed_refuses_operational_dirs_outside_subhome
test_home_seed_refuses_symlinked_leaf_files
test_secondmate_spawn_requires_seeded_matching_home
test_secondmate_spawn_refuses_operational_dirs_outside_subhome
test_secondmate_spawn_allows_plain_clone_home_without_stamp
test_fm_send_refuses_bare_window_without_home_meta
test_secondmate_teardown_retires_empty_home
test_secondmate_teardown_serializes_against_spawn
test_secondmate_teardown_blocks_prelock_legacy_spawn
test_secondmate_teardown_quiescence_catches_late_legacy_spawn
test_secondmate_teardown_blocks_child_publication_during_census
test_secondmate_teardown_refuses_home_referenced_by_another_task
test_secondmate_force_teardown_scopes_a_nested_child_home_to_its_parent
test_secondmate_force_teardown_preflights_nested_home_ownership
test_secondmate_teardown_refuses_failed_leased_home_return
test_secondmate_teardown_removes_plain_clone_home_without_treehouse_return
test_secondmate_force_teardown_discards_child_work
test_secondmate_force_teardown_preserves_linked_child_without_treehouse
test_secondmate_force_teardown_recursively_preserves_without_treehouse
test_secondmate_force_teardown_allows_operational_dir_symlinks_inside_home
test_secondmate_force_teardown_refuses_operational_dir_symlink_outside_home
test_secondmate_teardown_refuses_registered_nested_home
test_secondmate_teardown_refuses_child_registry_nested_home
test_secondmate_force_teardown_prevalidates_before_child_cleanup
test_secondmate_force_teardown_refuses_unknown_child_backend
test_secondmate_force_teardown_refuses_child_active_home_descendant
test_secondmate_force_teardown_refuses_child_repo_descendant
test_secondmate_force_teardown_refuses_unregistered_child_worktree
test_secondmate_teardown_path_boundary_matrix
test_secondmate_idle_pane_is_not_stale
test_secondmate_charter_brief_is_idle_by_default
test_backlog_handoff_aborts_safely
test_backlog_handoff_creates_absent_section_and_refuses_non_secondmate_home
