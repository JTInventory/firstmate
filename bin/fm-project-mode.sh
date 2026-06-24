#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and optional no-mistakes gate flag
# from the data/projects.md registry.
# Prints three words to stdout: "<mode> <yolo> <nm_gate>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo/nm_gate are on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                         -> no-mistakes off off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                 -> <mode> off off
#   - <name> [<mode> +yolo] - <desc> (added <date>)           -> <mode> on off
#   - <name> [<mode> +nm-gate] - <desc> (added <date>)        -> <mode> off on
#   - <name> [<mode> +yolo +nm-gate] - <desc> (added <date>)  -> <mode> on on
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> firstmate review -> captain approve -> local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
# nm_gate (orthogonal) = when on, no-mistakes is available as a Firstmate-owned
#   post-scope delivery gate. It is not the base delivery mode and does not apply
#   to scout/report tasks.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off off"
# and warns to stderr, so a typo never silently drops the default gate.
# Usage: fm-project-mode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off off" >&2
  echo "no-mistakes off off"
  exit 0
fi

# awk emits "<mode> <yolo> <nm_gate>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; nm_gate="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] != "+nm-gate") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
      for (j=1; j<=k; j++) if (a[j]=="+nm-gate") nm_gate="on";
    }
    print mode, yolo, nm_gate; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off off" >&2
  echo "no-mistakes off off"
  exit 0
fi

set -- $parsed
mode=${1:-no-mistakes}
yolo=${2:-off}
nm_gate=${3:-off}
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off off" >&2; mode=no-mistakes; yolo=off; nm_gate=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$nm_gate" in on|off) ;; *) nm_gate=off ;; esac
echo "$mode $yolo $nm_gate"
