#!/usr/bin/env bash
# Run every firstmate behavior test with bounded serial-by-default execution.
#
# FM_TEST_JOBS controls the number of test processes in flight. Values above one
# require FM_TEST_PARALLEL_ALLOWLIST to name isolated tests explicitly.
# This runner is intentionally Linux-only: it requires pidfds and a child
# subreaper; unsupported systems and architectures fail closed with exit 125.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

test_platform=$(uname -s 2>/dev/null || true)
test_arch=$(uname -m 2>/dev/null || true)
case "$test_platform:$test_arch" in
  Linux:x86_64|Linux:amd64|Linux:aarch64|Linux:riscv64|Linux:s390x|Linux:i[3-6]86|Linux:arm*|Linux:ppc64*) ;;
  *)
    printf '%s\n' 'FAIL: unsupported platform or architecture; behavior tests require Linux pidfd/subreaper support' >&2
    exit 125
    ;;
esac

if ! bash "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh"; then
  printf '%s\n' 'FAIL: PR target guard rejected this checkout; tests were not started' >&2
  exit 1
fi

if ! command -v tmux >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: tmux is required for e2e tests' >&2
  exit 1
fi
if ! tmux -V; then
  printf '%s\n' 'FAIL: tmux could not report its version' >&2
  exit 1
fi

jobs=${FM_TEST_JOBS:-1}
case "$jobs" in
  ''|*[!0-9]*)
    printf 'FAIL: FM_TEST_JOBS must be a positive integer (got %s)\n' "$jobs" >&2
    exit 1
    ;;
esac
if [ "$jobs" -lt 1 ]; then
  printf 'FAIL: FM_TEST_JOBS must be at least 1 (got %s)\n' "$jobs" >&2
  exit 1
fi

test_timeout=${FM_TEST_TIMEOUT_SECONDS:-300}
case "$test_timeout" in
  ''|*[!0-9]*)
    printf 'FAIL: FM_TEST_TIMEOUT_SECONDS must be a positive integer (got %s)\n' "$test_timeout" >&2
    exit 1
    ;;
esac
if [ "$test_timeout" -lt 1 ] || [ "$test_timeout" -gt 900 ]; then
  printf 'FAIL: FM_TEST_TIMEOUT_SECONDS must be between 1 and 900 seconds (got %s)\n' "$test_timeout" >&2
  exit 1
fi

FM_TEST_BOUNDED_GROUP_PERL='
use Config;
use Errno qw(ECHILD ESRCH);
use POSIX qw(:signal_h :sys_wait_h setpgid);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my $arch = $Config{archname} // "";
my $sys_prctl;
my $sys_pidfd_open;
my $sys_pidfd_send_signal;
if ($^O eq "linux") {
  if ($arch =~ /(?:x86_64|amd64)/) {
    $sys_prctl = 157;
  } elsif ($arch =~ /(?:aarch64|riscv64|s390x)/) {
    $sys_prctl = 167;
  } elsif ($arch =~ /(?:i[3-6]86|arm)/) {
    $sys_prctl = 172;
  } elsif ($arch =~ /ppc64/) {
    $sys_prctl = 171;
  }
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
}
my $containment_ready = sub {
  return 0 unless $^O eq "linux" && defined $sys_prctl;
  return syscall($sys_prctl, 36, 1, 0, 0, 0) == 0;
};
my $handles_ready = sub {
  return 0 unless $^O eq "linux" && defined $sys_pidfd_open && defined $sys_pidfd_send_signal;
  my $self = $$;
  my $fd = syscall($sys_pidfd_open, $self, 0);
  return 0 unless defined $fd && $fd >= 0;
  my $ok = syscall($sys_pidfd_send_signal, $fd, 0, 0, 0) == 0;
  POSIX::close($fd);
  return $ok;
};
$containment_ready->() && $handles_ready->() or do {
  print STDERR "FAIL: bounded behavior tests require Linux child-subreaper containment\n";
  exit 125;
};
my $process_info = sub {
  my $pid = shift;
  if ($^O eq "linux") {
    open my $stat, "<", "/proc/$pid/stat" or return;
    my $line = <$stat>;
    close $stat;
    return unless defined $line;
    my $comm_end = rindex($line, ")");
    return if $comm_end < 0;
    my @fields = split /\s+/, substr($line, $comm_end + 2);
    my $start = $fields[19];
    my $parent = $fields[1];
    return unless defined $start && $start =~ /^\d+\z/;
    return unless defined $parent && $parent =~ /^\d+\z/;
    return { identity => "$pid:$start", parent => 0 + $parent };
  }
  if ($^O eq "darwin") {
    open my $ps, "-|", "ps", "-p", "$pid", "-o", "lstart=" or return;
    my $start = <$ps>;
    my $ok = close $ps;
    return unless $ok && defined $start;
    $start =~ s/^\s+//;
    $start =~ s/\s+\z//;
    return { identity => "$pid:$start", parent => undef } if length $start;
  }
  return;
};
my $snapshot_children = sub {
  my %children;
  open my $ps, "-|", "ps", "-axo", "pid=,ppid=" or return;
  while (my $line = <$ps>) {
    next if $line =~ /^\s*$/;
    $line =~ /^\s*(\d+)\s+(\d+)\s*\z/ or return;
    push @{$children{$2}}, $1;
  }
  close $ps or return;
  return \%children;
};
my $read_children = sub {
  my $parent = shift;
  if ($^O eq "linux") {
    open my $children, "<", "/proc/$parent/task/$parent/children" or return;
    local $/;
    my $data = <$children>;
    close $children;
    return unless defined $data && $data =~ /^\s*(?:\d+\s*)*\z/;
    my @pids = ($data =~ /(\d+)/g);
    return \@pids;
  }
  if ($^O eq "darwin") {
    my $snapshot = $snapshot_children->();
    return unless defined $snapshot;
    return [@{$snapshot->{$parent} || []}];
  }
  return;
};
my $pidfd_open = sub {
  my $pid = shift;
  my $fd = syscall($sys_pidfd_open, $pid, 0);
  if (!defined $fd || $fd < 0) {
    return { gone => 1 } if $!{ESRCH};
    return { error => 1 };
  }
  return { fd => $fd };
};
my $pidfd_alive = sub {
  my $fd = shift;
  my $probe = syscall($sys_pidfd_send_signal, $fd, 0, 0, 0);
  return 1 if defined $probe && $probe == 0;
  return 0 if defined $probe && $probe < 0 && $!{ESRCH};
  return;
};
my $pidfd_signal = sub {
  my ($fd, $signal) = @_;
  my $sent = syscall($sys_pidfd_send_signal, $fd, $signal, 0, 0);
  return 1 if defined $sent && $sent == 0;
  return 0 if defined $sent && $sent < 0 && $!{ESRCH};
  return;
};
my $close_handle = sub {
  my $entry = shift;
  POSIX::close($entry->{fd}) if defined $entry->{fd};
  $entry->{fd} = undef;
};
my $seconds = shift;
my $blocked = POSIX::SigSet->new(SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGCONT);
my $old = POSIX::SigSet->new();
defined(sigprocmask(SIG_BLOCK, $blocked, $old)) or exit 125;
pipe(my $ready_r, my $ready_w) or exit 125;
pipe(my $release_r, my $release_w) or exit 125;
my $pid = fork;
defined($pid) or exit 125;
if (!$pid) {
  close $ready_r;
  close $release_w;
  setpgid(0, 0) == 0 or exit 125;
  syswrite($ready_w, "1") == 1 or exit 125;
  close $ready_w;
  my $release = "";
  my $release_count = sysread($release_r, $release, 1);
  close $release_r;
  exit 125 unless $release_count == 1 && $release eq "1";
  defined(sigprocmask(SIG_SETMASK, $old)) or exit 125;
  exec @ARGV;
  exit 127;
}
close $ready_w;
close $release_r;
my $pre_fd = $ENV{FM_TEST_FORCE_ROOT_PIDFD_OPEN_FAILURE}
  ? -1
  : syscall($sys_pidfd_open, $pid, 0);
my $pre_reap = sub {
  for (1 .. 100) {
    my $waited = waitpid $pid, WNOHANG;
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
my $pre_terminate = sub {
  my ($fd) = @_;
  my $sent = syscall($sys_pidfd_send_signal, $fd, 15, 0, 0);
  my $term_ok = defined $sent && ($sent == 0 || ($sent < 0 && $!{ESRCH}));
  return 0 unless $term_ok;
  return 1 if $pre_reap->();
  my $killed = syscall($sys_pidfd_send_signal, $fd, 9, 0, 0);
  my $kill_ok = defined $killed && ($killed == 0 || ($killed < 0 && $!{ESRCH}));
  return 0 unless $kill_ok;
  return $pre_reap->();
};
my $abort_before_bind = sub {
  close $release_w;
  my $deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $cleanup_ok;
    if (defined $pre_fd && $pre_fd >= 0) {
      $cleanup_ok = $pre_terminate->($pre_fd);
    } else {
      $cleanup_ok = $pre_reap->();
    }
    last if $cleanup_ok;
    select undef, undef, undef, 0.05;
  }
  POSIX::close($pre_fd) if defined $pre_fd && $pre_fd >= 0;
  exit 125;
};
if (!defined $pre_fd || $pre_fd < 0) {
  $abort_before_bind->();
}
my $ready = "";
my $ready_count = sysread($ready_r, $ready, 1);
close $ready_r;
if (!$ready_count) {
  $abort_before_bind->();
}
if (defined $ENV{FM_TEST_ROOT_PID_FILE} && length $ENV{FM_TEST_ROOT_PID_FILE}) {
  my $record_ok = 1;
  my $record_info = $process_info->($pid);
  $record_ok = 0 unless defined $record_info && defined $record_info->{identity};
  if ($record_ok) {
    if (open my $record, ">", $ENV{FM_TEST_ROOT_PID_FILE}) {
      my $written = print $record "$record_info->{identity}\n";
      my $closed = close $record;
      $record_ok = 0 unless $written && $closed;
    } else {
      $record_ok = 0;
    }
  }
  if (!$record_ok) {
    $abort_before_bind->();
  }
}
my $bind_process = sub {
  my ($candidate, $expected_parent) = @_;
  my $opened = $pidfd_open->($candidate);
  return $opened if $opened->{gone};
  return { error => 1 } if $opened->{error};
  my $fd = $opened->{fd};
  my $info = $process_info->($candidate);
  if (!defined $info || !defined $info->{parent}) {
    my $gone = $pidfd_alive->($fd);
    POSIX::close($fd);
    return { gone => 1 } if defined $gone && !$gone;
    return { error => 1 };
  }
  my $alive = $pidfd_alive->($fd);
  if (!defined $alive) {
    POSIX::close($fd);
    return { error => 1 };
  }
  if (!$alive) {
    POSIX::close($fd);
    return { gone => 1 };
  }
  if ($info->{parent} != $expected_parent) {
    POSIX::close($fd);
    return { error => 1 };
  }
  return { fd => $fd, identity => $info->{identity} };
};
my $root = $ENV{FM_TEST_FORCE_ROOT_HANDLE_FAILURE} ? { error => 1 } : $bind_process->($pid, $$);
if ($root->{gone} || $root->{error}) {
  $abort_before_bind->();
}
syswrite($release_w, "1") == 1 or $abort_before_bind->();
close $release_w;
POSIX::close($pre_fd);
$pre_fd = undef;
my %tracked = ($pid => $root);
my $tracking_ok = 1;
my @signal_numbers = (HUP => 1, INT => 2, QUIT => 3, TERM => 15, KILL => 9, TSTP => 20, CONT => 18);
my %signal_numbers = @signal_numbers;
my $refresh_tracked = sub {
  my %seen;
  my @queue = ($$, keys %tracked);
  while (@queue) {
    my $parent = shift @queue;
    next if $seen{$parent}++;
    if ($parent != $$) {
      my $parent_entry = $tracked{$parent};
      next unless defined $parent_entry;
      my $parent_alive = $pidfd_alive->($parent_entry->{fd});
      if (!defined $parent_alive) {
        $tracking_ok = 0;
        return;
      }
      if (!$parent_alive) {
        $close_handle->($parent_entry);
        delete $tracked{$parent};
        next;
      }
    }
    my $children = $read_children->($parent);
    if (!defined $children) {
      $tracking_ok = 0;
      return;
    }
    for my $child (@$children) {
      next if $child == $$;
      if (exists $tracked{$child}) {
        my $entry = $tracked{$child};
        my $alive = $pidfd_alive->($entry->{fd});
        if (!defined $alive) {
          $tracking_ok = 0;
          return;
        }
        if ($alive) {
          my $info = $process_info->($child);
          if (!defined $info || !defined $info->{parent} || $info->{parent} != $parent || $info->{identity} ne $entry->{identity}) {
            $tracking_ok = 0;
            return;
          }
          push @queue, $child;
          next;
        }
        $close_handle->($entry);
        delete $tracked{$child};
      }
      my $bound = $bind_process->($child, $parent);
      next if $bound->{gone};
      if ($bound->{error}) {
        $tracking_ok = 0;
        return;
      }
      $tracked{$child} = $bound;
      push @queue, $child;
    }
  }
};
my $signal_tracked = sub {
  my $signal = shift;
  my $number = $signal_numbers{$signal};
  if (!defined $number) {
    $tracking_ok = 0;
    return;
  }
  for my $tracked_pid (keys %tracked) {
    my $entry = $tracked{$tracked_pid};
    my $alive = $pidfd_alive->($entry->{fd});
    if (!defined $alive) {
      $tracking_ok = 0;
      next;
    }
    if (!$alive) {
      $close_handle->($entry);
      delete $tracked{$tracked_pid};
      next;
    }
    my $info = $process_info->($tracked_pid);
    if (!defined $info || $info->{identity} ne $entry->{identity}) {
      $tracking_ok = 0;
      next;
    }
    my $sent = $pidfd_signal->($entry->{fd}, $number);
    if (!defined $sent) {
      $tracking_ok = 0;
      next;
    }
    if (!$sent) {
      $close_handle->($entry);
      delete $tracked{$tracked_pid};
    }
  }
};
my $signal_group = sub {
  my $signal = shift;
  my $root_entry = $tracked{$pid};
  return unless defined $root_entry;
  my $alive = $pidfd_alive->($root_entry->{fd});
  if (!defined $alive) {
    $tracking_ok = 0;
    return;
  }
  return unless $alive;
  my $info = $process_info->($pid);
  if (!defined $info || $info->{identity} ne $root_entry->{identity} || $info->{parent} != $$) {
    $tracking_ok = 0;
    return;
  }
  my $probe = kill 0, -$pid;
  if ($probe) {
    kill $signal, -$pid or $tracking_ok = 0;
  } elsif (!$probe && !$!{ESRCH}) {
    $tracking_ok = 0;
  }
};
my $group_gone = sub {
  my $root_entry = $tracked{$pid};
  return 1 unless defined $root_entry;
  my $alive = $pidfd_alive->($root_entry->{fd});
  if (!defined $alive) {
    $tracking_ok = 0;
    return 0;
  }
  return 1 unless $alive;
  my $info = $process_info->($pid);
  if (!defined $info || $info->{identity} ne $root_entry->{identity} || $info->{parent} != $$) {
    $tracking_ok = 0;
    return 0;
  }
  for (1 .. 20) {
    my $probe = kill 0, -$pid;
    return 1 if !$probe && $!{ESRCH};
    return 0 if !$probe;
    select undef, undef, undef, 0.1;
  }
  return 0;
};
my $tracked_gone = sub {
  for my $tracked_pid (keys %tracked) {
    my $entry = $tracked{$tracked_pid};
    my $alive = $pidfd_alive->($entry->{fd});
    if (!defined $alive) {
      $tracking_ok = 0;
      return 0;
    }
    if (!$alive) {
      $close_handle->($entry);
      delete $tracked{$tracked_pid};
      next;
    }
    my $info = $process_info->($tracked_pid);
    if (!defined $info || $info->{identity} ne $entry->{identity}) {
      $tracking_ok = 0;
      return 0;
    }
    return 0;
  }
  return 1;
};
my $reap_nonblocking = sub {
  my $reaped;
  while (($reaped = waitpid(-1, WNOHANG)) > 0) {
  }
  return 1 if $reaped < 0 && $!{ECHILD};
  return 0 if $reaped == 0;
  $tracking_ok = 0;
  return 0;
};
my $reap_until_empty = sub {
  for (1 .. 40) {
    my $reaped;
    while (($reaped = waitpid(-1, WNOHANG)) > 0) {
    }
    return 1 if $reaped < 0 && $!{ECHILD};
    if ($reaped < 0 && !$!{ECHILD}) {
      $tracking_ok = 0;
      return 0;
    }
    select undef, undef, undef, 0.05;
  }
  return 0;
};
my $stop = sub {
  my ($signal, $code) = @_;
  $refresh_tracked->();
  $SIG{ALRM} = $SIG{HUP} = $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = $SIG{TSTP} = $SIG{CONT} = "IGNORE";
  sigprocmask(SIG_BLOCK, $blocked);
  $signal_group->($signal);
  $signal_tracked->($signal);
  select undef, undef, undef, 0.2;
  $refresh_tracked->();
  $signal_group->("KILL");
  $signal_tracked->("KILL");
  my $reaped = $reap_until_empty->();
  $refresh_tracked->();
  exit 125 unless $reaped && $tracking_ok && $group_gone->() && $tracked_gone->();
  exit $code;
};
$SIG{ALRM} = sub { $stop->("TERM", 124) };
$SIG{HUP} = sub { $stop->("HUP", 129) };
$SIG{INT} = sub { $stop->("INT", 130) };
$SIG{QUIT} = sub { $stop->("QUIT", 131) };
$SIG{TERM} = sub { $stop->("TERM", 143) };
my $suspend;
$suspend = sub {
  kill "TSTP", -$pid;
  $SIG{TSTP} = "DEFAULT";
  kill "TSTP", $$;
  $SIG{TSTP} = $suspend;
};
$SIG{TSTP} = $suspend;
$SIG{CONT} = sub { kill "CONT", -$pid };
$refresh_tracked->();
alarm $seconds;
defined(sigprocmask(SIG_SETMASK, $old)) or exit 125;
my $waited;
while (1) {
  $waited = waitpid $pid, WNOHANG;
  last if $waited == $pid;
  exit 125 if $waited < 0 && !$!{EINTR};
  select undef, undef, undef, 0.02;
}
my $status = $?;
alarm 0;
exit 125 if $waited < 0;
$refresh_tracked->();
if (!$tracking_ok || !$reap_nonblocking->() || !$group_gone->() || !$tracked_gone->()) {
  $stop->("TERM", 125);
}
exit(128 + ($status & 127)) if $status & 127;
exit($status >> 8);
'
FM_TEST_SUPERVISOR_HANDLE_PERL='
use Config;
use Errno qw(ECHILD EINTR EIO EPERM ESRCH);
use Fcntl qw(O_NONBLOCK O_WRONLY);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my ($input_path, $output_path) = @ARGV;
my $arch = $Config{archname} // "";
my ($sys_prctl, $sys_pidfd_open, $sys_pidfd_send_signal);
if ($arch =~ /(?:x86_64|amd64)/) {
  $sys_prctl = 157;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
} elsif ($arch =~ /(?:aarch64|riscv64|s390x|ppc64|i[3-6]86|arm)/) {
  $sys_prctl = 167 if $arch =~ /(?:aarch64|riscv64|s390x)/;
  $sys_prctl = 171 if $arch =~ /ppc64/;
  $sys_prctl = 172 if $arch =~ /(?:i[3-6]86|arm)/;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
}
defined $sys_prctl && defined $sys_pidfd_open && defined $sys_pidfd_send_signal or exit 125;
my $parent = getppid();
syscall($sys_prctl, 1, 15, 0, 0, 0) == 0 or exit 125;
exit 125 if getppid() != $parent;
open my $input, "<", $input_path or exit 125;
open my $output, ">", $output_path or exit 125;
select $output;
$| = 1;
my $identity = sub {
  my ($pid) = @_;
  open my $stat, "<", "/proc/$pid/stat" or return;
  my $line = <$stat>;
  close $stat;
  return unless defined $line;
  my $comm_end = rindex($line, ")");
  return if $comm_end < 0;
  my @fields = split /\s+/, substr($line, $comm_end + 2);
  my $start = $fields[19];
  return unless defined $start && $start =~ /^\d+\z/;
  return "$pid:$start";
};
my $probe_fd = sub {
  my ($fd) = @_;
  my $result = syscall($sys_pidfd_send_signal, $fd, 0, 0, 0);
  return 1 if defined $result && $result == 0;
  return 0 if defined $result && $result < 0 && $!{ESRCH};
  return;
};
my $reap_pid = sub {
  my ($pid, $deadline) = @_;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
my %handles;
my $close_handle = sub {
  my ($entry) = @_;
  my $command_fh = $entry->{command};
  my $response_fh = $entry->{response};
  close $command_fh if defined $command_fh;
  close $response_fh if defined $response_fh;
  POSIX::close($entry->{fd}) if defined $entry->{fd} && $entry->{fd} >= 0;
  $entry->{command} = undef;
  $entry->{response} = undef;
  $entry->{fd} = undef;
};
my $owner_request = sub {
  my ($entry, $command) = @_;
  my $wire = "$command\n";
  my $written = syswrite($entry->{command}, $wire);
  return unless defined $written && $written == length($wire);
  my $response_fh = $entry->{response};
  my $response = <$response_fh>;
  return unless defined $response;
  chomp $response;
  return $response;
};
my $owner_reap = sub {
  my ($entry) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE}) {
    $! = EIO;
    return 0;
  }
  my $response = $owner_request->($entry, "wait");
  return 0 unless defined $response;
  return 0 if $response =~ /\|running\z/;
  return 0 unless $response =~ /\|exit\|/;
  return $reap_pid->($entry->{pid}, clock_gettime(CLOCK_MONOTONIC) + 2);
};
my $owner_terminate = sub {
  my ($entry) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_JOB_PIDFD_SIGNAL_FAILURE}) {
    $! = EPERM;
    return 0;
  }
  my $response = $owner_request->($entry, "terminate");
  return 0 unless defined $response && $response =~ /\|(terminated|gone)\z/;
  return $reap_pid->($entry->{pid}, clock_gettime(CLOCK_MONOTONIC) + 2);
};
if ($ENV{FM_TEST_SUPERVISOR_BLOCK_FIFO}) {
  while (1) {
    my $blocked = "";
    my $count = sysread($input, $blocked, 1);
    next if !defined $count && $!{EINTR};
    select undef, undef, undef, 0.02 if defined $count && $count == 0;
    exit 125 if !defined $count && !$!{EINTR};
  }
}
while (my $line = <$input>) {
  chomp $line;
  my @parts = index($line, "\t") >= 0 ? split(/\t/, $line) : split(/\|/, $line, 4);
  my $command = shift @parts // "";
  if ($command eq "ping") {
    print "ping|ready\n";
    next;
  }
  if ($command eq "launch" && @parts == 10) {
    my ($key, $runner, $test_path, $job_root, $log_path, $start_gate, $abort_gate, $test_root, $timeout, $bounded_script) = @parts;
    my ($command_r, $command_w, $response_r, $response_w);
    if (!pipe($command_r, $command_w)) {
      print "$key|error-pipe\n";
      next;
    }
    if (!pipe($response_r, $response_w)) {
      close $command_r;
      close $command_w;
      print "$key|error-pipe\n";
      next;
    }
    my $owner_pid = fork;
    if (!defined $owner_pid) {
      print "$key|error-fork\n";
      next;
    }
    if (!$owner_pid) {
      close $command_w;
      close $response_r;
      my $owner_parent = getppid();
      syscall($sys_prctl, 1, 15, 0, 0, 0) == 0 or exit 125;
      exit 125 if getppid() != $owner_parent;
      my $owner_identity = $identity->($$);
      defined $owner_identity or exit 125;
      if (defined $ENV{FM_TEST_SUPERVISOR_JOB_REAPER_PID_FILE} && length $ENV{FM_TEST_SUPERVISOR_JOB_REAPER_PID_FILE}) {
        open my $record, ">", $ENV{FM_TEST_SUPERVISOR_JOB_REAPER_PID_FILE} or exit 125;
        print $record "$owner_identity\n";
        close $record or exit 125;
      }
      select $response_w;
      $| = 1;
      my $job_pid = fork;
      defined $job_pid or exit 125;
      if (!$job_pid) {
        my $job_parent = getppid();
        syscall($sys_prctl, 1, 15, 0, 0, 0) == 0 or exit 125;
        exit 125 if getppid() != $job_parent;
        exec "/usr/bin/bash", $runner, $test_path, $job_root, $log_path, $start_gate, $abort_gate, $test_root, $timeout, $bounded_script;
        exit 127;
      }
      my $job_fd = $ENV{FM_TEST_SUPERVISOR_FORCE_JOB_PIDFD_OPEN_FAILURE}
        ? -1
        : syscall($sys_pidfd_open, $job_pid, 0);
      if (!defined $job_fd || $job_fd < 0) {
        if (open my $abort, ">", $abort_gate) {
          close $abort;
        }
        $reap_pid->($job_pid, clock_gettime(CLOCK_MONOTONIC) + 4) or exit 125;
        print $response_w "error-open\n";
        exit 125;
      }
      my $job_identity = $identity->($job_pid);
      if (!defined $job_identity) {
        if (open my $abort, ">", $abort_gate) {
          close $abort;
        }
        syscall($sys_pidfd_send_signal, $job_fd, 15, 0, 0, 0);
        $reap_pid->($job_pid, clock_gettime(CLOCK_MONOTONIC) + 4) or exit 125;
        POSIX::close($job_fd);
        print $response_w "error-identity\n";
        exit 125;
      }
      if (defined $ENV{FM_TEST_SUPERVISOR_JOB_PID_FILE} && length $ENV{FM_TEST_SUPERVISOR_JOB_PID_FILE}) {
        open my $record, ">", $ENV{FM_TEST_SUPERVISOR_JOB_PID_FILE} or exit 125;
        print $record "$job_identity\n";
        close $record or exit 125;
      }
      my $ready_wire = "ready|$job_pid|$job_identity\n";
      syswrite($response_w, $ready_wire) == length($ready_wire) or exit 125;
      delete @ENV{qw(FM_TEST_SUPERVISOR_FORCE_JOB_PIDFD_SIGNAL_FAILURE FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE)};
      my $custody_acknowledged = 0;
      my $send_custody = sub {
        return 1 if $custody_acknowledged;
        my $custody_path = $ENV{FM_TEST_SUPERVISOR_REAPER_CUSTODY_PATH};
        return 0 unless defined $custody_path && length $custody_path;
        sysopen my $custody, $custody_path, O_NONBLOCK | O_WRONLY or return 0;
        my $wire = "custody|$job_pid|$job_identity|$$|$owner_identity\n";
        my $written = syswrite($custody, $wire);
        close $custody;
        return 0 unless defined $written && $written == length($wire);
        my $ack_path = $ENV{FM_TEST_SUPERVISOR_JOB_REAP_FAILURE_RECEIPT};
        return 0 unless defined $ack_path && length $ack_path;
        my $ack = "custody-accepted|$job_identity|$owner_identity\n";
        my $deadline = clock_gettime(CLOCK_MONOTONIC) + 2;
        while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
          if (open my $receipt, "<", $ack_path) {
            local $/;
            my $contents = <$receipt> // "";
            close $receipt;
            if ($contents eq $ack) {
              $custody_acknowledged = 1;
              return 1;
            }
          }
          select undef, undef, undef, 0.02;
        }
        return 0;
      };
      my $job_status;
      my $stop = 0;
      $SIG{INT} = sub { $stop = 1 };
      $SIG{TERM} = sub { $stop = 1 };
      my $reap_job = sub {
        return 1 if defined $job_status;
        my $waited = waitpid($job_pid, WNOHANG);
        if ($ENV{FM_TEST_SUPERVISOR_FORCE_JOB_PIDFD_REAP_FAILURE}) {
          $! = EIO;
          return 0;
        }
        if ($waited == $job_pid) {
          $job_status = $?;
          return 1;
        }
        return 0 if $waited == 0 || ($waited < 0 && $!{EINTR});
        $job_status = 125 << 8 if $waited < 0 && $!{ECHILD};
        return defined $job_status;
      };
      my $terminate_job = sub {
        my $deadline = clock_gettime(CLOCK_MONOTONIC) + 4;
        my $sent = syscall($sys_pidfd_send_signal, $job_fd, 15, 0, 0, 0);
        my $term_ok = defined $sent && ($sent == 0 || ($sent < 0 && $!{ESRCH}));
        return 0 unless $term_ok;
        while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
          return 1 if $reap_job->();
          select undef, undef, undef, 0.02;
        }
        return 1 if $reap_job->();
        my $killed = syscall($sys_pidfd_send_signal, $job_fd, 9, 0, 0, 0);
        my $kill_ok = defined $killed && ($killed == 0 || ($killed < 0 && $!{ESRCH}));
        return 0 unless $kill_ok;
        while (clock_gettime(CLOCK_MONOTONIC) < $deadline + 2) {
          return 1 if $reap_job->();
          select undef, undef, undef, 0.02;
        }
        return $reap_job->();
      };
      my $terminate_forever = sub {
        delete @ENV{qw(FM_TEST_SUPERVISOR_FORCE_JOB_PIDFD_SIGNAL_FAILURE FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE)};
        my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
        while (!$terminate_job->()) {
          exit 125 if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
          select undef, undef, undef, 0.05;
        }
        POSIX::close($job_fd);
        exit 125;
      };
      my $buffer = "";
      while (1) {
        $reap_job->();
        if ($stop) {
          $terminate_forever->() unless defined $job_status;
          POSIX::close($job_fd);
          exit 125;
        }
        my $readable = "";
        vec($readable, fileno($command_r), 1) = 1;
        my $selected = select($readable, undef, undef, 0.05);
        next unless defined $selected && $selected > 0 && vec($readable, fileno($command_r), 1);
        my $chunk = "";
        my $count = sysread($command_r, $chunk, 4096);
        if (!defined $count) {
          next if $!{EAGAIN} || $!{EINTR};
          $stop = 1;
          next;
        }
        if ($count == 0) {
          $stop = 1;
          next;
        }
        $buffer .= $chunk;
        while ($buffer =~ s/^([^\n]*)\n//) {
          my $request = $1;
          if ($request eq "terminate") {
            if ($terminate_job->()) {
              print $response_w "terminated\n";
              POSIX::close($job_fd);
              exit 125;
            }
            print $response_w "unproven\n";
          } elsif ($request eq "signal") {
            my $sent = syscall($sys_pidfd_send_signal, $job_fd, 15, 0, 0, 0);
            print $response_w (defined $sent && $sent == 0 ? "signaled\n" : (defined $sent && $sent < 0 && $!{ESRCH} ? "gone\n" : "error\n"));
          } elsif ($request eq "state") {
            my $alive = $probe_fd->($job_fd);
            print $response_w (!defined $alive ? "error\n" : $alive ? "alive\n" : "gone\n");
          } elsif ($request eq "wait") {
            my $reaped = $reap_job->();
            if (!$reaped && $ENV{FM_TEST_SUPERVISOR_FORCE_JOB_PIDFD_REAP_FAILURE}) {
              my $transferred = $send_custody->();
              print $response_w ($transferred ? "reap-error\n" : "error\n");
            } else {
              print $response_w (defined $job_status ? "exit|$job_status\n" : "running\n");
            }
          } elsif ($request eq "close") {
            $reap_job->();
            if (defined $job_status) {
              POSIX::close($job_fd);
              print $response_w "closed\n";
              exit 0;
            }
            print $response_w "error\n";
          } else {
            print $response_w "error\n";
          }
        }
      }
    }
    close $command_r;
    close $response_w;
    my $owner_command = $command_w;
    my $owner_response = $response_r;
    my $ready = <$owner_response>;
    chomp $ready if defined $ready;
    if (!defined $ready || $ready !~ /^ready\|(\d+)\|([^\n]+)$/) {
      close $owner_command;
      close $owner_response;
      $reap_pid->($owner_pid, clock_gettime(CLOCK_MONOTONIC) + 4) or exit 125;
      print "$key|error-open\n";
      next;
    }
    my ($job_pid, $job_identity) = ($1, $2);
    my $owner_fd = syscall($sys_pidfd_open, $owner_pid, 0);
    if (!defined $owner_fd || $owner_fd < 0) {
      print $owner_command "terminate\n";
      close $owner_command;
      close $owner_response;
      $reap_pid->($owner_pid, clock_gettime(CLOCK_MONOTONIC) + 4) or exit 125;
      print "$key|error-open\n";
      next;
    }
    my $entry = { fd => $owner_fd, pid => $owner_pid, command => $owner_command, response => $owner_response, job_pid => $job_pid, job_identity => $job_identity };
    my $abort_launch = sub {
      my ($error) = @_;
      if ($owner_terminate->($entry)) {
        $close_handle->($entry);
        print "$key|$error\n";
        return 1;
      }
      $handles{"__abort-$owner_pid"} = $entry;
      print "$key|$error\n";
      return 0;
    };
    if ($ENV{FM_TEST_FORCE_SUPERVISOR_IDENTITY_FAILURE}) {
      $abort_launch->("error-identity");
      next;
    }
    my $alive = $probe_fd->($owner_fd);
    if (!defined $alive || !$alive) {
      $abort_launch->("error-probe");
      next;
    }
    $handles{$key} = $entry;
    next if $ENV{FM_TEST_SUPERVISOR_DROP_LAUNCH_RESPONSE};
    print "$key|registered|$job_pid|$job_identity\n";
    next;
  }
  if (($command eq "abort" || $command eq "shutdown") && (($command eq "abort" && @parts == 1) || ($command eq "shutdown" && !@parts))) {
    my @keys = $command eq "abort" ? ($parts[0]) : keys %handles;
    my $ok = 1;
    for my $key (@keys) {
      my $entry = $handles{$key};
      next unless defined $entry;
      if ($owner_terminate->($entry)) {
        $close_handle->($entry);
        delete $handles{$key};
      } else {
        $ok = 0;
      }
    }
    if ($command eq "abort") {
      print "$parts[0]|" . ($ok ? "aborted" : "error") . "\n";
    } else {
      print $ok ? "shutdown|done\n" : "shutdown|error\n";
      last;
    }
    next;
  }
  if ($command eq "wait" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE}) {
      if (defined $ENV{FM_TEST_SUPERVISOR_READY_FILE} && length $ENV{FM_TEST_SUPERVISOR_READY_FILE}) {
        my $ready = 0;
        for (1 .. 200) {
          if (-e $ENV{FM_TEST_SUPERVISOR_READY_FILE}) {
            $ready = 1;
            last;
          }
          select undef, undef, undef, 0.01;
        }
        unless ($ready) {
          print "$key|error\n";
          next;
        }
      }
      $! = EIO;
      print "$key|error\n";
      next;
    }
    my $response = defined $entry ? $owner_request->($entry, "wait") : undef;
    if (!defined $response) {
      print "$key|error\n";
    } elsif ($response eq "running") {
      print "$key|running\n";
    } elsif ($response =~ /^exit\|(\d+)$/) {
      print "$key|exit|$1\n";
    } else {
      print "$key|error\n";
    }
    next;
  }
  if ($command eq "signal" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    my $response = defined $entry ? $owner_request->($entry, "signal") : undef;
    print "$key|" . (!defined $response ? "error" : $response) . "\n";
    next;
  }
  if ($command eq "state" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    my $response = defined $entry ? $owner_request->($entry, "state") : undef;
    print "$key|" . (!defined $response ? "error" : $response) . "\n";
    next;
  }
  if ($command eq "close" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    my $response = defined $entry ? $owner_request->($entry, "close") : undef;
    if (defined $response && $response eq "closed") {
      $close_handle->($entry);
      delete $handles{$key};
      print "$key|closed\n";
    } else {
      print "$key|error\n";
    }
    next;
  }
  print "error|malformed\n";
}
for my $key (keys %handles) {
  my $entry = $handles{$key};
  if ($owner_terminate->($entry)) {
    $close_handle->($entry);
    delete $handles{$key};
  }
}
exit 125 if keys %handles;
exit 0;
'
FM_TEST_SUPERVISOR_GUARD_WORKER_PERL='
use Config;
use Errno qw(ECHILD EINTR EIO EPERM ESRCH);
use Fcntl qw(F_SETFD);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my ($worker_path, $input_path, $output_path) = @ARGV;
my $arch = $Config{archname} // "";
my ($sys_prctl, $sys_pidfd_open, $sys_pidfd_send_signal);
if ($arch =~ /(?:x86_64|amd64)/) {
  $sys_prctl = 157;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
} elsif ($arch =~ /(?:aarch64|riscv64|s390x|ppc64|i[3-6]86|arm)/) {
  $sys_prctl = 167 if $arch =~ /(?:aarch64|riscv64|s390x)/;
  $sys_prctl = 171 if $arch =~ /ppc64/;
  $sys_prctl = 172 if $arch =~ /(?:i[3-6]86|arm)/;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
}
defined $sys_prctl && defined $sys_pidfd_open && defined $sys_pidfd_send_signal or exit 125;
my $parent = getppid();
syscall($sys_prctl, 1, 15, 0, 0, 0) == 0 or exit 125;
exit 125 if getppid() != $parent;
pipe(my $gate_r, my $gate_w) or exit 125;
defined fcntl($gate_r, F_SETFD, 0) or exit 125;
my $pid = fork;
defined $pid or exit 125;
if (!$pid) {
  close $gate_w;
  my $release = "";
  my $release_count = sysread($gate_r, $release, 1);
  close $gate_r;
  exit 125 unless $release_count == 1 && $release eq "1";
  exec $^X, $worker_path, $input_path, $output_path;
  exit 127;
}
close $gate_r;
my $fd = $ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_OPEN_FAILURE}
  ? -1
  : syscall($sys_pidfd_open, $pid, 0);
my $reap_bounded = sub {
  my ($until) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE}) {
    $! = EIO;
    return 0;
  }
  for (1 .. 100) {
    return 0 if defined $until && clock_gettime(CLOCK_MONOTONIC) >= $until;
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
if (!defined $fd || $fd < 0) {
  close $gate_w;
  delete $ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE};
  my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
  while (!$reap_bounded->($cleanup_deadline)) {
    last if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
    select undef, undef, undef, 0.05;
  }
  exit 125;
}
my $terminate = sub {
  my ($deadline) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE}) {
    $! = EPERM;
    return 0;
  }
  my $sent = syscall($sys_pidfd_send_signal, $fd, 15, 0, 0);
  my $term_ok = defined $sent && ($sent == 0 || ($sent < 0 && $!{ESRCH}));
  return 0 unless $term_ok;
  my $reap_until = sub {
    my ($until) = @_;
    while (clock_gettime(CLOCK_MONOTONIC) < $until) {
      my $waited = waitpid($pid, WNOHANG);
      return 1 if $waited == $pid;
      return 1 if $waited < 0 && $!{ECHILD};
      return 0 if $waited < 0 && !$!{EINTR};
      my $remaining = $until - clock_gettime(CLOCK_MONOTONIC);
      last if $remaining <= 0;
      select undef, undef, undef, $remaining < 0.02 ? $remaining : 0.02;
    }
    return 0;
  };
  my $term_deadline = clock_gettime(CLOCK_MONOTONIC) + 2;
  $term_deadline = $deadline if $term_deadline > $deadline;
  return 1 if $reap_until->($term_deadline);
  return 0 if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
  my $killed = syscall($sys_pidfd_send_signal, $fd, 9, 0, 0);
  my $kill_ok = defined $killed && ($killed == 0 || ($killed < 0 && $!{ESRCH}));
  return 0 unless $kill_ok;
  return $reap_until->($deadline);
};
my $terminate_until_proven = sub {
  delete @ENV{qw(FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE)};
  my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
  while (!$terminate->(clock_gettime(CLOCK_MONOTONIC) + 4)) {
    exit 125 if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
    select undef, undef, undef, 0.05;
  }
  return 1;
};
my $abort_before_release = sub {
  close $gate_w;
  $terminate_until_proven->();
  POSIX::close($fd);
  exit 125;
};
my $probe = syscall($sys_pidfd_send_signal, $fd, 0, 0, 0);
if (!defined $probe || $probe != 0) {
  $abort_before_release->();
}
if (defined $ENV{FM_TEST_SUPERVISOR_BROKER_PID_FILE} &&
    length $ENV{FM_TEST_SUPERVISOR_BROKER_PID_FILE}) {
  open my $record, ">", $ENV{FM_TEST_SUPERVISOR_BROKER_PID_FILE} or $abort_before_release->();
  print $record "$pid:";
  open my $stat, "<", "/proc/$pid/stat" or $abort_before_release->();
  my $line = <$stat>;
  close $stat;
  my $comm_end = defined $line ? rindex($line, ")") : -1;
  $abort_before_release->() if $comm_end < 0;
  my @fields = split /\s+/, substr($line, $comm_end + 2);
  my $start = $fields[19];
  $abort_before_release->() unless defined $start && $start =~ /^\d+\z/;
  print $record "$start\n";
  close $record or $abort_before_release->();
}
my $finish = sub {
  my ($status) = @_;
  POSIX::close($fd);
  exit $status;
};
my $terminate_command = sub {
  my $waited = waitpid($pid, WNOHANG);
  $finish->($?) if $waited == $pid;
  $finish->(125) if $waited < 0 && !$!{EINTR};
  $terminate_until_proven->();
  POSIX::close($fd);
  exit 125;
};
$SIG{INT} = $terminate_command;
$SIG{TERM} = $terminate_command;
syswrite($gate_w, "1") == 1 or $abort_before_release->();
close $gate_w;
while (1) {
  my $waited = waitpid($pid, WNOHANG);
  $finish->($?) if $waited == $pid;
  $finish->(125) if $waited < 0 && !$!{EINTR};
  select undef, undef, undef, 0.05;
}
'
FM_TEST_SUPERVISOR_GUARD_PERL='
use Config;
use Errno qw(ECHILD EINTR EIO EPERM ESRCH);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my ($guard_worker_path, $worker_path, $input_path, $output_path, $release_fd) = @ARGV;
my $arch = $Config{archname} // "";
my ($sys_prctl, $sys_pidfd_open, $sys_pidfd_send_signal);
if ($arch =~ /(?:x86_64|amd64)/) {
  $sys_prctl = 157;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
} elsif ($arch =~ /(?:aarch64|riscv64|s390x|ppc64|i[3-6]86|arm)/) {
  $sys_prctl = 167 if $arch =~ /(?:aarch64|riscv64|s390x)/;
  $sys_prctl = 171 if $arch =~ /ppc64/;
  $sys_prctl = 172 if $arch =~ /(?:i[3-6]86|arm)/;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
}
defined $sys_prctl && defined $sys_pidfd_open && defined $sys_pidfd_send_signal or exit 125;
my $parent = getppid();
syscall($sys_prctl, 1, 15, 0, 0, 0) == 0 or exit 125;
exit 125 if getppid() != $parent;
open my $release, "<&=$release_fd" or exit 125;
my $release_value = "";
my $release_count = sysread($release, $release_value, 1);
close $release;
exit 125 unless $release_count == 1 && $release_value eq "1";
pipe(my $gate_r, my $gate_w) or exit 125;
my $pid = fork;
defined $pid or exit 125;
if (!$pid) {
  close $gate_w;
  my $release = "";
  my $release_count = sysread($gate_r, $release, 1);
  close $gate_r;
  exit 125 unless $release_count == 1 && $release eq "1";
  exec $^X, $guard_worker_path, $worker_path, $input_path, $output_path;
  exit 127;
}
close $gate_r;
my $guard_fd = $ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_OPEN_FAILURE}
  ? -1
  : syscall($sys_pidfd_open, $pid, 0);
my $reap_bounded = sub {
  my ($until) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE}) {
    $! = EIO;
    return 0;
  }
  for (1 .. 100) {
    return 0 if defined $until && clock_gettime(CLOCK_MONOTONIC) >= $until;
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
if (!defined $guard_fd || $guard_fd < 0) {
  close $gate_w;
  delete $ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE};
  my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
  while (!$reap_bounded->($cleanup_deadline)) {
    last if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
    select undef, undef, undef, 0.05;
  }
  exit 125;
}
my $terminate = sub {
  my ($deadline) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE}) {
    $! = EPERM;
    return 0;
  }
  my $sent = syscall($sys_pidfd_send_signal, $guard_fd, 15, 0, 0);
  my $term_ok = defined $sent && ($sent == 0 || ($sent < 0 && $!{ESRCH}));
  return 0 unless $term_ok;
  my $reap_until = sub {
    my ($until) = @_;
    while (clock_gettime(CLOCK_MONOTONIC) < $until) {
      my $waited = waitpid($pid, WNOHANG);
      return 1 if $waited == $pid;
      return 1 if $waited < 0 && $!{ECHILD};
      return 0 if $waited < 0 && !$!{EINTR};
      my $remaining = $until - clock_gettime(CLOCK_MONOTONIC);
      last if $remaining <= 0;
      select undef, undef, undef, $remaining < 0.02 ? $remaining : 0.02;
    }
    return 0;
  };
  my $term_deadline = clock_gettime(CLOCK_MONOTONIC) + 2;
  $term_deadline = $deadline if $term_deadline > $deadline;
  return 1 if $reap_until->($term_deadline);
  return 0 if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
  my $killed = syscall($sys_pidfd_send_signal, $guard_fd, 9, 0, 0);
  my $kill_ok = defined $killed && ($killed == 0 || ($killed < 0 && $!{ESRCH}));
  return 0 unless $kill_ok;
  return $reap_until->($deadline);
};
my $terminate_until_proven = sub {
  delete @ENV{qw(FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE)};
  my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
  while (!$terminate->(clock_gettime(CLOCK_MONOTONIC) + 4)) {
    exit 125 if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
    select undef, undef, undef, 0.05;
  }
  return 1;
};
my $abort_before_release = sub {
  close $gate_w;
  $terminate_until_proven->();
  POSIX::close($guard_fd);
  exit 125;
};
if (defined $ENV{FM_TEST_SUPERVISOR_WORKER_PID_FILE} &&
    length $ENV{FM_TEST_SUPERVISOR_WORKER_PID_FILE}) {
  open my $record, ">", $ENV{FM_TEST_SUPERVISOR_WORKER_PID_FILE} or $abort_before_release->();
  print $record "$pid:";
  open my $stat, "<", "/proc/$pid/stat" or $abort_before_release->();
  my $line = <$stat>;
  close $stat;
  my $comm_end = defined $line ? rindex($line, ")") : -1;
  $abort_before_release->() if $comm_end < 0;
  my @fields = split /\s+/, substr($line, $comm_end + 2);
  my $start = $fields[19];
  $abort_before_release->() unless defined $start && $start =~ /^\d+\z/;
  print $record "$start\n";
  close $record or $abort_before_release->();
}
my $guard_probe = syscall($sys_pidfd_send_signal, $guard_fd, 0, 0, 0);
if (!defined $guard_probe || $guard_probe != 0) {
  $abort_before_release->();
}
my $finish = sub {
  my ($status) = @_;
  POSIX::close($guard_fd);
  exit $status;
};
my $terminate_command = sub {
  my $waited = waitpid($pid, WNOHANG);
  $finish->($?) if $waited == $pid;
  $finish->(125) if $waited < 0 && !$!{EINTR};
  $terminate_until_proven->();
  POSIX::close($guard_fd);
  exit 125;
};
$SIG{INT} = $terminate_command;
$SIG{TERM} = $terminate_command;
syswrite($gate_w, "1") == 1 or $abort_before_release->();
close $gate_w;
while (1) {
  my $waited = waitpid($pid, WNOHANG);
  $finish->($?) if $waited == $pid;
  $finish->(125) if $waited < 0 && !$!{EINTR};
  select undef, undef, undef, 0.05;
}
'
FM_TEST_SUPERVISOR_GUARD_PARENT_PERL='
use Config;
use Errno qw(EAGAIN ECHILD EINTR EIO EPERM ESRCH);
use Fcntl qw(F_SETFD O_NONBLOCK O_RDONLY);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my ($guard_perl, $guard_worker_path, $worker_path, $input_path, $output_path, $control_path) = @ARGV;
my $arch = $Config{archname} // "";
my ($sys_prctl, $sys_pidfd_open, $sys_pidfd_send_signal);
if ($arch =~ /(?:x86_64|amd64)/) {
  $sys_prctl = 157;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
} elsif ($arch =~ /(?:aarch64|riscv64|s390x|ppc64|i[3-6]86|arm)/) {
  $sys_prctl = 167 if $arch =~ /(?:aarch64|riscv64|s390x)/;
  $sys_prctl = 171 if $arch =~ /ppc64/;
  $sys_prctl = 172 if $arch =~ /(?:i[3-6]86|arm)/;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
}
defined $sys_prctl && defined $sys_pidfd_open && defined $sys_pidfd_send_signal or exit 125;
my $parent = getppid();
syscall($sys_prctl, 1, 15, 0, 0, 0) == 0 or exit 125;
exit 125 if getppid() != $parent;
pipe(my $release_r, my $release_w) or exit 125;
defined fcntl($release_r, F_SETFD, 0) or exit 125;
my $pid = fork;
defined $pid or exit 125;
if (!$pid) {
  close $release_w;
  exec $^X, "-e", $guard_perl, $guard_worker_path, $worker_path, $input_path, $output_path, fileno($release_r);
  exit 127;
}
close $release_r;
my $reap_bounded = sub {
  my ($until) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE}) {
    $! = EIO;
    return 0;
  }
  for (1 .. 100) {
    return 0 if defined $until && clock_gettime(CLOCK_MONOTONIC) >= $until;
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
my $outer_fd = $ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_OPEN_FAILURE}
  ? -1
  : syscall($sys_pidfd_open, $pid, 0);
if (!defined $outer_fd || $outer_fd < 0) {
  close $release_w;
  delete $ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE};
  my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
  while (!$reap_bounded->($cleanup_deadline)) {
    last if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
    select undef, undef, undef, 0.05;
  }
  exit 125;
}
my $terminate = sub {
  my ($deadline) = @_;
  if ($ENV{FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE}) {
    $! = EPERM;
    return 0;
  }
  my $sent = syscall($sys_pidfd_send_signal, $outer_fd, 15, 0, 0);
  my $term_ok = defined $sent && ($sent == 0 || ($sent < 0 && $!{ESRCH}));
  return 0 unless $term_ok;
  my $reap_until = sub {
    my ($until) = @_;
    while (clock_gettime(CLOCK_MONOTONIC) < $until) {
      my $waited = waitpid($pid, WNOHANG);
      return 1 if $waited == $pid;
      return 1 if $waited < 0 && $!{ECHILD};
      return 0 if $waited < 0 && !$!{EINTR};
      my $remaining = $until - clock_gettime(CLOCK_MONOTONIC);
      last if $remaining <= 0;
      select undef, undef, undef, $remaining < 0.02 ? $remaining : 0.02;
    }
    return 0;
  };
  my $term_deadline = clock_gettime(CLOCK_MONOTONIC) + 2;
  $term_deadline = $deadline if $term_deadline > $deadline;
  return 1 if $reap_until->($term_deadline);
  return 0 if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
  my $killed = syscall($sys_pidfd_send_signal, $outer_fd, 9, 0, 0);
  my $kill_ok = defined $killed && ($killed == 0 || ($killed < 0 && $!{ESRCH}));
  return 0 unless $kill_ok;
  return $reap_until->($deadline);
};
my $terminate_until_proven = sub {
  delete @ENV{qw(FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE)};
  my $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
  while (!$terminate->(clock_gettime(CLOCK_MONOTONIC) + 4)) {
    exit 125 if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
    select undef, undef, undef, 0.05;
  }
  return 1;
};
my $finish = sub {
  my ($status) = @_;
  POSIX::close($outer_fd);
  exit $status;
};
my $stop = 0;
$SIG{INT} = sub { $stop = 1; };
$SIG{TERM} = sub { $stop = 1; };
my $abort_before_release = sub {
  close $release_w;
  $terminate_until_proven->();
  $finish->(125);
};
my $outer_probe = syscall($sys_pidfd_send_signal, $outer_fd, 0, 0, 0);
if (!defined $outer_probe || $outer_probe != 0) {
  $abort_before_release->();
}
if (defined $ENV{FM_TEST_SUPERVISOR_GUARD_PID_FILE} &&
    length $ENV{FM_TEST_SUPERVISOR_GUARD_PID_FILE}) {
  open my $record, ">", $ENV{FM_TEST_SUPERVISOR_GUARD_PID_FILE} or $abort_before_release->();
  print $record "$pid:";
  open my $stat, "<", "/proc/$pid/stat" or $abort_before_release->();
  my $line = <$stat>;
  close $stat;
  my $comm_end = defined $line ? rindex($line, ")") : -1;
  $abort_before_release->() if $comm_end < 0;
  my @fields = split /\s+/, substr($line, $comm_end + 2);
  my $start = $fields[19];
  $abort_before_release->() unless defined $start && $start =~ /^\d+\z/;
  print $record "$start\n";
  close $record or $abort_before_release->();
}
if (defined $ENV{FM_TEST_SUPERVISOR_DELAY_CONTROL_OPEN} &&
    length $ENV{FM_TEST_SUPERVISOR_DELAY_CONTROL_OPEN}) {
  my $released = 0;
  for (1 .. 200) {
    if (-e $ENV{FM_TEST_SUPERVISOR_DELAY_CONTROL_OPEN}) {
      $released = 1;
      last;
    }
    select undef, undef, undef, 0.01;
  }
  $abort_before_release->() unless $released;
}
sysopen my $control, $control_path, O_RDONLY | O_NONBLOCK or $abort_before_release->();
syswrite($release_w, "1") == 1 or $abort_before_release->();
close $release_w;
while (1) {
  my $waited = waitpid($pid, WNOHANG);
  $finish->($?) if $waited == $pid;
  $stop = 1 if $waited < 0 && !$!{EINTR};
  if ($stop) {
    $terminate_until_proven->();
    $finish->(0);
  }
  my $readable = "";
  vec($readable, fileno($control), 1) = 1;
  my $selected = select($readable, undef, undef, 0.05);
  next unless defined $selected && $selected > 0 && vec($readable, fileno($control), 1);
  my $command = "";
  my $count = sysread($control, $command, 4096);
  if (!defined $count) {
    next if $!{EAGAIN} || $!{EINTR};
    $stop = 1;
    next;
  }
  $stop = 1 if $count == 0 || $command =~ /(?:^|\n)terminate(?:\n|$)/;
}
'
FM_TEST_SUPERVISOR_REAPER_PERL='
use Config;
use Errno qw(EAGAIN ECHILD EINTR EIO ESRCH);
use Fcntl qw(F_GETFL F_SETFL O_CREAT O_NONBLOCK O_TRUNC O_WRONLY);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my ($guard_parent_perl, $guard_perl, $guard_worker_path, $worker_path, $input_path, $output_path, $control_path, $reaper_control_fd, $exit_path) = @ARGV;
my $arch = $Config{archname} // "";
my ($sys_prctl, $sys_pidfd_open, $sys_pidfd_send_signal);
if ($arch =~ /(?:x86_64|amd64)/) {
  $sys_prctl = 157;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
} elsif ($arch =~ /(?:aarch64|riscv64|s390x|ppc64|i[3-6]86|arm)/) {
  $sys_prctl = 167 if $arch =~ /(?:aarch64|riscv64|s390x)/;
  $sys_prctl = 171 if $arch =~ /ppc64/;
  $sys_prctl = 172 if $arch =~ /(?:i[3-6]86|arm)/;
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
}
defined $sys_prctl && defined $sys_pidfd_open && defined $sys_pidfd_send_signal or exit 125;
syscall($sys_prctl, 36, 1, 0, 0, 0) == 0 or exit 125;
my $stop = 0;
$SIG{INT} = sub { $stop = 1 };
$SIG{TERM} = sub { $stop = 1 };
my $pid = fork;
defined $pid or exit 125;
if (!$pid) {
  exec $^X, "-e", $guard_parent_perl, $guard_perl, $guard_worker_path, $worker_path, $input_path, $output_path, $control_path;
  exit 127;
}
my $fd = syscall($sys_pidfd_open, $pid, 0);
my $startup_error = 0;
my $exit_fd;
if (!sysopen($exit_fd, $exit_path, O_CREAT | O_TRUNC | O_WRONLY, 0600)) {
  $startup_error = 1;
}
if (!defined $fd || $fd < 0) {
  $fd = undef;
  $startup_error = 1;
}
my $identity = sub {
  my ($candidate) = @_;
  open my $stat, "<", "/proc/$candidate/stat" or return;
  my $line = <$stat>;
  close $stat;
  return unless defined $line;
  my $comm_end = rindex($line, ")");
  return if $comm_end < 0;
  my @fields = split /\s+/, substr($line, $comm_end + 2);
  my $start = $fields[19];
  return unless defined $start && $start =~ /^\d+\z/;
  return "$candidate:$start";
};
my $current = $identity->($pid);
if (!defined $current) {
  $startup_error = 1;
}
my $original_guard_live = sub {
  return 0 unless defined $current;
  my $observed = $identity->($pid);
  return defined $observed && $observed eq $current;
};
my $self_identity = sub {
  open my $stat, "<", "/proc/$$/stat" or return;
  my $line = <$stat>;
  close $stat;
  return unless defined $line;
  my $comm_end = rindex($line, ")");
  return if $comm_end < 0;
  my @fields = split /\s+/, substr($line, $comm_end + 2);
  my $start = $fields[19];
  return unless defined $start && $start =~ /^\d+\z/;
  return "$$:$start";
};
my $reaper_identity = $self_identity->();
if (!defined $reaper_identity) {
  $reaper_identity = "";
  $startup_error = 1;
}
if (defined $ENV{FM_TEST_SUPERVISOR_PID_FILE} && length $ENV{FM_TEST_SUPERVISOR_PID_FILE}) {
  if (defined $current && open my $record, ">", $ENV{FM_TEST_SUPERVISOR_PID_FILE}) {
    my $written = print $record "$current\n";
    my $closed = close $record;
    $startup_error = 1 unless $written && $closed;
  } else {
    $startup_error = 1;
  }
}
my $control;
if (!open($control, "<&=$reaper_control_fd")) {
  $startup_error = 1;
} else {
  my $flags = fcntl($control, F_GETFL, 0);
  if (!defined $flags || !defined fcntl($control, F_SETFL, $flags | O_NONBLOCK)) {
    close $control;
    undef $control;
    $startup_error = 1;
  }
}
my $control_buffer = "";
my $children = sub {
  open my $list, "<", "/proc/$$/task/$$/children" or return;
  local $/;
  my $data = <$list>;
  close $list;
  return unless defined $data && $data =~ /^\s*(?:\d+\s*)*\z/;
  my @pids = ($data =~ /(\d+)/g);
  return \@pids;
};
my $probe = sub {
  my ($child_fd) = @_;
  my $result = syscall($sys_pidfd_send_signal, $child_fd, 0, 0, 0);
  return 1 if defined $result && $result == 0;
  return 0 if defined $result && $result < 0 && $!{ESRCH};
  return;
};
my %adopted;
my $close_adopted = sub {
  my ($entry) = @_;
  POSIX::close($entry->{fd}) if defined $entry->{fd};
  $entry->{fd} = undef;
};
my $acquire_custody_fd = sub {
  my ($candidate, $expected) = @_;
  if (exists $adopted{$candidate}) {
    return unless $adopted{$candidate}{identity} eq $expected;
    return ($adopted{$candidate}{fd}, 0);
  }
  my $candidate_fd = syscall($sys_pidfd_open, $candidate, 0);
  return unless defined $candidate_fd && $candidate_fd >= 0;
  my $observed = $identity->($candidate);
  if (!defined $observed || $observed ne $expected) {
    POSIX::close($candidate_fd);
    return;
  }
  return ($candidate_fd, 1);
};
my $accept_custody = sub {
  my ($job_pid, $job_identity, $owner_pid, $owner_identity) = @_;
  return 0 if $job_pid == $owner_pid || $job_pid == $pid || $owner_pid == $pid;
  my ($job_fd, $job_new) = $acquire_custody_fd->($job_pid, $job_identity);
  return 0 unless defined $job_fd;
  my ($owner_fd, $owner_new) = $acquire_custody_fd->($owner_pid, $owner_identity);
  if (!defined $owner_fd) {
    POSIX::close($job_fd) if $job_new;
    return 0;
  }
  $adopted{$job_pid} = { fd => $job_fd, identity => $job_identity } if $job_new;
  $adopted{$owner_pid} = { fd => $owner_fd, identity => $owner_identity } if $owner_new;
  my $receipt_path = $ENV{FM_TEST_SUPERVISOR_JOB_REAP_FAILURE_RECEIPT};
  return 0 unless defined $receipt_path && length $receipt_path;
  my $receipt_line = "custody-accepted|$job_identity|$owner_identity\n";
  open my $receipt, ">", $receipt_path or return 0;
  my $written = print $receipt $receipt_line;
  my $closed = close $receipt;
  return $written && $closed;
};
my $refresh_adopted = sub {
  my $child_pids = $children->();
  return 0 unless defined $child_pids;
  my $ok = 1;
  for my $child_pid (@$child_pids) {
    next if exists $adopted{$child_pid};
    next if $child_pid == $pid && $original_guard_live->();
    my $child_fd = syscall($sys_pidfd_open, $child_pid, 0);
    if (!defined $child_fd || $child_fd < 0) {
      next if $!{ESRCH};
      $ok = 0;
      next;
    }
    my $child_identity = $identity->($child_pid);
    if (!defined $child_identity) {
      my $alive = $probe->($child_fd);
      POSIX::close($child_fd);
      next if defined $alive && !$alive;
      $ok = 0;
      next;
    }
    $adopted{$child_pid} = { fd => $child_fd, identity => $child_identity };
  }
  for my $child_pid (keys %adopted) {
    my $entry = $adopted{$child_pid};
    my $alive = $probe->($entry->{fd});
    if (!defined $alive) {
      $ok = 0;
      next;
    }
    if (!$alive) {
      $close_adopted->($entry);
      delete $adopted{$child_pid};
      next;
    }
    my $child_identity = $identity->($child_pid);
    if (!defined $child_identity || $child_identity ne $entry->{identity}) {
      $ok = 0;
    }
  }
  return $ok;
};
my $reap_adopted = sub {
  my $ok = 1;
  while (1) {
    my $waited = waitpid(-1, WNOHANG);
    last if $waited == 0;
    if ($waited < 0) {
      last if $!{ECHILD} || $!{EINTR};
      $ok = 0;
      last;
    }
    my $entry = $adopted{$waited};
    if (defined $entry) {
      $close_adopted->($entry);
      delete $adopted{$waited};
    }
  }
  return $ok;
};
my $adopted_gone = sub {
  $reap_adopted->() or return 0;
  my $ok = $refresh_adopted->();
  $reap_adopted->() or return 0;
  my $first = $children->();
  return 0 unless defined $first;
  return 0 if @$first || keys %adopted;
  select undef, undef, undef, 0.02;
  $reap_adopted->() or return 0;
  $ok = 0 unless $refresh_adopted->();
  $reap_adopted->() or return 0;
  my $second = $children->();
  return 0 unless defined $second;
  return 0 if @$second || keys %adopted;
  return $ok;
};
my $signal_adopted = sub {
  my ($signal) = @_;
  my $ok = $refresh_adopted->();
  for my $child_pid (keys %adopted) {
    my $entry = $adopted{$child_pid};
    my $sent = syscall($sys_pidfd_send_signal, $entry->{fd}, $signal, 0, 0);
    if (defined $sent && $sent == 0) {
      next;
    }
    if (defined $sent && $sent < 0 && $!{ESRCH}) {
      next;
    }
    $ok = 0;
  }
  return $ok;
};
my $cleanup_adopted = sub {
  my ($deadline, $kill_at) = @_;
  delete @ENV{qw(FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE)};
  my $killed = 0;
  my $term_ok = $signal_adopted->(15);
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    return 1 if $adopted_gone->();
    if (!$killed && clock_gettime(CLOCK_MONOTONIC) >= $kill_at) {
      $killed = 1;
    }
    if ($killed) {
      $signal_adopted->(9);
    } elsif (!$term_ok) {
      $term_ok = $signal_adopted->(15);
    }
    select undef, undef, undef, 0.02;
  }
  return $adopted_gone->();
};
my $terminate = sub {
  delete @ENV{qw(FM_TEST_SUPERVISOR_FORCE_PIDFD_SIGNAL_FAILURE FM_TEST_SUPERVISOR_FORCE_PIDFD_REAP_FAILURE)};
  my $deadline = clock_gettime(CLOCK_MONOTONIC) + 6;
  my $sent = defined $fd
    ? syscall($sys_pidfd_send_signal, $fd, 15, 0, 0, 0)
    : kill(15, $pid);
  my $term_ok = defined $fd
    ? defined $sent && ($sent == 0 || ($sent < 0 && $!{ESRCH}))
    : defined $sent && $sent == 1;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    if (!$term_ok) {
      my $retry = defined $fd
        ? syscall($sys_pidfd_send_signal, $fd, 15, 0, 0, 0)
        : kill(15, $pid);
      $term_ok = defined $fd
        ? defined $retry && ($retry == 0 || ($retry < 0 && $!{ESRCH}))
        : defined $retry && $retry == 1;
    }
    select undef, undef, undef, 0.02;
  }
  my $killed = defined $fd
    ? syscall($sys_pidfd_send_signal, $fd, 9, 0, 0, 0)
    : kill(9, $pid);
  my $kill_ok = defined $fd
    ? defined $killed && ($killed == 0 || ($killed < 0 && $!{ESRCH}))
    : defined $killed && $killed == 1;
  return 0 unless $kill_ok;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline + 4) {
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
my $exit_recorded = 0;
my $record_exit = sub {
  my ($state) = @_;
  return 1 if $exit_recorded;
  return 0 unless defined $exit_fd;
  my $payload = "$reaper_identity|$state\n";
  my $offset = 0;
  my $deadline = clock_gettime(CLOCK_MONOTONIC) + 1;
  while ($offset < length($payload) && clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $written = syswrite($exit_fd, $payload, length($payload) - $offset, $offset);
    if (defined $written && $written > 0) {
      $offset += $written;
      next;
    }
    select undef, undef, undef, 0.02;
  }
  return 0 unless $offset == length($payload);
  $exit_recorded = 1;
  return -e $exit_path;
};
my $quarantine = sub {
  my ($reason) = @_;
  $record_exit->("quarantine|$reason");
  my $quarantine_buffer = "";
  while (1) {
    if ($adopted_gone->()) {
      exit 125;
    }
    $signal_adopted->(9);
    if (defined $control) {
      my $readable = "";
      vec($readable, fileno($control), 1) = 1;
      my $selected = select($readable, undef, undef, 1);
      if (defined $selected && $selected > 0 && vec($readable, fileno($control), 1)) {
        my $command = "";
        my $count = sysread($control, $command, 4096);
        if (!defined $count) {
          if (!$!{EAGAIN} && !$!{EINTR}) {
            close $control;
            undef $control;
          }
        } elsif ($count == 0) {
          close $control;
          undef $control;
        } else {
          $quarantine_buffer .= $command;
          while ($quarantine_buffer =~ s/^([^\n]*)\n//) {
            $signal_adopted->(9) if $1 eq "terminate";
          }
        }
      }
    } else {
      select undef, undef, undef, 1;
    }
  }
};
my $child_done = 0;
my $child_status = 125 << 8;
my ($cleanup_deadline, $cleanup_kill_at);
my $mark_child_unwaitable = sub {
  return 0 unless defined $fd;
  my $alive = $probe->($fd);
  if (defined $alive && !$alive) {
    POSIX::close($fd);
    undef $fd;
    $child_done = 1;
    return 1;
  }
  if (defined $alive && $alive && defined $current) {
    $adopted{$pid} = { fd => $fd, identity => $current };
    undef $fd;
    $child_status = 125 << 8;
    $child_done = 1;
    return 1;
  }
  return 0;
};
while (1) {
  if (!$child_done) {
    my $waited = waitpid($pid, WNOHANG);
    if ($waited == $pid) {
      $child_status = $?;
      $child_done = 1;
      POSIX::close($fd) if defined $fd;
    } elsif ($waited < 0 && !$!{EINTR}) {
      if ($!{ECHILD}) {
        $mark_child_unwaitable->() or $stop = 1;
      } else {
        $stop = 1;
      }
    }
  }
  if (!$child_done && $stop) {
    if (!$terminate->()) {
      if ($mark_child_unwaitable->()) {
        next;
      }
      select undef, undef, undef, 0.05;
      next;
    }
    unless ($child_done) {
      my $waited = waitpid($pid, WNOHANG);
      if ($waited == $pid) {
        $child_status = $?;
        $child_done = 1;
        POSIX::close($fd) if defined $fd;
      } elsif ($waited < 0 && $!{ECHILD}) {
        $mark_child_unwaitable->();
      }
    }
    next unless $child_done;
  }
  if ($child_done && !defined $cleanup_deadline) {
    $cleanup_deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
    $cleanup_kill_at = clock_gettime(CLOCK_MONOTONIC) + 2;
  }
  if (!$child_done) {
    $stop = 1 if $startup_error;
  }
  if (!$child_done && !$stop && defined $control) {
    my $readable = "";
    vec($readable, fileno($control), 1) = 1;
    my $selected = select($readable, undef, undef, 0.05);
    if (defined $selected && $selected > 0 && vec($readable, fileno($control), 1)) {
      my $command = "";
      my $count = sysread($control, $command, 4096);
      if (!defined $count || $count == 0) {
        $stop = 1;
      } else {
        $control_buffer .= $command;
        while ($control_buffer =~ s/^([^\n]*)\n//) {
          my $line = $1;
          if ($line eq "terminate") {
            $stop = 1;
          } elsif ($line =~ /^custody\|(\d+)\|(\d+:\d+)\|(\d+)\|(\d+:\d+)$/) {
            $accept_custody->($1, $2, $3, $4);
          }
        }
      }
    }
    next;
  }
  if (!$child_done) {
    select undef, undef, undef, 0.05;
    next;
  }
  if (!$cleanup_adopted->($cleanup_deadline, $cleanup_kill_at)) {
    $quarantine->("cleanup") if clock_gettime(CLOCK_MONOTONIC) >= $cleanup_deadline;
    select undef, undef, undef, 0.05;
    next;
  }
  $quarantine->("startup") if $startup_error;
  $quarantine->("receipt") unless $record_exit->("done");
  exit($child_status >> 8) if ($child_status & 127) == 0;
  exit(125);
}
'
run_bounded() {
  local seconds=$1
  shift
  if ! command -v perl >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: perl is required for child-subreaper timeout enforcement' >&2
    return 125
  fi
  perl -e "$FM_TEST_BOUNDED_GROUP_PERL" "$seconds" "$@"
}

mapfile -t tests < <(compgen -G 'tests/*.test.sh' | sort)
if [ "${#tests[@]}" -eq 0 ]; then
  printf '%s\n' 'FAIL: no tests/*.test.sh files found' >&2
  exit 1
fi

gate_test="$ROOT/tests/fm-gate-refuse.test.sh"
if [ -f "$gate_test" ]; then
  gate_status=0
  run_bounded "$test_timeout" bash "$gate_test" || gate_status=$?
  if [ "$gate_status" -ne 0 ]; then
    printf '%s\n' 'FAIL: gate-refusal test failed; tests were not started' >&2
    exit "$gate_status"
  fi
fi

base_tmp=${TMPDIR:-/tmp}
if ! mkdir -p "$base_tmp"; then
  printf 'FAIL: could not create temporary base %s\n' "$base_tmp" >&2
  exit 1
fi
suite_tmp=$(mktemp -d "$base_tmp/fm-behavior-tests.XXXXXX") || {
  printf 'FAIL: could not create an isolated behavior-test root\n' >&2
  exit 1
}
test_root="$suite_tmp/repo"
if ! git clone --quiet --no-hardlinks "$ROOT" "$test_root"; then
  printf 'FAIL: could not create a normal behavior-test clone\n' >&2
  exit 1
fi
delta_manifest="$suite_tmp/worktree-delta"
if ! {
  git -C "$ROOT" diff --name-only -z HEAD &&
  git -C "$ROOT" ls-files --others --exclude-standard -z
} >"$delta_manifest"; then
  printf 'FAIL: could not enumerate current working-tree contents\n' >&2
  exit 1
fi
copy_worktree_delta() {
  local path src dst
  while IFS= read -r -d '' path; do
    src="$ROOT/$path"
    dst="$test_root/$path"
    if [ -e "$src" ] || [ -L "$src" ]; then
      mkdir -p "$(dirname "$dst")" || return 1
      rm -rf -- "$dst" || return 1
      cp -a -- "$src" "$dst" || return 1
    else
      rm -rf -- "$dst" || return 1
    fi
  done <"$delta_manifest"
}
if ! copy_worktree_delta; then
  printf 'FAIL: could not overlay current working-tree contents\n' >&2
  exit 1
fi
if [ -f "$test_root/bin/fm-gate-refuse-lib.sh" ]; then
  cat > "$test_root/bin/fm-gate-refuse-lib.sh" <<'SH'
FM_GATE_REFUSE_EXIT=3
fm_refuse_if_gate_agent() { return 0; }
SH
fi
RUNNING_TEST_PIDS=()
SUPERVISOR_HANDLE_BROKER_PID=
SUPERVISOR_HANDLE_BROKER_IDENTITY=
SUPERVISOR_HANDLE_BROKER_EXIT_FILE=
SUPERVISOR_HANDLE_READY=0
SUPERVISOR_HANDLE_WRITE=
SUPERVISOR_HANDLE_READ=
SUPERVISOR_HANDLE_CONTROL=
SUPERVISOR_HANDLE_REAPER_CONTROL=
SUPERVISOR_HANDLE_RESPONSE=
supervisor_handle_process_identity() {
  local pid=$1 stat fields start
  IFS= read -r stat <"/proc/$pid/stat" || return 1
  fields=${stat##*) }
  set -- $fields
  [ "$#" -ge 20 ] || return 1
  start=${20}
  [[ "$start" =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s\n' "$pid" "$start"
}
supervisor_handle_broker_state() {
  local stat fields process_state current exit_identity exit_state
  if [ -s "$SUPERVISOR_HANDLE_BROKER_EXIT_FILE" ]; then
    IFS='|' read -r exit_identity exit_state <"$SUPERVISOR_HANDLE_BROKER_EXIT_FILE" || return 2
    [ "$exit_identity" = "$SUPERVISOR_HANDLE_BROKER_IDENTITY" ] || return 2
    [ "$exit_state" = done ] || return 2
    return 3
  fi
  if [ ! -e "/proc/$SUPERVISOR_HANDLE_BROKER_PID/stat" ]; then
    return 2
  fi
  if ! IFS= read -r stat <"/proc/$SUPERVISOR_HANDLE_BROKER_PID/stat"; then
    return 2
  fi
  fields=${stat##*) }
  set -- $fields
  [ "$#" -ge 20 ] || return 2
  process_state=$1
  if ! current=$(supervisor_handle_process_identity "$SUPERVISOR_HANDLE_BROKER_PID"); then
    return 2
  fi
  [ "$current" = "$SUPERVISOR_HANDLE_BROKER_IDENTITY" ] || return 2
  [ "$process_state" = Z ] && return 3
  return 1
}
supervisor_handle_close_channels() {
  if [ -n "$SUPERVISOR_HANDLE_WRITE" ]; then
    eval "exec $SUPERVISOR_HANDLE_WRITE>&-"
    SUPERVISOR_HANDLE_WRITE=
  fi
  if [ -n "$SUPERVISOR_HANDLE_READ" ]; then
    eval "exec $SUPERVISOR_HANDLE_READ<&-"
    SUPERVISOR_HANDLE_READ=
  fi
  if [ -n "$SUPERVISOR_HANDLE_CONTROL" ]; then
    eval "exec $SUPERVISOR_HANDLE_CONTROL>&-"
    SUPERVISOR_HANDLE_CONTROL=
  fi
  if [ -n "$SUPERVISOR_HANDLE_REAPER_CONTROL" ]; then
    eval "exec $SUPERVISOR_HANDLE_REAPER_CONTROL>&-"
    SUPERVISOR_HANDLE_REAPER_CONTROL=
  fi
}
supervisor_handle_force_broker_teardown() {
  if [ -n "$SUPERVISOR_HANDLE_CONTROL" ]; then
    printf '%s\n' terminate >&"$SUPERVISOR_HANDLE_CONTROL" || true
  fi
  if [ -n "$SUPERVISOR_HANDLE_REAPER_CONTROL" ]; then
    printf '%s\n' terminate >&"$SUPERVISOR_HANDLE_REAPER_CONTROL" || true
  fi
}
supervisor_handle_broker_join() {
  local broker_state broker_status wait_timeout timer_pid
  for ((broker_tick = 0; broker_tick < 40; broker_tick++)); do
    broker_state=0
    supervisor_handle_broker_state || broker_state=$?
    case "$broker_state" in
      3)
        wait_timeout=0
        trap 'wait_timeout=1' ALRM
        ( sleep 2; kill -ALRM "$$" 2>/dev/null || true ) &
        timer_pid=$!
        wait "$SUPERVISOR_HANDLE_BROKER_PID" 2>/dev/null
        broker_status=$?
        kill "$timer_pid" 2>/dev/null || true
        wait "$timer_pid" 2>/dev/null || true
        trap - ALRM
        [ "$wait_timeout" -eq 0 ] || return 1
        [ "$broker_status" -eq 0 ] || return 1
        return 0
        ;;
      1) sleep 0.05 ;;
      *) return 1 ;;
    esac
  done
  return 1
}
supervisor_handle_request() {
  [ "$SUPERVISOR_HANDLE_READY" -eq 1 ] || return 1
  SUPERVISOR_HANDLE_RESPONSE=
  printf '%s\n' "$1" >&"$SUPERVISOR_HANDLE_WRITE" || return 1
  supervisor_handle_read_response
}
supervisor_handle_read_response() {
  [ "$SUPERVISOR_HANDLE_READY" -eq 1 ] || return 1
  SUPERVISOR_HANDLE_RESPONSE=
  IFS= read -r -t 2 SUPERVISOR_HANDLE_RESPONSE <&"$SUPERVISOR_HANDLE_READ" || return 1
}
supervisor_handle_signal() {
  local key=$1
  supervisor_handle_request "signal|$key" || return 1
  case "$SUPERVISOR_HANDLE_RESPONSE" in
    "$key|signaled"|"$key|gone") return 0 ;;
    *) return 1 ;;
  esac
}
supervisor_handle_abort() {
  local key=$1
  local abort_tick
  [ "$SUPERVISOR_HANDLE_READY" -eq 1 ] || return 1
  printf '%s\n' "abort|$key" >&"$SUPERVISOR_HANDLE_WRITE" || return 1
  for ((abort_tick = 0; abort_tick < 3; abort_tick++)); do
    supervisor_handle_read_response || return 1
    case "$SUPERVISOR_HANDLE_RESPONSE" in
      "$key|aborted"|"$key|gone") return 0 ;;
    esac
  done
  return 1
}
supervisor_handle_state() {
  local key=$1
  supervisor_handle_request "state|$key" || return 2
  case "$SUPERVISOR_HANDLE_RESPONSE" in
    "$key|gone") return 0 ;;
    "$key|alive") return 1 ;;
    *) return 2 ;;
  esac
}
supervisor_handle_close() {
  local key=$1
  supervisor_handle_request "close|$key" || return 1
  [ "$SUPERVISOR_HANDLE_RESPONSE" = "$key|closed" ]
}
supervisor_handle_shutdown() {
  supervisor_handle_request shutdown || return 1
  [ "$SUPERVISOR_HANDLE_RESPONSE" = 'shutdown|done' ]
}
SUPERVISOR_HANDLE_LAUNCHED_PID=
SUPERVISOR_HANDLE_LAUNCHED_IDENTITY=
supervisor_handle_launch() {
  local key=$1 runner=$2 test_path=$3 job_root=$4 log_path=$5
  local start_gate=$6 abort_gate=$7 test_root=$8 timeout=$9 bounded_script=${10}
  local request response_key response_state
  printf -v request 'launch\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$key" "$runner" "$test_path" "$job_root" "$log_path" "$start_gate" \
    "$abort_gate" "$test_root" "$timeout" "$bounded_script"
  if ! supervisor_handle_request "$request"; then
    supervisor_handle_abort "$key" || true
    return 1
  fi
  IFS='|' read -r response_key response_state SUPERVISOR_HANDLE_LAUNCHED_PID \
    SUPERVISOR_HANDLE_LAUNCHED_IDENTITY <<<"$SUPERVISOR_HANDLE_RESPONSE"
  if [ "$response_key" != "$key" ] || [ "$response_state" != registered ] || \
    ! [[ "$SUPERVISOR_HANDLE_LAUNCHED_PID" =~ ^[0-9]+$ ]] || \
    [ -z "$SUPERVISOR_HANDLE_LAUNCHED_IDENTITY" ]; then
    supervisor_handle_abort "$key" || true
    return 1
  fi
}
SUPERVISOR_HANDLE_EXIT_STATUS=
supervisor_handle_wait() {
  local key=$1 response_key response_state raw_status broker_state
  while :; do
    broker_state=0
    supervisor_handle_broker_state || broker_state=$?
    [ "$broker_state" -eq 1 ] || return 1
    supervisor_handle_request "wait|$key" || return 1
    IFS='|' read -r response_key response_state raw_status <<<"$SUPERVISOR_HANDLE_RESPONSE"
    [ "$response_key" = "$key" ] || return 1
    if [ "$response_state" = running ]; then
      sleep 0.02
      continue
    fi
    [ "$response_state" = exit ] || return 1
    [[ "$raw_status" =~ ^[0-9]+$ ]] || return 1
    if [ $((raw_status & 127)) -ne 0 ]; then
      SUPERVISOR_HANDLE_EXIT_STATUS=$((128 + (raw_status & 127)))
    else
      SUPERVISOR_HANDLE_EXIT_STATUS=$((raw_status >> 8))
    fi
    return 0
  done
}
remove_running_pid() {
  local target=$1 entry entry_key
  local remaining=()
  for entry in "${RUNNING_TEST_PIDS[@]}"; do
    entry_key=${entry%%|*}
    [ "$entry_key" = "$target" ] || remaining+=("$entry")
  done
  RUNNING_TEST_PIDS=("${remaining[@]}")
}
supervisor_entry_for_key() {
  local target=$1 entry
  for entry in "${RUNNING_TEST_PIDS[@]}"; do
    [ "${entry%%|*}" = "$target" ] && {
      printf '%s\n' "$entry"
      return 0
    }
  done
  return 1
}
signal_running_supervisor() {
  local entry=$1 key
  key=${entry%%|*}
  supervisor_handle_signal "$key"
}
supervisor_is_gone() {
  local entry=$1 key
  key=${entry%%|*}
  supervisor_handle_state "$key"
}
cleanup() {
  local cleanup_ok=1 broker_shutdown_ok=1 entry key state still_alive broker_state=0
  if [ "$SUPERVISOR_HANDLE_READY" -eq 1 ]; then
    supervisor_handle_broker_state || broker_state=$?
  else
    cleanup_ok=0
    supervisor_handle_force_broker_teardown
  fi
  if [ "$broker_state" -ne 1 ]; then
    cleanup_ok=0
  else
    for entry in "${RUNNING_TEST_PIDS[@]}"; do
      signal_running_supervisor "$entry" || cleanup_ok=0
    done
    for ((cleanup_tick = 0; cleanup_tick < 100; cleanup_tick++)); do
      broker_state=0
      supervisor_handle_broker_state || broker_state=$?
      [ "$broker_state" -eq 1 ] || break
      still_alive=0
      for entry in "${RUNNING_TEST_PIDS[@]}"; do
        state=0
        supervisor_is_gone "$entry" || state=$?
        case "$state" in
          0) ;;
          1|2) still_alive=1; [ "$state" -eq 2 ] && cleanup_ok=0; break ;;
        esac
      done
      [ "$still_alive" -eq 0 ] && break
      sleep 0.05
    done
    if [ "$broker_state" -eq 1 ]; then
      for entry in "${RUNNING_TEST_PIDS[@]}"; do
        key=${entry%%|*}
        state=0
        supervisor_is_gone "$entry" || state=$?
        if [ "$state" -eq 0 ]; then
          supervisor_handle_wait "$key" || cleanup_ok=0
          supervisor_handle_close "$key" || cleanup_ok=0
        else
          cleanup_ok=0
        fi
      done
    else
      cleanup_ok=0
    fi
  fi
  if [ "$SUPERVISOR_HANDLE_READY" -eq 1 ]; then
    supervisor_handle_shutdown || {
      cleanup_ok=0
      broker_shutdown_ok=0
    }
    SUPERVISOR_HANDLE_READY=0
  fi
  [ "$broker_shutdown_ok" -eq 1 ] || supervisor_handle_force_broker_teardown
  if [ -n "$SUPERVISOR_HANDLE_BROKER_PID" ]; then
    if supervisor_handle_broker_join; then
      SUPERVISOR_HANDLE_BROKER_PID=
    else
      cleanup_ok=0
      supervisor_handle_force_broker_teardown
      if supervisor_handle_broker_join; then
        SUPERVISOR_HANDLE_BROKER_PID=
      fi
    fi
  fi
  supervisor_handle_close_channels
  if [ "$cleanup_ok" -ne 1 ]; then
    printf '%s\n' 'FAIL: could not prove cleanup of active behavior tests' >&2
    trap - EXIT
    exit 125
  fi
  rm -rf -- "$suite_tmp"
}
trap cleanup EXIT

supervisor_handle_input="$suite_tmp/supervisor-handles.in"
supervisor_handle_output="$suite_tmp/supervisor-handles.out"
supervisor_handle_control="$suite_tmp/supervisor-handles.control"
supervisor_handle_reaper_control="$suite_tmp/supervisor-handles.reaper.control"
supervisor_handle_reaper_exit="$suite_tmp/supervisor-handles.reaper.exit"
SUPERVISOR_HANDLE_BROKER_EXIT_FILE="$supervisor_handle_reaper_exit"
supervisor_handle_worker="$suite_tmp/supervisor-handles-worker.pl"
supervisor_handle_guard_worker="$suite_tmp/supervisor-handles-guard-worker.pl"
if ! mkfifo "$supervisor_handle_input" "$supervisor_handle_output" "$supervisor_handle_control" "$supervisor_handle_reaper_control"; then
  printf '%s\n' 'FAIL: could not create supervisor handle channels' >&2
  exit 125
fi
if ! command -v perl >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: perl is required for retained supervisor handles' >&2
  exit 125
fi
if ! exec {SUPERVISOR_HANDLE_CONTROL}<>"$supervisor_handle_control"; then
  printf '%s\n' 'FAIL: could not open supervisor broker control channel' >&2
  exit 125
fi
if ! exec {SUPERVISOR_HANDLE_REAPER_CONTROL}<>"$supervisor_handle_reaper_control"; then
  printf '%s\n' 'FAIL: could not open supervisor reaper control channel' >&2
  exit 125
fi
FM_TEST_SUPERVISOR_REAPER_CUSTODY_PATH="$supervisor_handle_reaper_control"
export FM_TEST_SUPERVISOR_REAPER_CUSTODY_PATH
if ! printf '%s' "$FM_TEST_SUPERVISOR_HANDLE_PERL" >"$supervisor_handle_worker"; then
  printf '%s\n' 'FAIL: could not write supervisor handle worker' >&2
  exit 125
fi
if ! printf '%s' "$FM_TEST_SUPERVISOR_GUARD_WORKER_PERL" >"$supervisor_handle_guard_worker"; then
  printf '%s\n' 'FAIL: could not write supervisor guard worker' >&2
  exit 125
fi
perl -e "$FM_TEST_SUPERVISOR_REAPER_PERL" "$FM_TEST_SUPERVISOR_GUARD_PARENT_PERL" "$FM_TEST_SUPERVISOR_GUARD_PERL" \
  "$supervisor_handle_guard_worker" \
  "$supervisor_handle_worker" \
  "$supervisor_handle_input" "$supervisor_handle_output" "$supervisor_handle_control" \
  "$SUPERVISOR_HANDLE_REAPER_CONTROL" "$supervisor_handle_reaper_exit" &
SUPERVISOR_HANDLE_BROKER_PID=$!
if ! SUPERVISOR_HANDLE_BROKER_IDENTITY=$(supervisor_handle_process_identity "$SUPERVISOR_HANDLE_BROKER_PID"); then
  printf '%s\n' 'FAIL: could not bind supervisor broker handle' >&2
  exit 125
fi
if [ -n "${FM_TEST_SUPERVISOR_REAPER_PID_FILE:-}" ]; then
  printf '%s\n' "$SUPERVISOR_HANDLE_BROKER_IDENTITY" >"$FM_TEST_SUPERVISOR_REAPER_PID_FILE" || exit 125
fi
if [ -n "${FM_TEST_SUPERVISOR_DELAY_CONTROL_OPEN:-}" ]; then
  : >"$FM_TEST_SUPERVISOR_DELAY_CONTROL_OPEN" || exit 125
fi
if ! exec {SUPERVISOR_HANDLE_WRITE}<>"$supervisor_handle_input"; then
  printf '%s\n' 'FAIL: could not open supervisor handle input' >&2
  exit 125
fi
if ! exec {SUPERVISOR_HANDLE_READ}<>"$supervisor_handle_output"; then
  printf '%s\n' 'FAIL: could not open supervisor handle output' >&2
  exit 125
fi
SUPERVISOR_HANDLE_READY=1
if ! supervisor_handle_request ping || [ "$SUPERVISOR_HANDLE_RESPONSE" != 'ping|ready' ]; then
  printf '%s\n' 'FAIL: supervisor handle broker did not become ready' >&2
  exit 125
fi
if [ -n "${FM_TEST_SUPERVISOR_DELAY_CONTROL_OPEN:-}" ]; then
  eval "exec $SUPERVISOR_HANDLE_CONTROL>&-"
  SUPERVISOR_HANDLE_CONTROL=
  exit 125
fi
if [ "${FM_TEST_SUPERVISOR_FORCE_TERMINATE_CONTROL:-0}" -eq 1 ]; then
  printf '%s\n' terminate >&"$SUPERVISOR_HANDLE_CONTROL" || true
  eval "exec $SUPERVISOR_HANDLE_CONTROL>&-"
  SUPERVISOR_HANDLE_CONTROL=
  exit 125
fi
if [ "${FM_TEST_SUPERVISOR_BREAK_CONTROL:-0}" -eq 1 ]; then
  eval "exec $SUPERVISOR_HANDLE_CONTROL>&-"
  SUPERVISOR_HANDLE_CONTROL=
fi

mapfile -t tests < <(
  cd "$test_root" || exit 1
  for test_path in tests/*.test.sh; do
    [ -f "$test_path" ] || continue
    [ "$test_path" = tests/fm-gate-refuse.test.sh ] || printf '%s\n' "$test_path"
  done
)
total=${#tests[@]}
active_jobs=$jobs
[ "$active_jobs" -le "$total" ] || active_jobs=$total
parallel_allowlist_entries=()
parallel_allowlist=${FM_TEST_PARALLEL_ALLOWLIST:-}
if [ "$active_jobs" -gt 1 ]; then
  if [ -z "$parallel_allowlist" ]; then
    printf '%s\n' 'FAIL: FM_TEST_JOBS above 1 requires FM_TEST_PARALLEL_ALLOWLIST' >&2
    exit 1
  fi
  IFS=',' read -r -a parallel_allowlist_entries <<< "$parallel_allowlist"
  for allowlist_index in "${!parallel_allowlist_entries[@]}"; do
    entry=${parallel_allowlist_entries[$allowlist_index]}
    case "$entry" in
      tests/*.test.sh) entry=${entry#tests/} ;;
      *.test.sh) ;;
      *)
        printf 'FAIL: FM_TEST_PARALLEL_ALLOWLIST has an invalid test name: %s\n' "$entry" >&2
        exit 1
        ;;
    esac
    parallel_allowlist_entries[$allowlist_index]=$entry
    found=0
    for test_path in "${tests[@]}"; do
      [ "$test_path" = "tests/$entry" ] && found=1 && break
    done
    if [ "$found" -ne 1 ]; then
      printf 'FAIL: FM_TEST_PARALLEL_ALLOWLIST names a missing test: %s\n' "$entry" >&2
      exit 1
    fi
  done
fi
parallel_test_allowed() {
  local test_path=$1 entry
  for entry in "${parallel_allowlist_entries[@]}"; do
    [ "$test_path" = "tests/$entry" ] && return 0
  done
  return 1
}
printf 'Running %s behavior tests with %s parallel job(s)\n' "$total" "$active_jobs"

run_one() {
  :
}

failed_count=0
index=0
while [ "$index" -lt "$total" ]; do
  pids=()
  batch_tests=()
  batch_logs=()
  batch_roots=()
  batch_keys=()
  batch_count=0

  batch_limit=$active_jobs
  if [ "$active_jobs" -gt 1 ] && ! parallel_test_allowed "${tests[$index]}"; then
    batch_limit=1
  fi
  while [ "$index" -lt "$total" ] && [ "$batch_count" -lt "$batch_limit" ]; do
    test_path=${tests[$index]}
    if [ "$batch_limit" -gt 1 ] && ! parallel_test_allowed "$test_path"; then
      break
    fi
    test_name=${test_path##*/}
    test_id=${test_name%.test.sh}
    job_root="$suite_tmp/$test_id"
    log_path="$job_root/output.log"
    start_gate="$job_root/start"
    abort_gate="$job_root/abort"
    mkdir -p "$job_root/tmp" "$job_root/gotmp"
    bounded_script="$job_root/bounded-group.pl"
    printf '%s' "$FM_TEST_BOUNDED_GROUP_PERL" >"$bounded_script" || exit 125
    printf 'START: %s (TMPDIR=%s GOTMPDIR=%s)\n' "$test_path" "$job_root/tmp" "$job_root/gotmp"
    if ! supervisor_handle_launch "$test_id" "$test_root/bin/fm-run-behavior-job.sh" \
      "$test_path" "$job_root" "$log_path" "$start_gate" "$abort_gate" \
      "$test_root" "$test_timeout" "$bounded_script"; then
      printf 'FAIL: could not bind an active behavior-test supervisor (%s)\n' "$SUPERVISOR_HANDLE_RESPONSE" >&2
      exit 125
    fi
    RUNNING_TEST_PIDS+=("$test_id|$SUPERVISOR_HANDLE_LAUNCHED_PID|$SUPERVISOR_HANDLE_LAUNCHED_IDENTITY")
    : >"$start_gate" || {
      printf '%s\n' 'FAIL: could not release a bound behavior-test supervisor' >&2
      exit 125
    }
    if [ "${FM_TEST_SUPERVISOR_FORCE_JOB_ABORT_AFTER_START:-0}" -eq 1 ]; then
      if [ -n "${FM_TEST_SUPERVISOR_READY_FILE:-}" ]; then
        ready_seen=0
        for ((ready_tick = 0; ready_tick < 200; ready_tick++)); do
          if [ -e "$FM_TEST_SUPERVISOR_READY_FILE" ]; then
            ready_seen=1
            break
          fi
          sleep 0.01
        done
        [ "$ready_seen" -eq 1 ] || exit 125
      fi
      supervisor_handle_abort "$test_id" || true
      exit 125
    fi
    pids+=("$SUPERVISOR_HANDLE_LAUNCHED_PID")
    batch_tests+=("$test_path")
    batch_logs+=("$log_path")
    batch_roots+=("$job_root")
    batch_keys+=("$test_id")
    index=$((index + 1))
    batch_count=$((batch_count + 1))
  done

  for batch_index in "${!pids[@]}"; do
    test_key=${batch_keys[$batch_index]}
    if ! supervisor_handle_wait "$test_key"; then
      printf '%s\n' 'FAIL: could not reap behavior-test supervisor' >&2
      exit 125
    fi
    test_rc=$SUPERVISOR_HANDLE_EXIT_STATUS
    test_entry=$(supervisor_entry_for_key "$test_key") || exit 125
    if ! supervisor_is_gone "$test_entry" || ! supervisor_handle_close "$test_key"; then
      printf '%s\n' 'FAIL: could not prove behavior-test supervisor exit' >&2
      exit 125
    fi
    remove_running_pid "$test_key"
    if [ "$test_rc" -eq 0 ]; then
      printf 'PASS: %s\n' "${batch_tests[$batch_index]}"
    elif [ "$test_rc" -eq 125 ]; then
      printf 'FAIL: %s (fail-closed exit 125)\n' "${batch_tests[$batch_index]}" >&2
      exit 125
    else
      printf 'FAIL: %s (exit %s)\n' "${batch_tests[$batch_index]}" "$test_rc" >&2
      failed_count=$((failed_count + 1))
    fi
    if [ -s "${batch_logs[$batch_index]}" ]; then
      cat "${batch_logs[$batch_index]}"
    fi
  done
done

if [ "$failed_count" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failed_count" >&2
  exit 1
fi
printf 'All %s behavior tests passed\n' "$total"
