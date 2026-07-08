#!/usr/bin/env bash
# Guard this repo's no-mistakes PR target before a push can open a PR.
# Usage: fm-no-mistakes-pr-target-guard.sh
#
# The default is the captain fork for this Firstmate checkout:
# JTInventory/firstmate. The guard checks direct push targets, any no-mistakes
# remote target, and the no-mistakes status remote when available. It allows an
# upstream-owner origin fetch URL only in a controlled-fork checkout whose
# delivery surfaces prove the captain fork.
set -u

ALLOWED_REPO=JTInventory/firstmate
UPSTREAM_REPO=kunchenguid/firstmate
EXPECTED_REPO=${1:-${FM_FIRSTMATE_PR_TARGET_REPO:-$ALLOWED_REPO}}

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

fail_origin_fetch_proof() {
  local label=$1 url=$2 reason=$3
  printf 'blocked: %s=%s is upstream without controlled-fork proof: %s\n' \
    "$label" "$url" "$reason" >&2
  exit 1
}

fail_origin_push_hazard() {
  local label=$1 url=$2 actual=$3
  printf 'blocked: direct origin push would target upstream %s=%s (normalized %s), expected %s\n' \
    "$label" "$url" "$actual" "$EXPECTED_NORM" >&2
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

has_url() {
  local urls=$1 url
  while IFS= read -r url; do
    [ -n "$url" ] && return 0
  done <<< "$urls"
  return 1
}

EXPECTED_NORM=$(normalize_github_repo "$EXPECTED_REPO") || {
  printf 'error: invalid expected GitHub repo: %s\n' "$EXPECTED_REPO" >&2
  exit 2
}
ALLOWED_NORM=$(normalize_github_repo "$ALLOWED_REPO") || {
  printf 'error: invalid allowed GitHub repo: %s\n' "$ALLOWED_REPO" >&2
  exit 2
}
UPSTREAM_NORM=$(normalize_github_repo "$UPSTREAM_REPO") || {
  printf 'error: invalid upstream GitHub repo: %s\n' "$UPSTREAM_REPO" >&2
  exit 2
}
[ "$EXPECTED_NORM" = "$ALLOWED_NORM" ] || {
  printf 'blocked: unsupported expected PR target %s, only %s is allowed\n' "$EXPECTED_NORM" "$ALLOWED_NORM" >&2
  exit 1
}

NO_MISTAKES_GATE_VERIFIED=0
NO_MISTAKES_STATUS_VERIFIED=0

check_no_mistakes_target() {
  local label=$1 gate=$2 gate_origins gate_pushes
  [ -n "$gate" ] || return 0
  if [ -d "$gate" ]; then
    gate_origins=$(git --git-dir="$gate" config --get-all remote.origin.url 2>/dev/null || true)
    gate_pushes=$(git --git-dir="$gate" config --get-all remote.origin.pushurl 2>/dev/null || true)
    has_url "$(printf '%s\n%s\n' "$gate_origins" "$gate_pushes")" || {
      printf 'blocked: cannot verify PR target no-mistakes gate=%s because remote.origin.url and remote.origin.pushurl are missing, expected %s\n' "$gate" "$EXPECTED_NORM" >&2
      exit 1
    }
    check_urls "no-mistakes gate remote.origin.url" "$gate_origins"
    check_urls "no-mistakes gate remote.origin.pushurl" "$gate_pushes"
    NO_MISTAKES_GATE_VERIFIED=1
  else
    check_url "$label" "$gate"
    NO_MISTAKES_GATE_VERIFIED=1
  fi
}

origin_pushes_safe_for_controlled_fork() {
  local urls=$1 url actual saw_expected=0
  has_url "$urls" || {
    printf 'blocked: cannot verify direct origin push target because remote.origin.pushurl is missing, expected %s\n' "$EXPECTED_NORM" >&2
    exit 1
  }
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    actual=$(normalize_github_repo "$url") || {
      printf 'blocked: cannot verify direct origin push target %s=%s, expected %s\n' "remote.origin.pushurl" "$url" "$EXPECTED_NORM" >&2
      exit 1
    }
    case "$actual" in
      "$EXPECTED_NORM") saw_expected=1 ;;
      "$UPSTREAM_NORM") fail_origin_push_hazard "remote.origin.pushurl" "$url" "$actual" ;;
      *) fail_target "remote.origin.pushurl" "$url" "$actual" "$EXPECTED_NORM" ;;
    esac
  done <<< "$urls"
  [ "$saw_expected" -eq 1 ] || {
    printf 'blocked: direct origin push target did not prove %s\n' "$EXPECTED_NORM" >&2
    exit 1
  }
}

branch_tracks_fork_main() {
  local branch=$1 remote merge
  [ -n "$branch" ] || return 1
  remote=$(git config --get "branch.$branch.remote" 2>/dev/null || true)
  merge=$(git config --get "branch.$branch.merge" 2>/dev/null || true)
  [ "$remote" = "fork" ] && [ "$merge" = "refs/heads/main" ]
}

delivery_branch_tracks_fork_main() {
  local current default_ref default_branch
  current=$(git branch --show-current 2>/dev/null || true)
  branch_tracks_fork_main "$current" && return 0

  default_ref=$(git symbolic-ref --quiet --short refs/remotes/fork/HEAD 2>/dev/null || true)
  default_branch=${default_ref#fork/}
  [ -n "$default_branch" ] || default_branch=main
  branch_tracks_fork_main "$default_branch"
}

controlled_fork_proven() {
  local origin_url=$1 fork_fetches origin_pushes

  fork_fetches=$(git remote get-url --all fork 2>/dev/null || true)
  has_url "$fork_fetches" || fail_origin_fetch_proof "remote.origin.url" "$origin_url" "remote.fork.url is missing"
  check_urls "remote.fork.url" "$fork_fetches"

  delivery_branch_tracks_fork_main || fail_origin_fetch_proof "remote.origin.url" "$origin_url" "delivery branch does not track fork/main"

  [ "$NO_MISTAKES_STATUS_VERIFIED" -eq 1 ] || fail_origin_fetch_proof "remote.origin.url" "$origin_url" "no-mistakes status remote did not prove $EXPECTED_NORM"
  [ "$NO_MISTAKES_GATE_VERIFIED" -eq 1 ] || fail_origin_fetch_proof "remote.origin.url" "$origin_url" "no-mistakes gate remote did not prove $EXPECTED_NORM"

  origin_pushes=$(git remote get-url --push --all origin 2>/dev/null || true)
  origin_pushes_safe_for_controlled_fork "$origin_pushes"
}

gate_urls=$(git remote get-url --all no-mistakes 2>/dev/null || true)
while IFS= read -r gate; do
  check_no_mistakes_target "remote.no-mistakes.url" "$gate"
done <<< "$gate_urls"

gate_push_urls=$(git remote get-url --push --all no-mistakes 2>/dev/null || true)
while IFS= read -r gate; do
  check_no_mistakes_target "remote.no-mistakes.pushurl" "$gate"
done <<< "$gate_push_urls"

if command -v no-mistakes >/dev/null 2>&1; then
  status_out=$(no-mistakes status 2>/dev/null || true)
  status_remote=$(printf '%s\n' "$status_out" | sed -nE 's/^[[:space:]]*remote:[[:space:]]+//p' | head -n 1)
  check_url "no-mistakes status remote" "$status_remote"
  [ -z "$status_remote" ] || NO_MISTAKES_STATUS_VERIFIED=1
fi

origin_fetches=$(git remote get-url --all origin 2>/dev/null || true)
[ -n "$origin_fetches" ] || {
  printf 'blocked: cannot verify PR target because remote.origin.url is missing, expected %s\n' "$EXPECTED_NORM" >&2
  exit 1
}

origin_fetch_has_upstream=0
while IFS= read -r origin_fetch; do
  [ -n "$origin_fetch" ] || continue
  origin_actual=$(normalize_github_repo "$origin_fetch") || {
    printf 'blocked: cannot verify PR target remote.origin.url=%s, expected %s\n' "$origin_fetch" "$EXPECTED_NORM" >&2
    exit 1
  }
  case "$origin_actual" in
    "$EXPECTED_NORM") ;;
    "$UPSTREAM_NORM")
      origin_fetch_has_upstream=1
      controlled_fork_proven "$origin_fetch"
      ;;
    *) fail_target "remote.origin.url" "$origin_fetch" "$origin_actual" "$EXPECTED_NORM" ;;
  esac
done <<< "$origin_fetches"

if [ "$origin_fetch_has_upstream" -eq 0 ]; then
  origin_pushes=$(git remote get-url --push --all origin 2>/dev/null || true)
  check_urls "remote.origin.pushurl" "$origin_pushes"
fi

printf 'ok: PR target repo %s verified\n' "$EXPECTED_NORM"
