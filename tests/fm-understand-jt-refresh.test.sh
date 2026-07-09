#!/usr/bin/env bash
# Tests for the JT Understand Anything graph refresh helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-understand-jt-refresh"
TMP_ROOT=$(fm_test_tmproot fm-understand-jt-refresh)

write_understand_fixture() {
  local repo=$1 ua head
  ua="$repo/.understand-anything"
  head=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$ua/tmp" "$ua/intermediate"
  cat > "$ua/config.json" <<'JSON'
{"scope":"test"}
JSON
  cat > "$ua/.understandignore" <<'IGNORE'
*
!app/**
!components/**
!lib/**
!scripts/lib/**
public/data/
docs/
state/
reports/
.next/
node_modules/
*.sqlite
*.csv
*.xlsx
*.pdf
*.zip
IGNORE
  cat > "$ua/tmp/ua-deterministic-understand.mjs" <<'JS'
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";

const ua = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const repo = path.dirname(ua);
const head = spawnSync("git", ["-C", repo, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim();
fs.mkdirSync(path.join(ua, "intermediate"), { recursive: true });
fs.writeFileSync(path.join(ua, "knowledge-graph.json"), JSON.stringify({
  nodes: [{ id: "app/page.tsx", filePath: "app/page.tsx" }],
  edges: [{ from: "app/page.tsx", to: "lib/demo.ts" }],
  layers: ["app"],
  tour: [{ file: "app/page.tsx" }]
}));
fs.writeFileSync(path.join(ua, "meta.json"), JSON.stringify({ gitCommitHash: head, analyzedFiles: 1 }));
fs.writeFileSync(path.join(ua, "intermediate", "review.json"), JSON.stringify({ issues: [], warnings: [] }));
fs.writeFileSync(path.join(ua, "intermediate", "summary.json"), JSON.stringify({ project: { gitCommitHash: head }, files: { total: 1, filteredByIgnore: 0 } }));
JS
  printf '%s\n' "$head" > "$ua/expected-head"
}

test_refresh_accepts_git_worktree_dotgit_file() {
  local root repo worktree home out rc
  root="$TMP_ROOT/worktree-refresh"
  repo="$root/repo"
  worktree="$root/worktree"
  home="$root/home"
  fm_git_worktree "$repo" "$worktree" feature
  mkdir -p "$worktree/app" "$worktree/components" "$worktree/lib" "$worktree/scripts/lib" "$home/state"
  printf '%s\n' 'export default function Page() { return null; }' > "$worktree/app/page.tsx"
  write_understand_fixture "$worktree"

  set +e
  out=$(FM_HOME="$home" JT_REPO="$worktree" "$REFRESH" --refresh 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "refresh should accept a git worktree checkout"
  assert_contains "$out" '"lastRefreshStatus": "success"' "refresh should succeed for worktree checkout"
  assert_present "$home/state/jt-understand-graph.summary.json" "summary should be written under FM_HOME state"
  pass "JT Understand refresh accepts git worktree .git files"
}

test_refresh_reference_commands_use_repo_root_with_external_home() {
  local root repo home out rc
  root="$TMP_ROOT/external-home-commands"
  repo="$root/repo"
  home="$root/home"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/app" "$repo/components" "$repo/lib" "$repo/scripts/lib" "$home/state"
  printf '%s\n' 'export default function Page() { return null; }' > "$repo/app/page.tsx"
  write_understand_fixture "$repo"

  set +e
  out=$(FM_HOME="$home" JT_REPO="$repo" "$REFRESH" --reference 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "reference should succeed with external FM_HOME"
  assert_contains "$out" "$ROOT/bin/fm-understand-jt-refresh --refresh" "reference should point refresh command at repo root bin"
  assert_contains "$(cat "$home/state/jt-understand-graph.summary.json")" "$ROOT/bin/fm-understand-jt-refresh --status" "summary should point status command at repo root bin"
  assert_no_grep "$home/bin/fm-understand-jt-refresh" "$home/state/jt-understand-graph.reference.md" "reference should not point helper commands at FM_HOME bin"
  pass "JT Understand refresh command references use repo root bin"
}

test_refresh_accepts_git_worktree_dotgit_file
test_refresh_reference_commands_use_repo_root_with_external_home
