#!/usr/bin/env bash

FM_PANE_IDLE_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'
FM_PANE_IDLE_META_INDEX_STATE=
FM_PANE_IDLE_META_INDEX_STATE_STAMP=
FM_PANE_IDLE_META_INDEX_SNAPSHOT=
FM_PANE_IDLE_META_INDEX_BUILT=0

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

fm_pane_idle_budget_secs() {
  local deadline_ms=$1 now
  case "$deadline_ms" in ''|*[!0-9]*) printf '300'; return 0 ;; esac
  now=$(fm_pane_idle_now_ms)
  [ "$deadline_ms" -gt "$now" ] || return 1
  printf '%s' "$(((deadline_ms - now + 999) / 1000))"
}

fm_pane_idle_run_bounded_child() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; my $status = $?; exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8))' "$seconds" "$@"
  else
    return 125
  fi
}

fm_pane_idle_path_stamp() {
  local path=$1 stamp
  stamp=$(stat -c '%Y:%y' "$path" 2>/dev/null) && {
    printf '%s' "$stamp"
    return 0
  }
  stat -f '%m' "$path" 2>/dev/null
}

fm_pane_idle_meta_index_collect() {
  local state=$1 output=$2 deadline_ms=${3:-} worker rc remaining sorted_tmp entries_tmp entries_sorted_tmp state_stamp entries_stamp
  local progress_dir cursor_path records_path complete_path seen_path aggregate_path aggregate_cursor_path
  local aggregate_complete_path sorted_path sorted_complete_path entries_path entries_complete_path entries_stamp_path
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ ! -L "$output" ] || return 1
  case "$output" in "$state"/*) ;; *) return 1 ;; esac
  progress_dir="$state/.pane-idle-meta-index"
  if [ -e "$progress_dir" ] || [ -L "$progress_dir" ]; then
    [ -d "$progress_dir" ] && [ ! -L "$progress_dir" ] || return 1
  else
    mkdir "$progress_dir" || return 1
  fi
  cursor_path="$progress_dir/.scan.cursor"
  records_path="$progress_dir/.scan.records"
  complete_path="$progress_dir/.scan.complete"
  seen_path="$progress_dir/.scan.seen"
  aggregate_path="$progress_dir/.scan.aggregate"
  aggregate_cursor_path="$progress_dir/.scan.aggregate.cursor"
  aggregate_complete_path="$progress_dir/.scan.aggregate.complete"
  sorted_path="$progress_dir/.scan.sorted"
  sorted_complete_path="$progress_dir/.scan.sorted.complete"
  entries_path="$progress_dir/.scan.entries"
  entries_complete_path="$progress_dir/.scan.entries.complete"
  entries_stamp_path="$progress_dir/.scan.entries.stamp"
  for path in "$cursor_path" "$records_path" "$complete_path" "$seen_path" \
    "$aggregate_path" "$aggregate_cursor_path" "$aggregate_complete_path" \
    "$sorted_path" "$sorted_complete_path" "$entries_path" \
    "$entries_complete_path" "$entries_stamp_path"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
    fi
  done
  if [ -e "$complete_path" ]; then
    rm -f "$cursor_path" "$records_path" "$seen_path" "$aggregate_path" \
      "$aggregate_cursor_path" "$aggregate_complete_path" "$sorted_path" \
      "$sorted_complete_path" "$complete_path" || return 1
  fi
  if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
    return 124
  fi
  state_stamp=$(fm_pane_idle_path_stamp "$state") || return 1
  entries_stamp=
  if [ -f "$entries_path" ] && [ ! -L "$entries_path" ] \
    && [ -f "$entries_complete_path" ] && [ ! -L "$entries_complete_path" ] \
    && [ -f "$entries_stamp_path" ] && [ ! -L "$entries_stamp_path" ]; then
    entries_stamp=$(cat "$entries_stamp_path" 2>/dev/null || true)
  fi
  if [ "$entries_stamp" != "$state_stamp" ]; then
    rm -f "$entries_path" "$entries_complete_path" "$entries_stamp_path" \
      "$cursor_path" "$records_path" "$seen_path" "$aggregate_path" \
      "$aggregate_cursor_path" "$aggregate_complete_path" "$sorted_path" \
      "$sorted_complete_path" || return 1
    entries_tmp=$(mktemp "$entries_path.XXXXXX") || return 1
    [ -f "$entries_tmp" ] && [ ! -L "$entries_tmp" ] || {
      rm -f "$entries_tmp"
      return 1
    }
    remaining=$(fm_pane_idle_budget_secs "$deadline_ms") || {
      rm -f "$entries_tmp"
      return 124
    }
    fm_pane_idle_run_bounded_child "$remaining" perl - "$state" > "$entries_tmp" <<'PERL'
use strict;
use warnings;
my $state = shift @ARGV;
opendir(my $dh, $state) or exit 1;
while (defined(my $entry = readdir($dh))) {
  next if $entry !~ /\.meta\z/ || $entry =~ /[\r\n]/;
  my $path = "$state/$entry";
  next unless -f $path && !-l $path;
  print $path, "\n" or exit 1;
}
closedir($dh) or exit 1;
PERL
    rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -ne 0 ] || rc=124
      rm -f "$entries_tmp"
      return "$rc"
    fi
    remaining=$(fm_pane_idle_budget_secs "$deadline_ms") || {
      rm -f "$entries_tmp"
      return 124
    }
    entries_sorted_tmp=$(mktemp "$entries_path.XXXXXX") || {
      rm -f "$entries_tmp"
      return 1
    }
    [ -f "$entries_sorted_tmp" ] && [ ! -L "$entries_sorted_tmp" ] || {
      rm -f "$entries_tmp" "$entries_sorted_tmp"
      return 1
    }
    fm_pane_idle_run_bounded_child "$remaining" env LC_ALL=C sort -u \
      "$entries_tmp" > "$entries_sorted_tmp"
    rc=$?
    rm -f "$entries_tmp"
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -ne 0 ] || rc=124
      rm -f "$entries_sorted_tmp"
      return "$rc"
    fi
    [ ! -L "$entries_path" ] && mv -f "$entries_sorted_tmp" "$entries_path" || {
      rm -f "$entries_sorted_tmp"
      return 1
    }
    fm_pane_idle_meta_index_cursor_write "$entries_complete_path" complete || return 1
    state_stamp=$(fm_pane_idle_path_stamp "$state") || return 1
    fm_pane_idle_meta_index_cursor_write "$entries_stamp_path" "$state_stamp" || return 1
    state_stamp=$(fm_pane_idle_path_stamp "$state") || return 1
    fm_pane_idle_meta_index_cursor_write "$entries_stamp_path" "$state_stamp" || return 1
  fi
  command -v perl >/dev/null 2>&1 || return 125
  perl - "$state" "$entries_path" "$cursor_path" "$records_path" "$complete_path" "$seen_path" "$deadline_ms" <<'PERL' &
use strict;
use warnings;
use Fcntl qw(:DEFAULT);

my ($state, $entries_path, $cursor_path, $records_path, $complete_path, $seen_path, $deadline, $output) = @ARGV;
$deadline = undef unless defined($deadline) && $deadline =~ /^\d+\z/ && $deadline ne '';
my $nofollow = eval { Fcntl::O_NOFOLLOW() };

sub open_read {
  my ($path) = @_;
  return undef if -l $path || !defined($nofollow);
  my $fh;
  sysopen($fh, $path, O_RDONLY | $nofollow) or return undef;
  return $fh;
}

sub open_append {
  my ($path) = @_;
  return undef if -l $path;
  my $flags = O_WRONLY | O_APPEND;
  if (-e $path) {
    return undef unless -f $path && defined($nofollow);
    $flags |= $nofollow;
  } else {
    $flags |= O_CREAT | O_EXCL;
  }
  my $fh;
  sysopen($fh, $path, $flags, 0600) or return undef;
  return $fh;
}

sub write_atomic {
  my ($path, $value) = @_;
  return 0 if -l $path;
  my $tmp = "$path.tmp.$$";
  my $fh;
  sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600) or return 0;
  binmode($fh);
  if (!print($fh $value) || !close($fh)) {
    close($fh);
    return 0;
  }
  return 0 if -l $path;
  rename($tmp, $path) or return 0;
  return 1;
}

sub open_output {
  my ($path) = @_;
  return undef if -l $path || !-f $path || !defined($nofollow);
  my $fh;
  sysopen($fh, $path, O_WRONLY | O_TRUNC | $nofollow) or return undef;
  return $fh;
}

sub expired {
  return defined($deadline) && int(time() * 1000) >= $deadline;
}

my $cursor = '';
if (-e $cursor_path) {
  my $cfh = open_read($cursor_path) or exit 1;
  $cursor = <$cfh> // '';
  chomp $cursor;
  close($cfh) or exit 1;
}
$cursor = '' if $cursor ne '' && $cursor ne 'EOF' && $cursor !~ /^\d+\z/;

while (1) {
  exit 124 if expired();
  exit 1 unless -d $state && !-l $state;
  if (!-e $records_path) {
    my $rfh = open_append($records_path) or exit 1;
    close($rfh) or exit 1;
  }
  if (!-e $seen_path) {
    my $sfh = open_append($seen_path) or exit 1;
    close($sfh) or exit 1;
  }
  exit 0 if $cursor eq 'EOF';
  my $efh = open_read($entries_path) or exit 1;
  binmode($efh);
  while (defined(my $path = <$efh>)) {
    exit 124 if expired();
    chomp $path;
    next if $path !~ /\.meta\z/ || $path =~ /[\r\n]/;
    next if $cursor ne '' && $path le $cursor;
    $path =~ /\A\Q$state\E\/[^\/]+\.meta\z/ or exit 1;
    if (-f $path && !-l $path) {
      my $fh = open_read($path) or exit 1;
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
        my $rfh = open_append($records_path) or exit 1;
        binmode($rfh);
        print $rfh $path, "\0", $window, "\0", "1", "\0" or exit 1;
        close($rfh) or exit 1;
      }
    }
    my $sfh = open_append($seen_path) or exit 1;
    print $sfh $path, "\n" or exit 1;
    close($sfh) or exit 1;
    write_atomic($cursor_path, "$path\n") or exit 1;
    $cursor = $path;
  }
  close($efh) or exit 1;
  write_atomic($cursor_path, "EOF\n") or exit 1;
  $cursor = 'EOF';
}
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
  rm -f "$cursor_path.tmp.$worker" "$complete_path.tmp.$worker"
  if [ "$rc" -ne 0 ]; then
    rm -f "$output"
    return "$rc"
  fi
  if [ ! -e "$aggregate_complete_path" ]; then
    remaining=$(fm_pane_idle_budget_secs "$deadline_ms") || {
      rm -f "$output"
      return 124
    }
    if fm_pane_idle_run_bounded_child "$remaining" perl - "$records_path" \
      "$aggregate_path" "$aggregate_cursor_path" "$aggregate_complete_path" <<'PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT);

my ($records_path, $aggregate_path, $cursor_path, $complete_path) = @ARGV;
my $nofollow = eval { Fcntl::O_NOFOLLOW() };
defined($nofollow) or exit 1;
sub open_read {
  my ($path) = @_;
  return undef if -l $path || !-f $path;
  my $fh;
  sysopen($fh, $path, O_RDONLY | $nofollow) or return undef;
  return $fh;
}
sub open_append {
  my ($path) = @_;
  return undef if -l $path;
  my $flags = O_WRONLY | O_APPEND;
  if (-e $path) {
    return undef unless -f $path;
    $flags |= $nofollow;
  } else {
    $flags |= O_CREAT | O_EXCL;
  }
  my $fh;
  sysopen($fh, $path, $flags, 0600) or return undef;
  return $fh;
}
sub write_atomic {
  my ($path, $value) = @_;
  return 0 if -l $path;
  my $tmp = "$path.tmp.$$";
  my $fh;
  sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600) or return 0;
  binmode($fh);
  return 0 unless print($fh $value) && close($fh);
  return 0 if -l $path;
  rename($tmp, $path) or return 0;
  return 1;
}
my $offset = 0;
if (-e $cursor_path) {
  my $cfh = open_read($cursor_path) or exit 1;
  my $value = <$cfh> // '';
  close($cfh) or exit 1;
  chomp $value;
  $value =~ /^\d+\z/ or exit 1;
  $offset = 0 + $value;
}
my $rfh = open_read($records_path) or exit 1;
seek($rfh, $offset, 0) or exit 1;
my $afh = open_append($aggregate_path) or exit 1;
binmode($rfh);
binmode($afh);
local $/ = "\0";
while (defined(my $meta = <$rfh>)) {
  my $window = <$rfh>;
  my $count = <$rfh>;
  last unless defined($window) && defined($count);
  $meta =~ s/\0\z// or exit 1;
  $window =~ s/\0\z// or exit 1;
  $count =~ s/\0\z// or exit 1;
  $window =~ /^\S+\z/ or exit 1;
  $count =~ /^\d+\z/ or exit 1;
  print $afh unpack('H*', $window), "\t", unpack('H*', $meta), "\n" or exit 1;
  my $position = tell($rfh);
  defined($position) or exit 1;
  write_atomic($cursor_path, "$position\n") or exit 1;
}
close($rfh) or exit 1;
close($afh) or exit 1;
write_atomic($complete_path, "complete\n") or exit 1;
PERL
    then :
    else
      rc=$?
      [ "$rc" -ne 0 ] || rc=124
      rm -f "$output"
      return "$rc"
    fi
  fi
  if [ ! -e "$sorted_complete_path" ]; then
    remaining=$(fm_pane_idle_budget_secs "$deadline_ms") || {
      rm -f "$output"
      return 124
    }
    sorted_tmp=$(mktemp "$sorted_path.XXXXXX") || {
      rm -f "$output"
      return 1
    }
    [ -f "$sorted_tmp" ] && [ ! -L "$sorted_tmp" ] || {
      rm -f "$sorted_tmp" "$output"
      return 1
    }
    if fm_pane_idle_run_bounded_child "$remaining" env LC_ALL=C sort -u \
      "$aggregate_path" > "$sorted_tmp" \
      && [ ! -L "$sorted_path" ] && mv -f "$sorted_tmp" "$sorted_path" \
      && fm_pane_idle_meta_index_cursor_write "$sorted_complete_path" complete; then
      :
    else
      rc=$?
      [ "$rc" -ne 0 ] || rc=124
      rm -f "$sorted_tmp" "$output"
      return "$rc"
    fi
  fi
  remaining=$(fm_pane_idle_budget_secs "$deadline_ms") || {
    rm -f "$output"
    return 124
  }
  if fm_pane_idle_run_bounded_child "$remaining" perl - "$sorted_path" "$output" <<'PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT);

my ($sorted_path, $output) = @ARGV;
my $nofollow = eval { Fcntl::O_NOFOLLOW() };
defined($nofollow) or exit 1;
open(my $sfh, '<', $sorted_path) or exit 1;
binmode($sfh);
my $ofh;
sysopen($ofh, $output, O_WRONLY | O_TRUNC | $nofollow) or exit 1;
binmode($ofh);
my ($window, $first_meta, $count) = ('', '', 0);
sub flush_window {
  return unless $count;
  print $ofh $first_meta, "\0", $window, "\0", $count, "\0" or exit 1;
}
while (defined(my $line = <$sfh>)) {
  chomp $line;
  my ($window_hex, $meta_hex) = split(/\t/, $line, 2);
  exit 1 unless defined($window_hex) && defined($meta_hex)
    && $window_hex =~ /\A(?:[0-9A-Fa-f]{2})*\z/
    && $meta_hex =~ /\A(?:[0-9A-Fa-f]{2})*\z/;
  my $current_window = pack('H*', $window_hex);
  my $current_meta = pack('H*', $meta_hex);
  if ($current_window ne $window) {
    flush_window();
    $window = $current_window;
    $first_meta = $current_meta;
    $count = 1;
  } else {
    $count++;
  }
}
close($sfh) or exit 1;
flush_window();
close($ofh) or exit 1;
PERL
  then :
  else
    rc=$?
    [ "$rc" -ne 0 ] || rc=124
    rm -f "$output"
    return "$rc"
  fi
  fm_pane_idle_meta_index_cursor_write "$complete_path" complete || {
    rm -f "$output"
    return 1
  }
  for path in "$output" "$records_path" "$complete_path" "$seen_path" \
    "$aggregate_path" "$aggregate_complete_path" "$sorted_path" \
    "$sorted_complete_path"; do
    [ -f "$path" ] && [ ! -L "$path" ] || {
      rm -f "$output"
      return 1
    }
  done
  if [ -e "$cursor_path" ] || [ -L "$cursor_path" ]; then
    [ -f "$cursor_path" ] && [ ! -L "$cursor_path" ] || {
      rm -f "$output"
      return 1
    }
  fi
}

fm_pane_idle_meta_index_build() {  # <state> [deadline-ms] [force]
  local state=$1 deadline_ms=${2:-} force=${3:-} rc tmp stamp snapshot progress_dir
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  progress_dir="$state/.pane-idle-meta-index"
  if [ -e "$progress_dir" ] || [ -L "$progress_dir" ]; then
    [ -d "$progress_dir" ] && [ ! -L "$progress_dir" ] || return 1
  else
    mkdir "$progress_dir" || return 1
  fi
  stamp=$(fm_pane_idle_path_stamp "$state") || return 1
  snapshot="$progress_dir/snapshot"
  if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
  fi
  if [ "$FM_PANE_IDLE_META_INDEX_STATE" = "$state" ] \
    && [ "$force" != force ] \
    && [ "$FM_PANE_IDLE_META_INDEX_BUILT" = 1 ] \
    && [ "$FM_PANE_IDLE_META_INDEX_STATE_STAMP" = "$stamp" ] \
    && [ -f "$snapshot" ]; then
    return 0
  fi
  tmp=$(mktemp "$snapshot.XXXXXX") || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
  fm_pane_idle_meta_index_collect "$state" "$tmp" "$deadline_ms"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    return "$rc"
  fi
  [ ! -L "$snapshot" ] && mv -f "$tmp" "$snapshot" || {
    rm -f "$tmp"
    return 1
  }
  FM_PANE_IDLE_META_INDEX_STATE=$state
  FM_PANE_IDLE_META_INDEX_STATE_STAMP=$(fm_pane_idle_path_stamp "$state") || return 1
  FM_PANE_IDLE_META_INDEX_SNAPSHOT=$snapshot
  FM_PANE_IDLE_META_INDEX_BUILT=1
}

fm_pane_idle_meta_for_window() {  # <state> <window>
  local state=$1 window=$2 candidate current_window count match_meta= matches=0
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  fm_pane_idle_meta_index_build "$state" || return 1
  while IFS= read -r -d '' candidate \
    && IFS= read -r -d '' current_window \
    && IFS= read -r -d '' count; do
    [ "$current_window" = "$window" ] || continue
    matches=$((matches + 1))
    [ "$count" = 1 ] || return 1
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    match_meta=$candidate
    [ "$matches" = 1 ] || return 1
  done < "$FM_PANE_IDLE_META_INDEX_SNAPSHOT"
  [ "$matches" = 1 ] || return 1
  printf '%s' "$match_meta"
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
  local state=$1 directory=$2 deadline_ms=${3:-} window meta count key path
  local cursor_path ready_path snapshot_path reclaim_cursor_path cursor= cursor_found=0 started=1
  local reclaim_entries_path reclaim_entries_complete_path snapshot_source
  local snapshot_tmp snapshot_changed=1 tmp rc
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  fm_pane_idle_meta_index_build "$state" "$deadline_ms"
  rc=$?
  [ "$rc" = 0 ] || return "$rc"
  snapshot_source=$FM_PANE_IDLE_META_INDEX_SNAPSHOT
  [ -f "$snapshot_source" ] && [ ! -L "$snapshot_source" ] || return 1
  cursor_path="$directory/.cursor"
  ready_path="$directory/.ready"
  snapshot_path="$directory/.snapshot"
  reclaim_cursor_path="$directory/.reclaim.cursor"
  reclaim_entries_path="$directory/.reclaim.entries"
  reclaim_entries_complete_path="$directory/.reclaim.entries.complete"
  for path in "$cursor_path" "$ready_path" "$snapshot_path" "$reclaim_cursor_path" \
    "$reclaim_entries_path" "$reclaim_entries_complete_path"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
    fi
  done
  if [ -e "$ready_path" ]; then
    rm -f "$ready_path" || return 1
  fi
  snapshot_tmp=$(mktemp "$snapshot_path.XXXXXX") || return 1
  [ -f "$snapshot_tmp" ] && [ ! -L "$snapshot_tmp" ] || { rm -f "$snapshot_tmp"; return 1; }
  if [ -e "$cursor_path" ]; then
    [ -f "$cursor_path" ] && [ ! -L "$cursor_path" ] || {
      rm -f "$snapshot_tmp"
      return 1
    }
    cursor=$(cat "$cursor_path" 2>/dev/null || true)
    case "$cursor" in *$'\n'*|*$'\r'*|*$'\t'*)
      rm -f "$snapshot_tmp"
      return 1
      ;;
    esac
  fi
  while IFS= read -r -d '' meta \
    && IFS= read -r -d '' window \
    && IFS= read -r -d '' count; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      rm -f "$snapshot_tmp"
      return 124
    fi
    case "$meta" in "$state"/*) ;; *) rm -f "$snapshot_tmp"; return 1 ;; esac
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rm -f "$snapshot_tmp"; return 1; }
    printf '%s\0%s\0%s\0' "$meta" "$window" "$count" >> "$snapshot_tmp" || {
      rm -f "$snapshot_tmp"
      return 1
    }
    [ -n "$cursor" ] && [ "$meta" = "$cursor" ] && cursor_found=1
  done < "$snapshot_source"
  if [ -f "$snapshot_path" ] && [ ! -L "$snapshot_path" ] \
    && cmp -s "$snapshot_tmp" "$snapshot_path"; then
    snapshot_changed=0
  fi
  if [ "$snapshot_changed" = 1 ]; then
    rm -f "$reclaim_cursor_path" "$reclaim_entries_path" \
      "$reclaim_entries_complete_path" || {
      rm -f "$snapshot_tmp"
      return 1
    }
    [ ! -L "$snapshot_path" ] || { rm -f "$snapshot_tmp"; return 1; }
    mv -f "$snapshot_tmp" "$snapshot_path" || { rm -f "$snapshot_tmp"; return 1; }
    snapshot_changed=0
    cursor=
    started=1
  fi
  if [ "$snapshot_changed" != 1 ] && [ -n "$cursor" ] \
    && [ "$cursor_found" = 0 ]; then
    cursor=
    started=1
  elif [ "$snapshot_changed" != 1 ] && [ -n "$cursor" ]; then
    started=0
  fi
  while IFS= read -r -d '' meta \
    && IFS= read -r -d '' window \
    && IFS= read -r -d '' count; do
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
  done < "$snapshot_source"
  rm -f "$cursor_path" || { rm -f "$snapshot_tmp"; return 1; }
  rm -f "$snapshot_tmp" || return 1
  if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
    return 124
  fi
  fm_pane_idle_meta_index_cursor_write "$ready_path" ready || return 1
  fm_pane_idle_meta_index_reclaim "$directory" "$deadline_ms" "$snapshot_source"
}

fm_pane_idle_meta_index_reclaim() {
  local directory=$1 deadline_ms=${2:-} snapshot_source=${3:-} current_tmp cursor_path worker rc path key meta window count
  local entries_path entries_complete_path entries_tmp entries_sorted_tmp remaining
  case "$deadline_ms" in ''|*[!0-9]*) deadline_ms=;; esac
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  [ -f "$snapshot_source" ] && [ ! -L "$snapshot_source" ] || return 1
  cursor_path="$directory/.reclaim.cursor"
  if [ -e "$cursor_path" ] || [ -L "$cursor_path" ]; then
    [ -f "$cursor_path" ] && [ ! -L "$cursor_path" ] || return 1
  fi
  entries_path="$directory/.reclaim.entries"
  entries_complete_path="$directory/.reclaim.entries.complete"
  for path in "$entries_path" "$entries_complete_path"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] || {
        return 1
      }
    fi
  done
  command -v perl >/dev/null 2>&1 || return 125
  current_tmp=$(mktemp "$directory/.reclaim-current.XXXXXX") || return 1
  [ -f "$current_tmp" ] && [ ! -L "$current_tmp" ] || {
    rm -f "$current_tmp"
    return 1
  }
  while IFS= read -r -d '' meta \
    && IFS= read -r -d '' window \
    && IFS= read -r -d '' count; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      rm -f "$current_tmp"
      return 124
    fi
    key=$(fm_pane_idle_sha256 "$window") || {
      rm -f "$current_tmp"
      return 1
    }
    [ "${#key}" = 64 ] || { rm -f "$current_tmp"; return 1; }
    case "$key" in *[!0123456789abcdefABCDEF]*) rm -f "$current_tmp"; return 1 ;; esac
    printf '%s\n' "$key" >> "$current_tmp" || {
      rm -f "$current_tmp"
      return 1
    }
  done < "$snapshot_source"
  if [ ! -f "$entries_path" ] || [ ! -f "$entries_complete_path" ]; then
    entries_tmp=$(mktemp "$entries_path.XXXXXX") || {
      rm -f "$current_tmp"
      return 1
    }
    [ -f "$entries_tmp" ] && [ ! -L "$entries_tmp" ] || {
      rm -f "$entries_tmp" "$current_tmp"
      return 1
    }
    remaining=$(fm_pane_idle_budget_secs "$deadline_ms") || {
      rm -f "$entries_tmp" "$current_tmp"
      return 124
    }
    fm_pane_idle_run_bounded_child "$remaining" perl - "$directory" > "$entries_tmp" <<'PERL'
use strict;
use warnings;
my $directory = shift @ARGV;
opendir(my $dh, $directory) or exit 1;
while (defined(my $entry = readdir($dh))) {
  print $entry, "\n" if $entry =~ /^[0-9A-Fa-f]{64}\z/;
}
closedir($dh) or exit 1;
PERL
    rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -ne 0 ] || rc=124
      rm -f "$entries_tmp" "$current_tmp"
      return "$rc"
    fi
    remaining=$(fm_pane_idle_budget_secs "$deadline_ms") || {
      rm -f "$entries_tmp" "$current_tmp"
      return 124
    }
    entries_sorted_tmp=$(mktemp "$entries_path.XXXXXX") || {
      rm -f "$entries_tmp" "$current_tmp"
      return 1
    }
    [ -f "$entries_sorted_tmp" ] && [ ! -L "$entries_sorted_tmp" ] || {
      rm -f "$entries_tmp" "$entries_sorted_tmp" "$current_tmp"
      return 1
    }
    fm_pane_idle_run_bounded_child "$remaining" env LC_ALL=C sort -u \
      "$entries_tmp" > "$entries_sorted_tmp"
    rc=$?
    rm -f "$entries_tmp"
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -ne 0 ] || rc=124
      rm -f "$entries_sorted_tmp" "$current_tmp"
      return "$rc"
    fi
    [ ! -L "$entries_path" ] && mv -f "$entries_sorted_tmp" "$entries_path" || {
      rm -f "$entries_sorted_tmp" "$current_tmp"
      return 1
    }
    fm_pane_idle_meta_index_cursor_write "$entries_complete_path" complete || {
      rm -f "$current_tmp"
      return 1
    }
  fi
  perl - "$directory" "$current_tmp" "$entries_path" "$cursor_path" "$deadline_ms" <<'PERL' &
use strict;
use warnings;
use Fcntl qw(:DEFAULT);

my ($directory, $current_path, $entries_path, $cursor_path, $deadline) = @ARGV;
$deadline = undef unless defined($deadline) && $deadline =~ /^\d+\z/ && $deadline ne '';
my $nofollow = eval { Fcntl::O_NOFOLLOW() };
defined($nofollow) or exit 1;
sub expired {
  return defined($deadline) && int(time() * 1000) >= $deadline;
}
sub write_progress {
  my ($path, $value) = @_;
  return 0 if -l $path || !defined($nofollow);
  my $fh;
  sysopen($fh, $path, O_WRONLY | O_CREAT | O_TRUNC | $nofollow, 0600) or return 0;
  binmode($fh);
  return 0 unless print($fh $value, "\n") && close($fh);
  return 1;
}
open(my $cfh, '<', $current_path) or exit 1;
my %current;
while (defined(my $key = <$cfh>)) {
  exit 124 if expired();
  chomp $key;
  $current{$key} = 1 if $key =~ /^[0-9A-Fa-f]{64}\z/;
}
close($cfh) or exit 1;
my $cursor = '';
if (-e $cursor_path) {
  open(my $rfh, '<', $cursor_path) or exit 1;
  my $value = <$rfh> // '';
  close($rfh) or exit 1;
  chomp $value;
  $cursor = $value if $value =~ /^[0-9A-Fa-f]{64}\z/;
}
my $efh;
sysopen($efh, $entries_path, O_RDONLY | $nofollow) or exit 1;
while (defined(my $entry = <$efh>)) {
  exit 124 if expired();
  chomp $entry;
  next unless $entry =~ /^[0-9A-Fa-f]{64}\z/;
  next if $cursor ne '' && $entry le $cursor;
  if ($entry =~ /^[0-9A-Fa-f]{64}\z/) {
    my $path = "$directory/$entry";
    exit 1 if -l $path;
    if (-e $path) {
      exit 1 unless -f $path;
      if (!exists $current{$entry}) {
        unlink($path) or exit 1;
      }
    }
  }
  write_progress($cursor_path, $entry) or exit 1;
}
close($efh) or exit 1;
PERL
  worker=$!
  while kill -0 "$worker" 2>/dev/null; do
    if [ -n "$deadline_ms" ] && [ "$(fm_pane_idle_now_ms)" -ge "$deadline_ms" ]; then
      kill -TERM "$worker" 2>/dev/null || true
      kill -KILL "$worker" 2>/dev/null || true
      wait "$worker" 2>/dev/null || true
      rm -f "$current_tmp"
      return 124
    fi
    sleep 0.01
  done
  wait "$worker"
  rc=$?
  rm -f "$current_tmp" || return 1
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  rm -f "$cursor_path" || return 1
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
