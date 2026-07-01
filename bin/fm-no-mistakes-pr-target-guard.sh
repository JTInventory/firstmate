#!/usr/bin/env bash
# Guard this repo's no-mistakes PR target before a push can open a PR.
# Usage: fm-no-mistakes-pr-target-guard.sh [OWNER/REPO]
#
# The default is the captain fork for this Firstmate checkout:
# JTInventory/firstmate. The guard checks the visible git origin, its push URLs,
# any no-mistakes remote target, and the no-mistakes status remote when
# available. It exits non-zero before the no-mistakes push/PR step if any path
# points at the upstream owner repo.
set -u

EXPECTED_REPO=${1:-${FM_FIRSTMATE_PR_TARGET_REPO:-JTInventory/firstmate}}

normalize_github_repo() {
  local raw=$1 path
  case "$raw" in
    https://github.com/*) path=${raw#https://github.com/} ;;
    http://github.com/*) path=${raw#http://github.com/} ;;
    git@github.com:*) path=${raw#git@github.com:} ;;
    ssh://git@github.com/*) path=${raw#ssh://git@github.com/} ;;
    github.com/*) path=${raw#github.com/} ;;
    */*) path=$raw ;;
    *) return 1 ;;
  esac
  path=${path%%\#*}
  path=${path%%\?*}
  path=${path%/}
  path=${path%.git}
  case "$path" in
    */*) printf '%s\n' "$path" | tr '[:upper:]' '[:lower:]' ;;
    *) return 1 ;;
  esac
}

fail_target() {
  local label=$1 url=$2 actual=$3 expected=$4
  printf 'blocked: would target upstream %s=%s (normalized %s), expected %s\n' \
    "$label" "$url" "$actual" "$expected" >&2
  exit 1
}

check_url() {
  local label=$1 url=$2 actual
  [ -n "$url" ] || return 0
  actual=$(normalize_github_repo "$url") || {
    printf 'blocked: cannot verify PR target %s=%s, expected %s\n' "$label" "$url" "$EXPECTED_NORM" >&2
    exit 1
  }
  [ "$actual" = "$EXPECTED_NORM" ] || fail_target "$label" "$url" "$actual" "$EXPECTED_NORM"
}

check_urls() {
  local label=$1 urls=$2 url
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    check_url "$label" "$url"
  done <<< "$urls"
}

EXPECTED_NORM=$(normalize_github_repo "$EXPECTED_REPO") || {
  printf 'error: invalid expected GitHub repo: %s\n' "$EXPECTED_REPO" >&2
  exit 2
}

origin_fetches=$(git remote get-url --all origin 2>/dev/null || true)
[ -n "$origin_fetches" ] || {
  printf 'blocked: cannot verify PR target because remote.origin.url is missing, expected %s\n' "$EXPECTED_NORM" >&2
  exit 1
}
check_urls "remote.origin.url" "$origin_fetches"

origin_pushes=$(git remote get-url --push --all origin 2>/dev/null || true)
check_urls "remote.origin.pushurl" "$origin_pushes"

gate_urls=$(git remote get-url --all no-mistakes 2>/dev/null || true)
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  if [ -d "$gate" ]; then
    gate_origins=$(git --git-dir="$gate" config --get-all remote.origin.url 2>/dev/null || true)
    check_urls "no-mistakes gate remote.origin.url" "$gate_origins"
    gate_pushes=$(git --git-dir="$gate" config --get-all remote.origin.pushurl 2>/dev/null || true)
    check_urls "no-mistakes gate remote.origin.pushurl" "$gate_pushes"
  else
    check_url "remote.no-mistakes.url" "$gate"
  fi
done <<< "$gate_urls"

if command -v no-mistakes >/dev/null 2>&1; then
  status_out=$(no-mistakes status 2>/dev/null || true)
  status_remote=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*remote:[[:space:]]+//p' | head -n 1)
  check_url "no-mistakes status remote" "$status_remote"
fi

printf 'ok: PR target repo %s verified\n' "$EXPECTED_NORM"
