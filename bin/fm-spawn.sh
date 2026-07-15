#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse worktree, or a secondmate in
# its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. It also reads fm-route.sh and fills any
#   omitted --model/--effort axes from the route when the active crew harness still
#   matches the routed harness. When config/crew-dispatch.json exists,
#   crewmate/scout spawns require an explicit harness so firstmate cannot silently
#   skip dispatch profile consultation. A --secondmate spawn is exempt and resolves
#   the SECONDMATE harness (config/secondmate-harness -> config/crew-harness -> own),
#   then fills any omitted --model/--effort axes from primary-local
#   config/secondmate-profile.json.
#   That keeps the secondmate-vs-crewmate launch profile DURABLE across every
#   respawn (recovery, /updatefirstmate, restart). A bare adapter name
#   (claude|codex|opencode|pi|grok) overrides the harness for this spawn (either
#   kind). A non-flag string containing whitespace is treated as a RAW launch
#   command - the escape hatch for verifying new adapters.
#   A --secondmate spawn also propagates the primary's declared inheritable config
#   into the secondmate home's config/, so the secondmate's OWN crewmates,
#   dispatch profiles, and backlog backend inherit the primary's settings
#   (fm-config-inherit-lib.sh).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Matching JT Control Room ship spawns for .openclaw or jt-control-room append a
#   JT PR Intake Governor block to direct-PR/no-mistakes briefs before launch.
#   Eligible projects may also receive an optional codebase-memory-mcp (CBM)
#   orientation block and CBM env exports at launch (soft dependency; see
#   bin/fm-cbm-lib.sh). Missing CBM never blocks spawn.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch after treehouse get unless the resolved pane
#   path is a real git worktree root of the TARGET project (same git common dir,
#   HEAD present in the target repo) distinct from the primary project checkout.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<session:window> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tool-path-lib.sh
. "$SCRIPT_DIR/fm-tool-path-lib.sh"
fm_normalize_tool_path
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-cbm-lib.sh
. "$SCRIPT_DIR/fm-cbm-lib.sh"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" "${shared_args[@]}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]:-}
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "error: unsafe task id: $ID" >&2; exit 2 ;;
esac
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

HARNESS=
LAUNCH=
ROUTE_PROFILE=manual
ROUTE_HARNESS=
ROUTE_MODEL=default
ROUTE_EFFORT=default
ROUTE_REASON=
ROUTE_OVERRIDE=none
ROUTE_RISK_FLAGS=none
case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ROUTE_HARNESS=${HARNESS:-raw}
    ROUTE_REASON="raw launch command selected for adapter verification"
    ROUTE_OVERRIDE=raw-launch
    ;;
  '')
    # Deferred until BRIEF/PROJ_ABS are known, so the route can read task text.
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ROUTE_HARNESS=$HARNESS
    ROUTE_REASON="manual harness override selected $HARNESS"
    ROUTE_OVERRIDE=manual-harness
    ;;
esac

parse_route_output() {
  local line key value
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || continue
    case "$key" in
      profile) ROUTE_PROFILE=$value ;;
      harness) ROUTE_HARNESS=$value ;;
      model) ROUTE_MODEL=$value ;;
      effort) ROUTE_EFFORT=$value ;;
      reason) ROUTE_REASON=$value ;;
      override) ROUTE_OVERRIDE=$value ;;
      risk_flags) ROUTE_RISK_FLAGS=$value ;;
    esac
  done
}

apply_secondmate_profile_config() {
  local file err model effort
  [ "$KIND" = secondmate ] || return 0
  file="$CONFIG/secondmate-profile.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: config/secondmate-profile.json requires jq to read model/effort defaults" >&2
    exit 1
  fi
  if ! jq . "$file" >/dev/null 2>&1; then
    echo "error: invalid config/secondmate-profile.json - malformed JSON" >&2
    exit 1
  fi
  err=$(jq -r '
    if type != "object" then "top-level value must be an object"
    elif has("model") and ((.model | type) != "string" or (.model | length) == 0) then "model must be a non-empty string"
    elif has("effort") and ((.effort | type) != "string") then "effort must be a string"
    elif has("effort") and (.effort as $e | (["default","low","medium","high","xhigh","max"] | index($e) | not)) then "invalid effort: " + (.effort | tostring)
    else empty
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "error: invalid config/secondmate-profile.json - $err" >&2
    exit 1
  fi
  if [ "$MODEL_SET" -eq 0 ]; then
    model=$(jq -r '.model // "default"' "$file")
    MODEL=$model
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    effort=$(jq -r '.effort // "default"' "$file")
    EFFORT=$effort
  fi
}

append_route_block() {
  [ "$KIND" != secondmate ] || return 0
  grep -qxF '<!-- firstmate-route -->' "$BRIEF" 2>/dev/null && return 0
  cat >> "$BRIEF" <<EOF

<!-- firstmate-route -->
# Route

route: $ROUTE_PROFILE because $ROUTE_REASON
Harness: $ROUTE_HARNESS
Model: $ROUTE_MODEL
Reasoning effort: $ROUTE_EFFORT
Override: $ROUTE_OVERRIDE
Risk flags: $ROUTE_RISK_FLAGS
Do not downgrade this route without an explicit firstmate override.
EOF
}

is_jt_pr_intake_context() {
  local lower_id lower_project
  lower_project=$(basename "$PROJ_ABS" | tr '[:upper:]' '[:lower:]')
  case "$lower_project" in
    .openclaw|jt-control-room) ;;
    *) return 1 ;;
  esac

  lower_id=$(printf '%s' "$ID" | tr '[:upper:]' '[:lower:]')
  case "$lower_id" in
    jt-*|*jt-control-room*|*replenishment*|*donnees*|*automation*) return 0 ;;
  esac

  if grep -Eiq 'jt control room|jt-control-room|control room|operator|routes?|replenishment|donnees|trust cockpit|automation cockpit|ppc|sellersnap|runtime|served data|refresh:doctor|replenishment-workflow-board|4187' "$BRIEF" 2>/dev/null; then
    return 0
  fi
  return 1
}

append_jt_pr_intake_governor() {
  [ "$KIND" = ship ] || return 0
  case "$MODE" in
    direct-PR|no-mistakes) ;;
    *) return 0 ;;
  esac
  grep -qxF '<!-- firstmate:jt-pr-intake-governor:start -->' "$BRIEF" 2>/dev/null && return 0
  is_jt_pr_intake_context || return 0
  cat >> "$BRIEF" <<'EOF'

<!-- firstmate:jt-pr-intake-governor:start -->
# JT PR Intake Governor

Before implementation, write a short intake note in your working notes or report, and carry the same answers into the PR body. Answer every field:

- Problem category: Replenishment/supplier proof, Automation/PPC proof, runtime/served data, operator UX/routes, Donnees/trust cockpit, tests/contracts, docs/knowledge, OpenClaw/Firstmate tooling, or other.
- Priority (P0-P4): classify operator impact, data-risk, money-risk, and whether the problem blocks a daily decision.
- Affected surface: page, endpoint, script, source file, generated artifact, or runtime service.
- Authoritative source: exact repo file, live endpoint, report, merged PR, source CSV/export, or runtime command that proves the truth.
- Expected proof: what the operator should see after the fix, including safe_to_buy/external_action_authorized when relevant.
- Verification gate: focused test, npm script, Python test, browser/live JSON proof, or CI check required before PR.
- Duplicate/superseded check: name any earlier PR/report/problem this replaces, confirms, or intentionally leaves alone.
- Runtime data policy: source-only PR, generated-data PR, runtime-local adoption, or no runtime mutation.

If any field cannot be answered from the brief and live/repo evidence, append `needs-decision:` or `blocked:` and stop. Do not open a PR until this intake is answered.
<!-- firstmate:jt-pr-intake-governor:end -->
EOF
}

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # Grok 0.2.101 accepts only low|medium|high for --reasoning-effort;
      # xhigh and max are recorded in meta but omitted from the launch command.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # pi accepts --thinking low|medium|high|xhigh. It warns and ignores max, so
      # omit max rather than passing a flag the installed CLI will reject as invalid.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  # Inheritable-config propagation: push the primary's declared LOCAL config into
  # this secondmate home's config/, so the secondmate's OWN crewmates, dispatch
  # profiles, and backlog backend inherit the primary's settings. config/ is
  # gitignored, so this is a
  # separate copy from the local-HEAD fast-forward above;
  # primary-authoritative and re-pushed on every convergence. config/secondmate-harness
  # and config/secondmate-profile.json are primary launch knobs and are deliberately
  # NOT in the inheritable set
  # (fm-config-inherit-lib.sh). A primary with no inheritable config set is a no-op.
  propagate_inheritable_config "$CONFIG" "$PROJ_ABS/config" \
    || echo "warning: secondmate $ID config inheritance failed for $PROJ_ABS/config" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

if [ -z "$ARG3" ]; then
  if [ "$KIND" = secondmate ]; then
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
    ROUTE_HARNESS=$HARNESS
    ROUTE_REASON="secondmate launch uses config/secondmate-harness with config/crew-harness fallback"
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from config/secondmate-harness/config/crew-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
  else
    if [ -f "$CONFIG/crew-dispatch.json" ]; then
      echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules, with optional --model/--effort axes (the consultation backstop, so the rules are never silently skipped)." >&2
      exit 1
    fi
    route_out=
    if ! route_out=$("$FM_ROOT/bin/fm-route.sh" "$ID" "$PROJ_ABS" --kind "$KIND" --task-file "$BRIEF" 2>&1); then
      printf '%s\n' "$route_out" >&2
      exit 1
    fi
    parse_route_output <<EOF
$route_out
EOF
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
    if [ "$HARNESS" != "$ROUTE_HARNESS" ]; then
      ROUTE_OVERRIDE=config-harness
      ROUTE_REASON="$ROUTE_REASON; launch harness overridden by config/crew-harness: $HARNESS"
    else
      [ "$MODEL_SET" -eq 1 ] || MODEL=$ROUTE_MODEL
      [ "$EFFORT_SET" -eq 1 ] || EFFORT=$ROUTE_EFFORT
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from route profile '$ROUTE_PROFILE'); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
  fi
fi

if [ "$KIND" = secondmate ]; then
  apply_secondmate_profile_config
  ROUTE_MODEL=${MODEL:-default}
  ROUTE_EFFORT=${EFFORT:-default}
fi

# Same session when firstmate already runs inside tmux; dedicated session otherwise.
if [ -n "${TMUX:-}" ]; then
  SES=$(tmux display-message -p '#S')
else
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
  SES=firstmate
fi

W="fm-$ID"
T="$SES:$W"
if tmux list-windows -t "$SES" -F '#{window_name}' | grep -qx "$W"; then
  echo "error: window $T already exists" >&2
  exit 1
fi

cleanup_spawn_window() {
  tmux kill-window -t "$1" >/dev/null 2>&1 || true
}

cleanup_unidentified_spawn_window() {
  local window_ids_after window_id candidate='' candidate_count=0
  window_ids_after=$(tmux list-windows -t "$SES" -F '#{window_id}' 2>/dev/null || true)
  while IFS= read -r window_id; do
    [ -n "$window_id" ] || continue
    if ! grep -qxF "$window_id" <<<"$WINDOW_IDS_BEFORE"; then
      candidate=$window_id
      candidate_count=$((candidate_count + 1))
    fi
  done <<<"$window_ids_after"
  [ "$candidate_count" -eq 1 ] && cleanup_spawn_window "$candidate"
}

# Spawn-time isolation guard: the resolved pane path must be the root of a real
# worktree OF THE TARGET project. A different git root is not enough: a raced
# treehouse shell can briefly land in an unrelated repository, which would put
# an autonomous agent in the wrong project. Compare physical git common dirs,
# then confirm the candidate HEAD exists in the target repo.
real_path_or_raw() {  # <path>
  if [ -n "$1" ] && [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

git_common_dir_real() {  # <dir> -> physical absolute common dir, or fail
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *) common="$dir/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P)
}

PROJ_ABS_REAL=$(real_path_or_raw "$PROJ_ABS")
PROJ_GIT_COMMON_REAL=
PROJ_GIT_COMMON_RESOLVED=0
proj_git_common_real() {
  if [ "$PROJ_GIT_COMMON_RESOLVED" -eq 0 ]; then
    PROJ_GIT_COMMON_REAL=$(git_common_dir_real "$PROJ_ABS" || true)
    PROJ_GIT_COMMON_RESOLVED=1
  fi
  printf '%s\n' "$PROJ_GIT_COMMON_REAL"
}

SPAWN_WT_FAIL=
spawn_worktree_check() {  # <candidate>; sets SPAWN_WT_FAIL (empty = valid)
  local candidate=$1 candidate_real worktree_root worktree_root_real
  local project_common worktree_common worktree_head
  SPAWN_WT_FAIL=
  candidate_real=$(real_path_or_raw "$candidate")
  worktree_root=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || true)
  worktree_root_real=$(real_path_or_raw "$worktree_root")
  if [ -z "$candidate_real" ] || [ -z "$worktree_root_real" ] \
    || [ "$candidate_real" != "$worktree_root_real" ]; then
    SPAWN_WT_FAIL="resolved path is not the root of a git worktree (worktree root '${worktree_root:-none}')"
    return 0
  fi
  if [ "$candidate_real" = "$PROJ_ABS_REAL" ]; then
    SPAWN_WT_FAIL="resolved path is the primary project checkout itself"
    return 0
  fi
  project_common=$(proj_git_common_real)
  if [ -z "$project_common" ]; then
    SPAWN_WT_FAIL="cannot resolve the target project's git common dir from '$PROJ_ABS'"
    return 0
  fi
  worktree_common=$(git_common_dir_real "$candidate_real" || true)
  if [ "$worktree_common" != "$project_common" ]; then
    SPAWN_WT_FAIL="resolved worktree belongs to a DIFFERENT repo (its git common dir is '${worktree_common:-unresolvable}', expected '$project_common')"
    return 0
  fi
  worktree_head=$(git -C "$candidate_real" rev-parse HEAD 2>/dev/null || true)
  if [ -z "$worktree_head" ] \
    || ! git -C "$PROJ_ABS" cat-file -e "$worktree_head^{commit}" 2>/dev/null; then
    SPAWN_WT_FAIL="worktree HEAD '${worktree_head:-unresolvable}' does not exist in the target repo"
  fi
}

worktree_of_target_repo() {  # <candidate> -> 0 iff fully valid
  spawn_worktree_check "$1"
  [ -z "$SPAWN_WT_FAIL" ]
}

validate_spawn_worktree() {  # <source> <inspect-target>
  spawn_worktree_check "$WT"
  [ -z "$SPAWN_WT_FAIL" ] || {
    {
      echo "error: $1 did not yield an isolated worktree of the target project; refusing to launch. $SPAWN_WT_FAIL"
      echo "  resolved: '$WT'"
      echo "  expected: a linked worktree of '$PROJ_ABS' (git common dir '$(proj_git_common_real)')"
      echo "  hint: a raced or stale treehouse lease, or an rc-driven cd in the pane's shell, can leave the pane cwd in an unrelated repo; inspect the pool state ('treehouse status' in the project; ~/.treehouse/*/treehouse-state.json) and target $2 before respawning. The just-created window is killed and no meta is recorded."
    } >&2
    cleanup_spawn_window "$WID"
    exit 1
  }
}

WINDOW_IDS_BEFORE=$(tmux list-windows -t "$SES" -F '#{window_id}' 2>/dev/null || true)
WID=$(tmux new-window -dP -F '#{window_id}' -t "$SES:" -n "$W" -c "$PROJ_ABS") || exit 1
if [[ ! "$WID" =~ ^@[0-9]+$ ]]; then
  cleanup_unidentified_spawn_window
  echo "error: tmux did not return a window id for $T" >&2
  exit 1
fi
if ! tmux set-window-option -t "$WID" automatic-rename off; then
  cleanup_spawn_window "$WID"
  echo "error: tmux failed to disable automatic window renaming for $T" >&2
  exit 1
fi
if ! tmux set-window-option -t "$WID" allow-rename off; then
  cleanup_spawn_window "$WID"
  echo "error: tmux failed to disable window renaming for $T" >&2
  exit 1
fi
if ! tmux rename-window -t "$WID" "$W"; then
  cleanup_spawn_window "$WID"
  echo "error: tmux failed to restore canonical window name $T" >&2
  exit 1
fi
if [ "$(tmux display-message -p -t "$WID" '#{window_name}')" != "$W" ]; then
  cleanup_spawn_window "$WID"
  echo "error: tmux did not retain canonical window name $T" >&2
  exit 1
fi
if [ "$KIND" != secondmate ]; then
  tmux send-keys -t "$WID" 'treehouse get' Enter

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  # Accept a pane cwd only once it passes the complete target-repo check. A
  # transient foreign cwd is retained only for the eventual diagnostic.
  WT_CANDIDATE=
  for _ in $(seq 1 "${FM_SPAWN_WT_WAIT_SECS:-60}"); do
    p=$(tmux display-message -p -t "$WID" '#{pane_current_path}' 2>/dev/null || true)
    if [ -n "$p" ] && [ "$(real_path_or_raw "$p")" != "$PROJ_ABS_REAL" ]; then
      WT_CANDIDATE="$p"
      if worktree_of_target_repo "$p"; then
        WT="$p"
        break
      fi
    fi
    sleep 1
  done
  if [ -z "$WT" ] && [ -n "$WT_CANDIDATE" ]; then
    WT="$WT_CANDIDATE"
  fi
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within ${FM_SPAWN_WT_WAIT_SECS:-60}s; inspect window $T" >&2
    exit 1
  fi

  validate_spawn_worktree "treehouse get" "$T"
fi

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (see the harness-adapters
      # skill for verification), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md project management and task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

append_jt_pr_intake_governor
append_route_block
# Soft CBM orientation for allowlisted ship/scout projects only (no-op if CBM
# off/missing). Secondmate charters stay free of CBM policy text.
if [ "$KIND" != secondmate ]; then
  fm_cbm_append_brief_policy "$BRIEF" "$PROJ_ABS" "$KIND" || true
fi

mkdir -p "$STATE"
{
  echo "window=$T"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "route_profile=$ROUTE_PROFILE"
  echo "route_harness=$ROUTE_HARNESS"
  echo "route_model=$ROUTE_MODEL"
  echo "route_effort=$ROUTE_EFFORT"
  echo "route_reason=$ROUTE_REASON"
  echo "route_override=$ROUTE_OVERRIDE"
  echo "route_risk_flags=$ROUTE_RISK_FLAGS"
  echo "tasktmp=$TASK_TMP"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT")
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
sq_gotmpdir=$(shell_quote "$TASK_TMP/gotmp")
tmux send-keys -t "$WID" "export GOTMPDIR=$sq_gotmpdir" Enter
sleep 0.3
# Soft CBM env for orientation tools/CLI (cache + resource caps + PATH).
# Also prefix the launch command so the agent process itself inherits CBM even
# if a later pane export is missed. Missing CBM is a no-op.
if [ "$KIND" != secondmate ] && fm_cbm_project_eligible "$PROJ_ABS" \
  && fm_cbm_prepare_environment 2>/dev/null \
  && cbm_prefix=$(fm_cbm_launch_env_prefix_prepared 2>/dev/null); then
  # Pane-level exports for shell tools the agent may run later.
  cbm_cache=$FM_CBM_RESOLVED_CACHE
  cbm_mem=$FM_CBM_RESOLVED_MEM
  cbm_workers=$FM_CBM_RESOLVED_WORKERS
  cbm_path_prefix=$FM_CBM_RESOLVED_PATH_PREFIX
  # FM_CBM_TASK_ID tags usage.jsonl lines from fm-cbm-cli.sh for this task.
  # FM_CBM_CLI points agents at the logged CLI wrapper when they shell out.
  cbm_cli_wrap=$(shell_quote "$FM_ROOT/bin/fm-cbm-cli.sh")
  tmux send-keys -t "$WID" "export CBM_CACHE_DIR=$(shell_quote "$cbm_cache") CBM_MEM_BUDGET_MB=$(shell_quote "$cbm_mem") CBM_WORKERS=$(shell_quote "$cbm_workers") FM_CBM_TASK_ID=$(shell_quote "$ID") FM_CBM_CLI=$cbm_cli_wrap FM_HOME=$(shell_quote "$FM_HOME") PATH=$(shell_quote "$cbm_path_prefix"):\"\$PATH\"" Enter
  sleep 0.2
  LAUNCH="${cbm_prefix}${LAUNCH}"
fi
tmux send-keys -t "$WID" -l "$LAUNCH"
sleep 0.3
tmux send-keys -t "$WID" Enter

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$T worktree=$WT"
