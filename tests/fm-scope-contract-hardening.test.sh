#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-scope-contract.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-scope-hardening.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

printf 'AC-1\tFeature behavior is proved.\nNG-1\tGlobal enforcement stays disabled.\n' > "$TMP/spec.tsv"
: > "$TMP/brief.md"
"$SCRIPT" append-brief "$TMP/spec.tsv" "$TMP/brief.md" no-mistakes

test_visible_uniquely_headed_ledger_only() {
  cat > "$TMP/body.md" <<'EOF'
```md
| AC-1 | covered | fake | none |
| NG-1 | out-of-scope | fake | none |
```
<!-- | AC-1 | covered | fake | none | -->
## PR scope ledger (advisory)
| ID | Status | Evidence | Residual risk |
| --- | --- | --- | --- |
| AC-1 | covered | test proof | none |
| NG-1 | out-of-scope | scope boundary | none |
EOF
  out=$("$SCRIPT" audit-body "$TMP/brief.md" "$TMP/body.md")
  [ "$out" = $'scope-ledger\tpass\tfindings=0' ] || fail "visible ledger did not pass: $out"
  pass 'only the uniquely headed visible ledger is counted'
}

test_code_and_comment_rows_cannot_fake_completion() {
  cat > "$TMP/body.md" <<'EOF'
```md
| AC-1 | covered | fake | none |
| NG-1 | out-of-scope | fake | none |
```
<!-- | AC-1 | covered | fake | none | -->
EOF
  out=$("$SCRIPT" audit-body "$TMP/brief.md" "$TMP/body.md")
  printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tmissing\tAC-1' || fail 'code/comment row satisfied AC-1'
  printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tmissing\tNG-1' || fail 'code/comment row satisfied NG-1'
  pass 'code fences and HTML comments cannot satisfy the ledger'
}

test_duplicate_ledger_heading_is_visible() {
  cat > "$TMP/body.md" <<'EOF'
## PR scope ledger (advisory)
| AC-1 | covered | test proof | none |
## PR scope ledger (advisory)
| NG-1 | out-of-scope | scope boundary | none |
EOF
  out=$("$SCRIPT" audit-body "$TMP/brief.md" "$TMP/body.md")
  printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tduplicate-heading\tPR-scope-ledger' || fail 'duplicate ledger heading was accepted'
  pass 'the PR scope ledger heading is unique'
}

test_fenced_heading_cannot_authorize_rows() {
  for fence in '```text' '~~~text'; do
    {
      printf '%s\n## PR scope ledger (advisory)\n' "$fence"
      case "$fence" in '```text') printf '```\n' ;; *) printf '~~~\n' ;; esac
      printf '| AC-1 | covered | test proof | none |\n| NG-1 | out-of-scope | boundary | none |\n'
    } > "$TMP/body.md"
    out=$("$SCRIPT" audit-body "$TMP/brief.md" "$TMP/body.md")
    printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tmissing\tAC-1' || fail "fenced heading was accepted for $fence"
  done
  pass 'backtick and tilde fenced headings cannot authorize ledger rows'
}

test_fence_delimiter_length_and_indentation_are_respected() {
  cat > "$TMP/body.md" <<'EOF'
   ````md
```
~~~
## PR scope ledger (advisory)
| AC-1 | covered | fake | none |
| NG-1 | out-of-scope | fake | none |
   ````
EOF
  out=$("$SCRIPT" audit-body "$TMP/brief.md" "$TMP/body.md")
  printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tmissing\tAC-1' || fail 'mismatched or short fence close exposed AC-1'
  printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tmissing\tNG-1' || fail 'mismatched or short fence close exposed NG-1'
  pass 'fence closing matches the opening delimiter, length, and indentation'
}

test_only_contiguous_table_rows_satisfy_the_ledger() {
  for fake_rows in \
    'note | AC-1 | covered | fake | none |
note | NG-1 | out-of-scope | fake | none |' \
    '    | AC-1 | covered | fake | none |
    | NG-1 | out-of-scope | fake | none |'
  do
    {
      printf '%s\n' '## PR scope ledger (advisory)'
      printf '%s\n' '| ID | Status | Evidence | Residual risk |'
      printf '%s\n' '| --- | --- | --- | --- |'
      printf '%s\n' "$fake_rows"
    } > "$TMP/body.md"
    out=$("$SCRIPT" audit-body "$TMP/brief.md" "$TMP/body.md")
    printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tmissing\tAC-1' || fail 'non-table text satisfied AC-1'
    printf '%s\n' "$out" | grep -q $'scope-ledger-finding\tmissing\tNG-1' || fail 'non-table text satisfied NG-1'
  done
  pass 'only contiguous non-code rows in the documented table shape count'
}

test_marker_rejects_nul_and_symlink_destination() {
  printf 'firstmate-scope-contract-v1\n\0suffix' > "$TMP/bad-marker"
  ! "$SCRIPT" validate-marker "$TMP/bad-marker" >/dev/null 2>&1 || fail 'NUL marker was accepted'
  printf 'protected\n' > "$TMP/target"
  ln -s "$TMP/target" "$TMP/scope-contract-enabled"
  ! "$SCRIPT" publish-marker "$TMP/scope-contract-enabled" >/dev/null 2>&1 || fail 'symlink marker destination was followed'
  [ "$(cat "$TMP/target")" = protected ] || fail 'symlink target was overwritten'
  pass 'marker bytes and destination are fail-closed'
}

test_visible_uniquely_headed_ledger_only
test_code_and_comment_rows_cannot_fake_completion
test_duplicate_ledger_heading_is_visible
test_fenced_heading_cannot_authorize_rows
test_fence_delimiter_length_and_indentation_are_respected
test_only_contiguous_table_rows_satisfy_the_ledger
test_marker_rejects_nul_and_symlink_destination
