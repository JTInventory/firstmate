#!/usr/bin/env bash

FM_PANE_IDLE_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'
FM_PANE_IDLE_META_INDEX_WINDOWS=()
FM_PANE_IDLE_META_INDEX_METAS=()
FM_PANE_IDLE_META_INDEX_COUNTS=()
FM_PANE_IDLE_META_INDEX_STATE=

fm_pane_idle_meta_value_unique() {  # <meta> <key>
  awk -F= -v wanted="$2" '
    $1 == wanted { count++; value=substr($0, index($0, "=") + 1) }
    END {
      if (count == 1) { print value; exit 0 }
      if (count == 0) exit 1
      exit 2
    }
  ' "$1" 2>/dev/null
}

fm_pane_idle_now_ms() {
  if command -v clock_millis >/dev/null 2>&1; then
    clock_millis
  else
    printf '%s000' "$(date +%s)"
  fi
}

fm_pane_idle_meta_index_build() {  # <state> [deadline-ms] [force]
  local state=$1 deadline_ms=${2:-} force=${3:-} meta window count rc now worker tmp
  local -a metas=()
  local -a new_windows=() new_metas=() new_counts=()
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  if [ "$FM_PANE_IDLE_META_INDEX_STATE" = "$state" ] \
    && [ "$force" != force ] \
    && [ "${#FM_PANE_IDLE_META_INDEX_WINDOWS[@]}" -gt 0 ]; then
    return 0
  fi
  for meta in "$state"/*.meta; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      return 124
    fi
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    metas+=("$meta")
  done
  if [ "${#metas[@]}" -gt 0 ]; then
    tmp=$(mktemp "$state/.pane-idle-meta-index.XXXXXX") || return 1
    (
      awk -F= '
        function finish_file() {
          if (seen && window_count == 1) {
            if (!(window_value in window_counts)) first_meta[window_value]=current_file
            window_counts[window_value]++
          }
        }
        FNR == 1 {
          finish_file()
          current_file=FILENAME
          window_count=0
          window_value=""
          seen=1
        }
        $1 == "window" {
          window_count++
          window_value=substr($0, index($0, "=") + 1)
        }
        END {
          finish_file()
          for (window in window_counts) {
            printf "%s%c%s%c%s%c", first_meta[window], 0, window, 0, window_counts[window], 0
          }
        }
      ' "${metas[@]}" > "$tmp" 2>/dev/null
    ) &
    worker=$!
    while kill -0 "$worker" 2>/dev/null; do
      if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
        kill "$worker" 2>/dev/null || true
        wait "$worker" 2>/dev/null || true
        rm -f "$tmp"
        return 124
      fi
      sleep 0.01
    done
    wait "$worker"
    rc=$?
    [ "$rc" = 0 ] || { rm -f "$tmp"; return "$rc"; }
    while IFS= read -r -d '' meta \
      && IFS= read -r -d '' window \
      && IFS= read -r -d '' count; do
      if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
        rm -f "$tmp"
        return 124
      fi
      [ -n "$window" ] || continue
      new_metas+=("$meta")
      new_windows+=("$window")
      new_counts+=("$count")
    done < "$tmp"
    rm -f "$tmp"
  fi
  FM_PANE_IDLE_META_INDEX_WINDOWS=("${new_windows[@]}")
  FM_PANE_IDLE_META_INDEX_METAS=("${new_metas[@]}")
  FM_PANE_IDLE_META_INDEX_COUNTS=("${new_counts[@]}")
  FM_PANE_IDLE_META_INDEX_STATE=$state
}

fm_pane_idle_meta_for_window() {  # <state> <window>
  local state=$1 window=$2 candidate i
  if [ "$FM_PANE_IDLE_META_INDEX_STATE" != "$state" ]; then
    fm_pane_idle_meta_index_build "$state" || return 1
  fi
  for ((i = 0; i < ${#FM_PANE_IDLE_META_INDEX_WINDOWS[@]}; i++)); do
    [ "${FM_PANE_IDLE_META_INDEX_WINDOWS[$i]}" = "$window" ] || continue
    [ "${FM_PANE_IDLE_META_INDEX_COUNTS[$i]}" = 1 ] || return 1
    candidate=${FM_PANE_IDLE_META_INDEX_METAS[$i]}
    [ -n "$candidate" ] || return 1
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

fm_pane_idle_meta_for_window_direct() {  # <state> <window>
  local state=$1 window=$2 meta
  local -a metas=()
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    metas+=("$meta")
  done
  [ "${#metas[@]}" -gt 0 ] || return 1
  awk -F= -v wanted="$window" '
    FNR == 1 {
      if (seen && count == 1 && value == wanted) {
        matches++
        candidate=current_file
      }
      current_file=FILENAME
      count=0
      value=""
      seen=1
    }
    $1 == "window" {
      count++
      value=substr($0, index($0, "=") + 1)
    }
    END {
      if (seen && count == 1 && value == wanted) {
        matches++
        candidate=current_file
      }
      if (matches == 1) print candidate
      exit !(matches == 1)
    }
  ' "${metas[@]}" 2>/dev/null
}

fm_pane_idle_meta_index_persist() {
  local state=$1 directory=$2 deadline_ms=${3:-} window meta count i key path
  local cursor_path ready_path cursor=0 tmp now
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  if [ "$FM_PANE_IDLE_META_INDEX_STATE" != "$state" ]; then
    fm_pane_idle_meta_index_build "$state" "$deadline_ms"
    i=$?
    [ "$i" = 0 ] || return "$i"
  fi
  cursor_path="$directory/.cursor"
  ready_path="$directory/.ready"
  if [ -f "$ready_path" ] && [ ! -L "$ready_path" ]; then
    rm -f "$ready_path" || return 1
  elif [ -e "$ready_path" ] || [ -L "$ready_path" ]; then
    return 1
  fi
  if [ -e "$cursor_path" ]; then
    [ -f "$cursor_path" ] && [ ! -L "$cursor_path" ] || return 1
    cursor=$(cat "$cursor_path" 2>/dev/null || true)
    case "$cursor" in ''|*[!0-9]*) return 1 ;; esac
  fi
  for ((i = 0; i < ${#FM_PANE_IDLE_META_INDEX_WINDOWS[@]}; i++)); do
    [ "$i" -ge "$cursor" ] || continue
    if [ -n "$deadline_ms" ] && command -v clock_millis >/dev/null 2>&1; then
      now=$(clock_millis)
      if [ "$now" -ge "$deadline_ms" ]; then
        tmp=$(mktemp "$cursor_path.XXXXXX") || return 1
        [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
        if ! printf '%s\n' "$i" > "$tmp" || [ -L "$cursor_path" ] || ! mv -f "$tmp" "$cursor_path"; then
          rm -f "$tmp"
          return 1
        fi
        return 124
      fi
    fi
    window=${FM_PANE_IDLE_META_INDEX_WINDOWS[$i]}
    count=${FM_PANE_IDLE_META_INDEX_COUNTS[$i]}
    key=$(fm_pane_idle_sha256 "$window") || return 1
    path="$directory/$key"
    [ ! -L "$path" ] || return 1
    tmp=$(mktemp "$path.XXXXXX") || return 1
    [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
    if ! printf '%s\n%s\n' "$count" "${FM_PANE_IDLE_META_INDEX_METAS[$i]}" > "$tmp" \
      || [ -L "$path" ] || ! mv -f "$tmp" "$path"; then
      rm -f "$tmp"
      return 1
    fi
  done
  rm -f "$cursor_path" || return 1
  : > "$ready_path" || return 1
}

fm_pane_idle_meta_for_window_indexed() {
  local directory=$1 window=$2 key path count meta current
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  key=$(fm_pane_idle_sha256 "$window") || return 1
  path="$directory/$key"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  {
    IFS= read -r count
    IFS= read -r meta
  } < "$path" || return 1
  [ "$count" = 1 ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  current=$(fm_pane_idle_meta_value_unique "$meta" window) || return 1
  [ "$current" = "$window" ] || return 1
  printf '%s' "$meta"
}

fm_pane_idle_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_pane_idle_hash() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_pane_idle_current_hash() {  # <backend> <target> <lines>
  local backend=$1 target=$2 lines=${3:-40} tail native=unknown
  command -v fm_backend_capture >/dev/null 2>&1 || return 1
  if [ "$backend" = herdr ] && command -v fm_backend_busy_state >/dev/null 2>&1; then
    native=$(FM_BACKEND_HERDR_NO_SERVER_START=1 fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
    case "$native" in
      busy) return 1 ;;
      idle|unknown) ;;
      *) return 1 ;;
    esac
  fi
  if [ "$backend" = herdr ]; then
    tail=$(FM_BACKEND_HERDR_NO_SERVER_START=1 fm_backend_capture "$backend" "$target" "$lines" 2>/dev/null) || return 1
  else
    tail=$(fm_backend_capture "$backend" "$target" "$lines" 2>/dev/null) || return 1
  fi
  if printf '%s' "$tail" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_PANE_IDLE_BUSY_REGEX_DEFAULT}"; then
    return 1
  fi
  printf '%s' "$tail" | fm_pane_idle_hash
}

fm_pane_idle_current_matches() {  # <backend> <target> <expected-hash>
  local current
  current=$(fm_pane_idle_current_hash "$1" "$2" 40) || return 1
  [ "$current" = "$3" ]
}

fm_pane_idle_read_incarnation() {  # <meta> <id>
  local meta=$1 id=$2 token tasktmp window worktree seed digest rc
  if token=$(fm_pane_idle_meta_value_unique "$meta" spawn_incarnation); then
    case "$token" in
      ''|legacy-unknown|*[!A-Za-z0-9._:-]*) return 1 ;;
    esac
    printf '%s' "$token"
    return 0
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
  fi
  if tasktmp=$(fm_pane_idle_meta_value_unique "$meta" tasktmp 2>/dev/null); then
    :
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
    tasktmp=
  fi
  if window=$(fm_pane_idle_meta_value_unique "$meta" window 2>/dev/null); then
    :
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
    window=
  fi
  if worktree=$(fm_pane_idle_meta_value_unique "$meta" worktree 2>/dev/null); then
    :
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
    worktree=
  fi
  if [ -n "$tasktmp" ]; then
    seed="legacy|tasktmp=$tasktmp"
  else
    seed="legacy|window=$window|worktree=$worktree"
  fi
  digest=$(fm_pane_idle_sha256 "$seed") || return 1
  printf 'legacy-%s' "${digest:0:32}"
}

fm_pane_idle_task_is_ordinary() {  # <meta>
  local kind rc
  if kind=$(fm_pane_idle_meta_value_unique "$1" kind); then
    :
  else
    rc=$?
    [ "$rc" = 1 ] && kind=ship || return 1
  fi
  case "$kind" in ship|scout) return 0 ;; esac
  return 1
}

fm_pane_idle_field_safe() {
  case "$1" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|*=*) return 1 ;;
  esac
}

fm_pane_idle_path() {  # <state> <task>
  printf '%s/.pane-idle/%s' "$1" "$2"
}

fm_pane_idle_key() {  # <window>
  printf '%s' "$1" | tr ':/.' '___'
}

fm_pane_idle_clear() {  # <state> <task>
  local state=$1 task=$2 dir path
  dir="$state/.pane-idle"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fi
  path=$(fm_pane_idle_path "$state" "$task")
  [ ! -e "$path" ] && return 0
  [ ! -L "$path" ] && [ -f "$path" ] || return 1
  rm -f "$path"
}

fm_pane_idle_clear_for_window() {  # <state> <window>
  local state=$1 window=$2 meta task
  meta=$(fm_pane_idle_meta_for_window "$state" "$window" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  task=${meta##*/}
  task=${task%.meta}
  fm_pane_idle_clear "$state" "$task"
}

fm_pane_idle_write() {  # <state> <meta> <task> <window> <backend> <hash> <samples>
  local state=$1 meta=$2 task=$3 window=$4 backend=$5 pane_hash=$6 samples=$7
  local path dir tmp token meta_window current_backend value rc
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fm_pane_idle_task_is_ordinary "$meta" || return 1
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  for value in "$window" "$backend" "$pane_hash"; do
    fm_pane_idle_field_safe "$value" || return 1
  done
  case "$backend" in tmux|herdr) ;; *) return 1 ;; esac
  case "$pane_hash" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  case "$samples" in ''|*[!0-9]*) return 1 ;; esac
  [ "$samples" -ge 2 ] || return 1
  meta_window=$(fm_pane_idle_meta_value_unique "$meta" window) || return 1
  [ "$meta_window" = "$window" ] || return 1
  if current_backend=$(fm_pane_idle_meta_value_unique "$meta" backend 2>/dev/null); then
    :
  else
    rc=$?
    [ "$rc" = 1 ] || return 1
    current_backend=tmux
  fi
  [ "$current_backend" = "$backend" ] || return 1
  token=$(fm_pane_idle_read_incarnation "$meta" "$task") || return 1
  dir="$state/.pane-idle"
  [ ! -L "$state" ] && [ -d "$state" ] || return 1
  if [ -e "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    mkdir "$dir" || return 1
  fi
  path=$(fm_pane_idle_path "$state" "$task")
  [ ! -L "$path" ] || return 1
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  if printf 'schema=fm-jt-pane-idle.v1\ntask=%s\nwindow=%s\nbackend=%s\nspawn_incarnation=%s\npane_hash=%s\nsample_count=%s\nobserved_epoch=%s\n' "$task" "$window" "$backend" "$token" "$pane_hash" "$samples" "$(date +%s)" > "$tmp" && mv -f "$tmp" "$path"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

fm_pane_idle_proof_valid() {  # <state> <meta> <task> <window> <backend> <incarnation> <max-age>
  local state=$1 meta=$2 task=$3 window=$4 backend=$5 incarnation=$6 max_age=$7
  local path proof_task proof_window proof_backend proof_incarnation pane_hash samples observed now age
  local key hash_file count_file current_hash current_count unique_meta
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fm_pane_idle_task_is_ordinary "$meta" || return 1
  if [ -n "${FM_PANE_IDLE_META_INDEX_DIR:-}" ]; then
    unique_meta=$(fm_pane_idle_meta_for_window_indexed "$FM_PANE_IDLE_META_INDEX_DIR" "$window" 2>/dev/null || true)
  else
    unique_meta=$(fm_pane_idle_meta_for_window_direct "$state" "$window" 2>/dev/null || true)
  fi
  [ "$unique_meta" = "$meta" ] || return 1
  path=$(fm_pane_idle_path "$state" "$task")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  awk -F= '
    BEGIN {
      allowed["schema"]=1; allowed["task"]=1; allowed["window"]=1
      allowed["backend"]=1; allowed["spawn_incarnation"]=1; allowed["pane_hash"]=1
      allowed["sample_count"]=1; allowed["observed_epoch"]=1
      required["schema"]=1; required["task"]=1; required["window"]=1
      required["backend"]=1; required["spawn_incarnation"]=1; required["pane_hash"]=1
      required["sample_count"]=1; required["observed_epoch"]=1
      valid=1
    }
    /^[^=]+=/ {
      key=$1
      if (!(key in allowed) || (key in seen)) valid=0
      seen[key]=1
      values[key]=substr($0, index($0, "=") + 1)
      next
    }
    { valid=0 }
    END {
      for (key in required) if (!(key in seen)) valid=0
      exit !(valid && values["schema"] == "fm-jt-pane-idle.v1")
    }
  ' "$path" 2>/dev/null || return 1
  proof_task=$(fm_pane_idle_meta_value_unique "$path" task) || return 1
  proof_window=$(fm_pane_idle_meta_value_unique "$path" window) || return 1
  proof_backend=$(fm_pane_idle_meta_value_unique "$path" backend) || return 1
  proof_incarnation=$(fm_pane_idle_meta_value_unique "$path" spawn_incarnation) || return 1
  pane_hash=$(fm_pane_idle_meta_value_unique "$path" pane_hash) || return 1
  samples=$(fm_pane_idle_meta_value_unique "$path" sample_count) || return 1
  observed=$(fm_pane_idle_meta_value_unique "$path" observed_epoch) || return 1
  [ "$proof_task" = "$task" ] && [ "$proof_window" = "$window" ] || return 1
  [ "$proof_backend" = "$backend" ] && [ "$proof_incarnation" = "$incarnation" ] || return 1
  case "$pane_hash" in ''|*[!A-Fa-f0-9]*) return 1 ;; esac
  case "$samples" in ''|*[!0-9]*) return 1 ;; esac
  [ "$samples" -ge 2 ] || return 1
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  case "$max_age" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  age=$((now - observed))
  [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ] || return 1
  key=$(fm_pane_idle_key "$window")
  hash_file="$state/.hash-$key"
  count_file="$state/.count-$key"
  [ -f "$hash_file" ] && [ ! -L "$hash_file" ] || return 1
  [ -f "$count_file" ] && [ ! -L "$count_file" ] || return 1
  current_hash=$(cat "$hash_file" 2>/dev/null || true)
  current_count=$(cat "$count_file" 2>/dev/null || true)
  [ "$current_hash" = "$pane_hash" ] || return 1
  case "$current_count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$current_count" -ge "$samples" ] || return 1
  fm_pane_idle_current_matches "$backend" "$window" "$pane_hash"
}
