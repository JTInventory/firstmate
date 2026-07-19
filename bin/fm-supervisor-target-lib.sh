#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - shared supervisor-pane discovery.
#
# The away-mode daemon and launcher must resolve the same pane running
# firstmate. The launcher resolves it before detaching so the daemon does not
# accidentally discover its own detached process context.

# Tmux remains the default when neither runtime provides an explicit signal.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# Resolve the supervisor pane target. An explicit target wins, then the marker
# for the selected backend, then the legacy tmux fallback.
discover_supervisor_target() {
  local backend
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  backend=$(discover_supervisor_backend) || true
  case "$backend" in
    herdr)
      if [ -n "${HERDR_PANE_ID:-}" ]; then
        printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
        return 0
      fi
      printf '%s\n' 'error: supervisor backend herdr needs HERDR_PANE_ID or FM_SUPERVISOR_TARGET' >&2
      return 1
      ;;
    tmux)
      if [ -n "${TMUX_PANE:-}" ]; then
        printf '%s' "$TMUX_PANE"
        return 0
      fi
      printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
      return 1
      ;;
    *)
      printf 'error: unsupported supervisor backend: %s\n' "$backend" >&2
      return 1
      ;;
  esac
}

# Resolve the backend used to address the supervisor pane independently from
# the target string. Explicit configuration wins; runtime markers follow the
# same tmux-first precedence as fm-backend.sh. The fallback is tmux.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
