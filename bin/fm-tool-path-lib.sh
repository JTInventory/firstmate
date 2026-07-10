# shellcheck shell=bash
# Normalize tool lookup for interactive and clean non-interactive OpenClaw shells.
# Usage: . bin/fm-tool-path-lib.sh; fm_normalize_tool_path

fm_normalize_tool_path() {
  local home candidate current_path
  home=${FM_TOOL_PATH_HOME:-${HOME:-}}
  [ -n "$home" ] || return 0
  current_path=${PATH:-}

  # NVM global bins and user-local shims are commonly absent from non-interactive
  # SSH shells. Append them only once, preserving an explicit caller PATH first.
  for candidate in "$home"/.nvm/versions/node/*/bin "$home"/.local/bin; do
    [ -d "$candidate" ] || continue
    case ":$current_path:" in
      *":$candidate:"*) ;;
      *) current_path="$current_path${current_path:+:}$candidate" ;;
    esac
  done

  PATH=$current_path
  export PATH
}
