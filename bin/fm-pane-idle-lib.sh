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

fm_pane_idle_meta_index_collect() {
  local state=$1 output=$2 deadline_ms=${3:-} worker rc
  local cursor_path records_path complete_path
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ ! -L "$output" ] || return 1
  case "$output" in "$state"/*) ;; *) return 1 ;; esac
  cursor_path="$state/.pane-idle-meta-index.scan.cursor"
  records_path="$state/.pane-idle-meta-index.scan.records"
  complete_path="$state/.pane-idle-meta-index.scan.complete"
  for path in "$cursor_path" "$records_path" "$complete_path"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
    fi
  done
  : > "$output" || return 1
  if [ -e "$complete_path" ]; then
    rm -f "$cursor_path" "$records_path" || return 1
    rm -f "$complete_path" || return 1
  fi
  if [ ! -e "$records_path" ]; then
    : > "$records_path" || return 1
  fi
  if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
    return 124
  fi
  command -v perl >/dev/null 2>&1 || return 125
  perl - "$state" "$cursor_path" "$records_path" "$complete_path" "$deadline_ms" > "$output" <<'PERL' &
use strict;
use warnings;

my ($state, $cursor_path, $records_path, $complete_path, $deadline) = @ARGV;
$deadline = undef unless defined($deadline) && $deadline =~ /^\d+\z/ && $deadline ne '';

sub expired {
  return defined($deadline) && int(time() * 1000) >= $deadline;
}

sub write_cursor {
  my ($value) = @_;
  my $tmp = "$cursor_path.tmp.$$";
  open(my $fh, '>', $tmp) or return 0;
  print $fh $value, "\n" or return 0;
  close($fh) or return 0;
  rename($tmp, $cursor_path) or return 0;
  return 1;
}

my $cursor = '';
if (-e $cursor_path) {
  open(my $cfh, '<', $cursor_path) or exit 1;
  $cursor = <$cfh> // '';
  chomp $cursor;
  close($cfh) or exit 1;
}

while (1) {
  exit 124 if expired();
  opendir(my $dh, $state) or exit 1;
  my $next = '';
  while (defined(my $entry = readdir($dh))) {
    exit 124 if expired();
    next unless $entry =~ /\.meta\z/;
    next unless $entry gt $cursor;
    my $path = "$state/$entry";
    next unless -f $path && !-l $path;
    $next = $entry if $next eq '' || $entry lt $next;
  }
  closedir($dh) or exit 1;
  last if $next eq '';
  my $path = "$state/$next";
  if (-f $path && !-l $path) {
    open(my $fh, '<', $path) or exit 1;
    my ($window, $window_count) = ('', 0);
    while (defined(my $line = <$fh>)) {
      exit 124 if expired();
      chomp $line;
      next unless $line =~ /^window=(.*)\z/;
      $window = $1;
      $window_count++;
    }
    close($fh) or exit 1;
    if ($window_count == 1 && $window ne '') {
      open(my $rfh, '>>', $records_path) or exit 1;
      binmode($rfh);
      print $rfh $path, "\0", $window, "\0", "1", "\0" or exit 1;
      close($rfh) or exit 1;
    }
  }
  write_cursor($next) or exit 1;
  $cursor = $next;
}

open(my $rfh, '<', $records_path) or exit 1;
binmode($rfh);
local $/ = "\0";
my (%seen, %first_meta, %window_counts);
while (defined(my $path = <$rfh>)) {
  chomp $path;
  my $window = <$rfh>;
  my $count = <$rfh>;
  last unless defined($window) && defined($count);
  chomp $window;
  chomp $count;
  next if $seen{$path}++;
  next unless $window ne '' && $count =~ /^\d+\z/;
  $first_meta{$window} = $path unless exists $window_counts{$window};
  $window_counts{$window} += $count;
}
close($rfh) or exit 1;
for my $window (sort keys %window_counts) {
  print $first_meta{$window}, "\0", $window, "\0", $window_counts{$window}, "\0" or exit 1;
}
my $complete_tmp = "$complete_path.tmp.$$";
open(my $complete_fh, '>', $complete_tmp) or exit 1;
print $complete_fh "complete\n" or exit 1;
close($complete_fh) or exit 1;
rename($complete_tmp, $complete_path) or exit 1;
PERL
  worker=$!
  while kill -0 "$worker" 2>/dev/null; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      kill -TERM "$worker" 2>/dev/null || true
      kill -KILL "$worker" 2>/dev/null || true
      wait "$worker" 2>/dev/null || true
      rm -f "$output"
      return 124
    fi
    sleep 0.01
  done
  wait "$worker"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$output"
    return "$rc"
  fi
}

fm_pane_idle_meta_index_build() {  # <state> [deadline-ms] [force]
  local state=$1 deadline_ms=${2:-} force=${3:-} meta window count rc tmp
  local -a new_windows=() new_metas=() new_counts=()
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  if [ "$FM_PANE_IDLE_META_INDEX_STATE" = "$state" ] \
    && [ "$force" != force ] \
    && [ "${#FM_PANE_IDLE_META_INDEX_WINDOWS[@]}" -gt 0 ]; then
    return 0
  fi
  tmp=$(mktemp "$state/.pane-idle-meta-index.XXXXXX") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
  fm_pane_idle_meta_index_collect "$state" "$tmp" "$deadline_ms"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  while IFS= read -r -d '' meta \
    && IFS= read -r -d '' window \
    && IFS= read -r -d '' count; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      rm -f "$tmp"
      return 124
    fi
    [ -n "$window" ] || continue
    case "$meta" in
      "$state"/*) ;;
      *) rm -f "$tmp"; return 1 ;;
    esac
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rm -f "$tmp"; return 1; }
    new_metas+=("$meta")
    new_windows+=("$window")
    new_counts+=("$count")
  done < "$tmp"
  rm -f "$tmp"
  FM_PANE_IDLE_META_INDEX_WINDOWS=("${new_windows[@]}")
  FM_PANE_IDLE_META_INDEX_METAS=("${new_metas[@]}")
  FM_PANE_IDLE_META_INDEX_COUNTS=("${new_counts[@]}")
  FM_PANE_IDLE_META_INDEX_STATE=$state
}

fm_pane_idle_meta_for_window() {  # <state> <window>
  local state=$1 window=$2 candidate i
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
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
  local state=$1 window=$2 deadline_ms=${3:-${FM_INACTIVE_OUTCOME_SCAN_DEADLINE_MS:-}}
  local meta current_window count candidate= matches=0 rc tmp
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  tmp=$(mktemp "$state/.pane-idle-meta-direct.XXXXXX") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
  fm_pane_idle_meta_index_collect "$state" "$tmp" "$deadline_ms"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  while IFS= read -r -d '' meta \
    && IFS= read -r -d '' current_window \
    && IFS= read -r -d '' count; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      rm -f "$tmp"
      return 124
    fi
    [ "$current_window" = "$window" ] || continue
    matches=$((matches + 1))
    candidate=$meta
    [ "$count" = 1 ] || matches=2
  done < "$tmp"
  rm -f "$tmp"
  [ "$matches" = 1 ] || return 1
  printf '%s' "$candidate"
}

fm_pane_idle_meta_index_cursor_write() {
  local path=$1 value=$2 tmp
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  [ ! -L "$path" ] || return 1
  tmp=$(mktemp "$path.XXXXXX") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
  if ! printf '%s\n' "$value" > "$tmp" || [ -L "$path" ] || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_pane_idle_meta_index_persist() {
  local state=$1 directory=$2 deadline_ms=${3:-} window meta count i key path
  local cursor_path ready_path snapshot_path reclaim_cursor_path cursor= cursor_found=0 started=1
  local snapshot_tmp snapshot_changed=1 tmp now rc
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  if [ "$FM_PANE_IDLE_META_INDEX_STATE" != "$state" ]; then
    fm_pane_idle_meta_index_build "$state" "$deadline_ms"
    rc=$?
    [ "$rc" = 0 ] || return "$rc"
  fi
  cursor_path="$directory/.cursor"
  ready_path="$directory/.ready"
  snapshot_path="$directory/.snapshot"
  reclaim_cursor_path="$directory/.reclaim.cursor"
  for path in "$cursor_path" "$ready_path" "$snapshot_path" "$reclaim_cursor_path"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
    fi
  done
  if [ -e "$ready_path" ]; then
    rm -f "$ready_path" || return 1
  fi
  snapshot_tmp=$(mktemp "$snapshot_path.XXXXXX") || return 1
  [ -f "$snapshot_tmp" ] && [ ! -L "$snapshot_tmp" ] || { rm -f "$snapshot_tmp"; return 1; }
  for ((i = 0; i < ${#FM_PANE_IDLE_META_INDEX_WINDOWS[@]}; i++)); do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      rm -f "$snapshot_tmp"
      return 124
    fi
    meta=${FM_PANE_IDLE_META_INDEX_METAS[$i]}
    window=${FM_PANE_IDLE_META_INDEX_WINDOWS[$i]}
    count=${FM_PANE_IDLE_META_INDEX_COUNTS[$i]}
    case "$meta" in "$state"/*) ;; *) rm -f "$snapshot_tmp"; return 1 ;; esac
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rm -f "$snapshot_tmp"; return 1; }
    printf '%s\0%s\0%s\0' "$meta" "$window" "$count" >> "$snapshot_tmp" || {
      rm -f "$snapshot_tmp"
      return 1
    }
  done
  if [ -f "$snapshot_path" ] && [ ! -L "$snapshot_path" ] \
    && cmp -s "$snapshot_tmp" "$snapshot_path"; then
    snapshot_changed=0
  fi
  if [ "$snapshot_changed" = 1 ]; then
    rm -f "$cursor_path" "$reclaim_cursor_path" || {
      rm -f "$snapshot_tmp"
      return 1
    }
  fi
  if [ -e "$cursor_path" ]; then
    cursor=$(cat "$cursor_path" 2>/dev/null || true)
    for ((i = 0; i < ${#FM_PANE_IDLE_META_INDEX_METAS[@]}; i++)); do
      [ "${FM_PANE_IDLE_META_INDEX_METAS[$i]}" = "$cursor" ] || continue
      cursor_found=1
      break
    done
    if [ "$cursor_found" = 0 ]; then
      cursor=
      rm -f "$cursor_path" || { rm -f "$snapshot_tmp"; return 1; }
    fi
  fi
  [ -n "$cursor" ] || started=1
  [ -n "$cursor" ] && [ "$cursor_found" = 1 ] && started=0
  for ((i = 0; i < ${#FM_PANE_IDLE_META_INDEX_WINDOWS[@]}; i++)); do
    meta=${FM_PANE_IDLE_META_INDEX_METAS[$i]}
    if [ "$started" = 0 ]; then
      if [ "$meta" = "$cursor" ]; then
        started=1
      fi
      continue
    fi
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      rm -f "$snapshot_tmp"
      return 124
    fi
    window=${FM_PANE_IDLE_META_INDEX_WINDOWS[$i]}
    count=${FM_PANE_IDLE_META_INDEX_COUNTS[$i]}
    key=$(fm_pane_idle_sha256 "$window") || { rm -f "$snapshot_tmp"; return 1; }
    path="$directory/$key"
    [ ! -L "$path" ] || { rm -f "$snapshot_tmp"; return 1; }
    if [ -e "$path" ]; then
      [ -f "$path" ] || { rm -f "$snapshot_tmp"; return 1; }
    fi
    tmp=$(mktemp "$path.XXXXXX") || { rm -f "$snapshot_tmp"; return 1; }
    [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp" "$snapshot_tmp"; return 1; }
    if ! printf '%s\n%s\n' "$count" "$meta" > "$tmp" \
      || [ -L "$path" ] || ! mv -f "$tmp" "$path"; then
      rm -f "$tmp" "$snapshot_tmp"
      return 1
    fi
    fm_pane_idle_meta_index_cursor_write "$cursor_path" "$meta" || {
      rm -f "$snapshot_tmp"
      return 1
    }
    cursor=$meta
  done
  rm -f "$cursor_path" || { rm -f "$snapshot_tmp"; return 1; }
  if [ "$snapshot_changed" = 1 ]; then
    [ ! -L "$snapshot_path" ] || { rm -f "$snapshot_tmp"; return 1; }
    mv -f "$snapshot_tmp" "$snapshot_path" || { rm -f "$snapshot_tmp"; return 1; }
  else
    rm -f "$snapshot_tmp" || return 1
  fi
  if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
    return 124
  fi
  [ ! -L "$ready_path" ] || return 1
  : > "$ready_path" || return 1
  fm_pane_idle_meta_index_reclaim "$directory" "$deadline_ms"
}

fm_pane_idle_meta_index_reclaim_next() {
  local directory=$1 cursor=$2 deadline_ms=${3:-} worker rc tmp next
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  command -v perl >/dev/null 2>&1 || return 125
  tmp=$(mktemp "$directory/.pane-idle-reclaim-next.XXXXXX") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
  perl - "$directory" "$cursor" "$deadline_ms" > "$tmp" <<'PERL' &
use strict;
use warnings;

my ($directory, $cursor, $deadline) = @ARGV;
$deadline = undef unless defined($deadline) && $deadline =~ /^\d+\z/ && $deadline ne '';
sub expired {
  return defined($deadline) && int(time() * 1000) >= $deadline;
}
opendir(my $dh, $directory) or exit 1;
my $next = '';
while (defined(my $entry = readdir($dh))) {
  exit 124 if expired();
  next unless $entry =~ /^[0-9A-Fa-f]{64}\z/;
  next unless $entry gt $cursor;
  my $path = "$directory/$entry";
  next unless -f $path && !-l $path;
  $next = $entry if $next eq '' || $entry lt $next;
}
closedir($dh) or exit 1;
print $next, "\n";
PERL
  worker=$!
  while kill -0 "$worker" 2>/dev/null; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      kill -TERM "$worker" 2>/dev/null || true
      kill -KILL "$worker" 2>/dev/null || true
      wait "$worker" 2>/dev/null || true
      rm -f "$tmp"
      return 124
    fi
    sleep 0.01
  done
  wait "$worker"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  next=$(cat "$tmp" 2>/dev/null || true)
  rm -f "$tmp" || return 1
  printf '%s' "$next"
}

fm_pane_idle_meta_index_reclaim() {
  local directory=$1 deadline_ms=${2:-} path base key next current i rc cursor_path cursor=
  local -a current_keys=()
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  cursor_path="$directory/.reclaim.cursor"
  if [ -e "$cursor_path" ] || [ -L "$cursor_path" ]; then
    [ -f "$cursor_path" ] && [ ! -L "$cursor_path" ] || return 1
    cursor=$(cat "$cursor_path" 2>/dev/null || true)
    case "$cursor" in ''|*[!0123456789abcdefABCDEF]*) return 1 ;; esac
  fi
  for ((i = 0; i < ${#FM_PANE_IDLE_META_INDEX_WINDOWS[@]}; i++)); do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      return 124
    fi
    key=$(fm_pane_idle_sha256 "${FM_PANE_IDLE_META_INDEX_WINDOWS[$i]}") || return 1
    [ "${#key}" = 64 ] || return 1
    case "$key" in *[!0123456789abcdefABCDEF]*) return 1 ;; esac
    current_keys+=("$key")
  done
  while :; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      return 124
    fi
    next=$(fm_pane_idle_meta_index_reclaim_next "$directory" "$cursor" "$deadline_ms")
    rc=$?
    case "$rc" in
      0) ;;
      124) return 124 ;;
      *) return "$rc" ;;
    esac
    [ -n "$next" ] || { rm -f "$cursor_path" || return 1; return 0; }
    current=0
    for ((i = 0; i < ${#current_keys[@]}; i++)); do
      if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
        return 124
      fi
      if [ "${current_keys[$i]}" = "$next" ]; then
        current=1
        break
      fi
    done
    path="$directory/$next"
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
      if [ "$current" = 0 ]; then
        rm -f "$path" || return 1
      fi
    fi
    fm_pane_idle_meta_index_cursor_write "$cursor_path" "$next" || return 1
    cursor=$next
  done
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
