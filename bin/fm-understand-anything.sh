#!/usr/bin/env bash
# Firstmate wrapper for Understand Anything orientation helpers.
#
# This helper protects firstmate workers from known dashboard caveats: stale PID
# files, token leaks in status output, and dashboard cache writes under a
# read-only plugin install root.
set -eu

redact_tokens() {
  sed -E \
    -e 's/([?&](token|access_token)=)[^&#[:space:]]+/\1<redacted>/g' \
    -e 's/([[:space:]](token|access_token)=)[^[:space:]]+/\1<redacted>/g'
}

usage() {
  cat >&2 <<'EOF'
usage: fm-understand-anything.sh dashboard-status [--pid-file path] [--url-file path] [--identity-file path] [--evidence-dir path] [--dashboard-dir path]
       fm-understand-anything.sh dashboard-start [--foreground] [--cache-dir path] [--log-file path] [--pid-file path] [--url-file path] [--identity-file path] [--project-dir path] [--dashboard-dir path] [-- command ...]
       fm-understand-anything.sh graph-status --metadata-file path
EOF
}

safe_cache_env() {
  cache_dir=$1
  mkdir -p \
    "$cache_dir/tmp" \
    "$cache_dir/xdg-cache" \
    "$cache_dir/npm-cache" \
    "$cache_dir/vite-cache" \
    "$cache_dir/vite-temp"
  export TMPDIR="$cache_dir/tmp"
  export XDG_CACHE_HOME="$cache_dir/xdg-cache"
  export npm_config_cache="$cache_dir/npm-cache"
  export VITE_CACHE_DIR="$cache_dir/vite-cache"
  export VITE_TEMP_DIR="$cache_dir/vite-temp"
}

find_dashboard_dir() {
  for candidate in \
    "${FM_UNDERSTAND_DASHBOARD_DIR:-}" \
    "${CLAUDE_PLUGIN_ROOT:-}/packages/dashboard" \
    "$HOME/.understand-anything-plugin/packages/dashboard" \
    "$HOME/.codex/understand-anything/understand-anything-plugin/packages/dashboard" \
    "$HOME/.opencode/understand-anything/understand-anything-plugin/packages/dashboard" \
    "$HOME/.pi/understand-anything/understand-anything-plugin/packages/dashboard" \
    "$HOME/understand-anything/understand-anything-plugin/packages/dashboard" \
    "$HOME/.understand-anything/repo/understand-anything-plugin/packages/dashboard"; do
    [ -n "$candidate" ] && [ -d "$candidate" ] && {
      printf '%s\n' "$candidate"
      return 0
    }
  done
  return 1
}

save_dashboard_url_from_log() {
  log_file=$1
  url_file=$2
  [ -f "$log_file" ] || return 0
  raw_url=$(grep -Eo 'https?://[^[:space:]]+[?&]token=[^[:space:]]+' "$log_file" 2>/dev/null | tail -n 1 || true)
  [ -n "$raw_url" ] || return 0
  [ -n "$url_file" ] || return 0
  mkdir -p "$(dirname "$url_file")"
  printf '%s\n' "$raw_url" > "$url_file"
}

process_identity() {
  pid=$1
  ps -p "$pid" -o lstart= -o command= 2>/dev/null | redact_tokens | head -n 1
}

redacted_dashboard_url_from_log() {
  log_file=$1
  [ -f "$log_file" ] || return 0
  grep -Eo 'https?://[^[:space:]]+[?&]token=[^[:space:]]+' "$log_file" 2>/dev/null \
    | tail -n 1 \
    | redact_tokens
}

wait_for_dashboard_url() {
  log_file=$1
  url_file=$2
  wait_seconds=${FM_UNDERSTAND_DASHBOARD_URL_WAIT_SECONDS:-2}
  end=$(( $(date +%s) + wait_seconds ))
  while :; do
    current_url=$(grep -Eo 'https?://[^[:space:]]+[?&]token=[^[:space:]]+' "$log_file" 2>/dev/null | tail -n 1 || true)
    if [ -n "$current_url" ]; then
      mkdir -p "$(dirname "$url_file")"
      printf '%s\n' "$current_url" > "$url_file"
      return 0
    fi
    [ "$(date +%s)" -ge "$end" ] && return 1
    sleep 0.1
  done
}

write_vite_config_wrapper() {
  dashboard_dir=$1
  cache_dir=$2
  wrapper=$3
  mkdir -p "$(dirname "$wrapper")"
  python3 - "$dashboard_dir" "$cache_dir/vite-cache" "$wrapper" <<'PY'
import json
import pathlib
import sys

dashboard_dir = pathlib.Path(sys.argv[1]).resolve()
cache_dir = pathlib.Path(sys.argv[2]).resolve()
wrapper = pathlib.Path(sys.argv[3])
base = None
for name in ("vite.config.mjs", "vite.config.js", "vite.config.ts"):
    candidate = dashboard_dir / name
    if candidate.exists():
        base = candidate
        break

cache_json = json.dumps(str(cache_dir))
if base is None:
    body = f"export default {{ cacheDir: {cache_json} }};\n"
else:
    base_url = json.dumps(base.as_uri())
    body = f"""import baseConfig from {base_url};

export default async function firstmateUnderstandDashboardConfig(env) {{
  const resolved = typeof baseConfig === "function" ? await baseConfig(env) : await baseConfig;
  return {{ ...(resolved || {{}}), cacheDir: {cache_json} }};
}}
"""
wrapper.write_text(body, encoding="utf-8")
PY
}

stop_dashboard_child() {
  child_pid=$1
  kill "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
}

cmd=${1:-}
if [ $# -gt 0 ]; then
  shift
fi

case "$cmd" in
  dashboard-status)
    PID_FILE=${FM_UNDERSTAND_DASHBOARD_PID_FILE:-}
    URL_FILE=${FM_UNDERSTAND_DASHBOARD_URL_FILE:-}
    EVIDENCE_DIR=${FM_UNDERSTAND_EVIDENCE_DIR:-}
    DASHBOARD_DIR=${FM_UNDERSTAND_DASHBOARD_DIR:-}
    IDENTITY_FILE=${FM_UNDERSTAND_DASHBOARD_IDENTITY_FILE:-}
    while [ $# -gt 0 ]; do
      case "$1" in
        --pid-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          PID_FILE=$2
          shift 2
          ;;
        --url-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          URL_FILE=$2
          shift 2
          ;;
        --identity-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          IDENTITY_FILE=$2
          shift 2
          ;;
        --evidence-dir)
          [ $# -ge 2 ] || { usage; exit 2; }
          EVIDENCE_DIR=$2
          shift 2
          ;;
        --dashboard-dir)
          [ $# -ge 2 ] || { usage; exit 2; }
          DASHBOARD_DIR=$2
          shift 2
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    done
    [ -n "$PID_FILE" ] || PID_FILE="${TMPDIR:-/tmp}/fm-understand-dashboard.pid"
    [ -n "$URL_FILE" ] || URL_FILE="${TMPDIR:-/tmp}/fm-understand-dashboard.url"
    [ -n "$EVIDENCE_DIR" ] || EVIDENCE_DIR="${TMPDIR:-/tmp}/fm-understand-evidence"
    [ -n "$IDENTITY_FILE" ] || IDENTITY_FILE="$PID_FILE.identity"

    url=
    [ -f "$URL_FILE" ] && url=$(redact_tokens < "$URL_FILE" | head -n 1)

    if [ ! -f "$PID_FILE" ]; then
      printf '%s\n' 'dashboard_status=stopped'
      [ -n "$url" ] && printf 'dashboard_url=%s\n' "$url"
      exit 1
    fi

    pid=$(head -n 1 "$PID_FILE" | tr -d '[:space:]')
    case "$pid" in
      ''|*[!0-9]*)
        printf '%s\n' 'dashboard_status=stale'
        printf 'stale_pid=%s\n' "$(redact_tokens < "$PID_FILE" | head -n 1)"
        [ -n "$url" ] && printf 'dashboard_url=%s\n' "$url"
        exit 1
        ;;
    esac

    process=$(ps -p "$pid" -o command= 2>/dev/null || true)
    process_redacted=$(printf '%s\n' "$process" | redact_tokens | head -n 1)
    process_matches=0
    if [ -z "$DASHBOARD_DIR" ]; then
      DASHBOARD_DIR=$(find_dashboard_dir 2>/dev/null || true)
    fi
    if [ -n "$DASHBOARD_DIR" ] && [ -e "/proc/$pid/cwd" ]; then
      expected_cwd=
      if [ -d "$DASHBOARD_DIR" ]; then
        expected_cwd=$(cd "$DASHBOARD_DIR" 2>/dev/null && pwd -P) || expected_cwd=
      fi
      actual_cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
      current_identity=$(process_identity "$pid")
      expected_identity=
      [ -f "$IDENTITY_FILE" ] && expected_identity=$(head -n 1 "$IDENTITY_FILE")
      if [ -n "$expected_cwd" ] && [ "$actual_cwd" = "$expected_cwd" ] \
        && [ -n "$expected_identity" ] && [ "$current_identity" = "$expected_identity" ]; then
        process_matches=1
      fi
    fi
    if [ "$process_matches" = 1 ]; then
      printf '%s\n' 'dashboard_status=running'
      printf 'pid=%s\n' "$pid"
      [ -n "$url" ] && printf 'dashboard_url=%s\n' "$url"
      exit 0
    fi

    mkdir -p "$EVIDENCE_DIR"
    evidence_file="$EVIDENCE_DIR/stale-dashboard-pid-$pid.txt"
    {
      printf 'stale_pid=%s\n' "$pid"
      printf 'stale_process=%s\n' "$process_redacted"
      [ -n "$url" ] && printf 'dashboard_url=%s\n' "$url"
    } > "$evidence_file"
    printf '%s\n' 'dashboard_status=stale'
    printf 'stale_pid=%s\n' "$pid"
    printf 'stale_process=%s\n' "$process_redacted"
    [ -n "$url" ] && printf 'dashboard_url=%s\n' "$url"
    printf 'stale_pid_evidence=%s\n' "$evidence_file"
    exit 1
    ;;
  dashboard-start)
    FOREGROUND=0
    CACHE_DIR=${FM_UNDERSTAND_CACHE_DIR:-"${TMPDIR:-/tmp}/fm-understand-cache"}
    LOG_FILE=${FM_UNDERSTAND_DASHBOARD_LOG_FILE:-"${TMPDIR:-/tmp}/fm-understand-dashboard.log"}
    PID_FILE=${FM_UNDERSTAND_DASHBOARD_PID_FILE:-"${TMPDIR:-/tmp}/fm-understand-dashboard.pid"}
    URL_FILE=${FM_UNDERSTAND_DASHBOARD_URL_FILE:-"${TMPDIR:-/tmp}/fm-understand-dashboard.url"}
    IDENTITY_FILE=${FM_UNDERSTAND_DASHBOARD_IDENTITY_FILE:-}
    PROJECT_DIR=${FM_UNDERSTAND_PROJECT_DIR:-$PWD}
    DASHBOARD_DIR=${FM_UNDERSTAND_DASHBOARD_DIR:-}
    COMMAND=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --foreground)
          FOREGROUND=1
          shift
          ;;
        --cache-dir)
          [ $# -ge 2 ] || { usage; exit 2; }
          CACHE_DIR=$2
          shift 2
          ;;
        --log-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          LOG_FILE=$2
          shift 2
          ;;
        --pid-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          PID_FILE=$2
          shift 2
          ;;
        --url-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          URL_FILE=$2
          shift 2
          ;;
        --identity-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          IDENTITY_FILE=$2
          shift 2
          ;;
        --project-dir)
          [ $# -ge 2 ] || { usage; exit 2; }
          PROJECT_DIR=$2
          shift 2
          ;;
        --dashboard-dir)
          [ $# -ge 2 ] || { usage; exit 2; }
          DASHBOARD_DIR=$2
          shift 2
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        --)
          shift
          while [ $# -gt 0 ]; do
            COMMAND+=("$1")
            shift
          done
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    done

    safe_cache_env "$CACHE_DIR"
    [ -n "$IDENTITY_FILE" ] || IDENTITY_FILE="$PID_FILE.identity"
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")" "$(dirname "$URL_FILE")" "$(dirname "$IDENTITY_FILE")"
    : > "$LOG_FILE"
    rm -f "$URL_FILE" "$IDENTITY_FILE"
    if [ "${#COMMAND[@]}" -eq 0 ]; then
      if [ -z "$DASHBOARD_DIR" ]; then
        DASHBOARD_DIR=$(find_dashboard_dir) || {
          printf '%s\n' 'dashboard_start=blocked'
          printf '%s\n' 'reason=understand_dashboard_dir_not_found'
          exit 1
        }
      fi
      VITE_CONFIG_WRAPPER="$CACHE_DIR/vite.config.mjs"
      write_vite_config_wrapper "$DASHBOARD_DIR" "$CACHE_DIR" "$VITE_CONFIG_WRAPPER"
      COMMAND=(npx vite --host 127.0.0.1 --config "$VITE_CONFIG_WRAPPER")
    fi
    [ -n "$DASHBOARD_DIR" ] || DASHBOARD_DIR=$PWD

    if [ "$FOREGROUND" = 1 ]; then
      printf '%s\n' 'dashboard_start=foreground'
      set +e
      (
        cd "$DASHBOARD_DIR" || exit 1
        GRAPH_DIR=$PROJECT_DIR "${COMMAND[@]}"
      ) 2>&1 | tee -a "$LOG_FILE" | redact_tokens
      rc=${PIPESTATUS[0]}
      set -e
      save_dashboard_url_from_log "$LOG_FILE" "$URL_FILE"
      exit "$rc"
    fi

    (
      cd "$DASHBOARD_DIR" || exit 1
      GRAPH_DIR=$PROJECT_DIR "${COMMAND[@]}"
    ) >> "$LOG_FILE" 2>&1 &
    dashboard_pid=$!
    printf '%s\n' "$dashboard_pid" > "$PID_FILE"
    process_identity "$dashboard_pid" > "$IDENTITY_FILE"
    printf '%s\n' 'dashboard_start=starting'
    printf 'pid=%s\n' "$dashboard_pid"
    printf 'log_file=%s\n' "$LOG_FILE"
    printf 'cache_dir=%s\n' "$CACHE_DIR"
    printf '%s\n' 'token_policy=redacted_in_status_output'
    redacted_url=
    if wait_for_dashboard_url "$LOG_FILE" "$URL_FILE"; then
      redacted_url=$(redacted_dashboard_url_from_log "$LOG_FILE" || true)
    else
      stop_dashboard_child "$dashboard_pid"
      rm -f "$PID_FILE" "$IDENTITY_FILE" "$URL_FILE"
      printf '%s\n' 'dashboard_start=failed'
      printf '%s\n' 'reason=dashboard_url_not_confirmed'
      printf 'log_file=%s\n' "$LOG_FILE"
      exit 1
    fi
    if ! kill -0 "$dashboard_pid" 2>/dev/null; then
      stop_dashboard_child "$dashboard_pid"
      rm -f "$PID_FILE" "$IDENTITY_FILE" "$URL_FILE"
      printf '%s\n' 'dashboard_start=failed'
      printf '%s\n' 'reason=dashboard_process_exited'
      printf 'log_file=%s\n' "$LOG_FILE"
      exit 1
    fi
    printf '%s\n' 'dashboard_start=background'
    [ -n "$redacted_url" ] && printf 'dashboard_url=%s\n' "$redacted_url"
    exit 0
    ;;
  graph-status)
    METADATA_FILE=
    while [ $# -gt 0 ]; do
      case "$1" in
        --metadata-file)
          [ $# -ge 2 ] || { usage; exit 2; }
          METADATA_FILE=$2
          shift 2
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    done
    [ -n "$METADATA_FILE" ] || { usage; exit 2; }
    [ -f "$METADATA_FILE" ] || {
      printf '%s\n' 'graph_status=missing_metadata'
      exit 1
    }
    python3 - "$METADATA_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
try:
    data = json.loads(text)
except json.JSONDecodeError:
    data = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()

def get(*names):
    for name in names:
        cur = data
        ok = True
        for part in name.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                ok = False
                break
        if ok and cur not in (None, ""):
            return cur
    return ""

status = get("status", "graph.status") or "unknown"
nodes = get("nodes", "nodeCount", "graph.nodes", "graph.nodeCount")
edges = get("edges", "edgeCount", "graph.edges", "graph.edgeCount")
analyzed = get("analyzedFiles", "analyzed_files", "filesAnalyzed", "graph.analyzedFiles")
head = get("head", "gitCommitHash", "gitHead", "git_head", "graphHead", "packetHead")
root = get("root", "projectRoot", "project_path", "workspace", "repositoryPath")
if root == "":
    resolved = path.expanduser().resolve(strict=False)
    if resolved.parent.name == ".understand-anything":
        root = str(resolved.parent.parent)

def emit(key, value):
    if value != "":
        print(f"{key}={value}")

emit("graph_status", status)
emit("nodes", nodes)
emit("edges", edges)
emit("analyzed_files", analyzed)
emit("graph_head", head)
emit("graph_root", root)
if str(root) == "/root/.openclaw":
    print("orientation_only=true")
    print("workers_must_prove_own_worktree_head=true")
    print("caveat=graph_or_packet_head_is_orientation_only_for_canonical_openclaw; prove_branch_and_head_in_the_worker_worktree_before_using_it_as_current_truth")
PY
    ;;
  --help|-h|'')
    usage
    [ -n "$cmd" ] || exit 2
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
