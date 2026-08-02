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
my $ready = "";
my $ready_count = sysread($ready_r, $ready, 1);
close $ready_r;
if (!$ready_count) {
  close $release_w;
  my $waited = waitpid $pid, 0;
  my $status = $?;
  defined(sigprocmask(SIG_SETMASK, $old)) or exit 125;
  exit 125 if $waited < 0;
  exit(128 + ($status & 127)) if $status & 127;
  exit($status >> 8);
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
    syswrite($release_w, "0");
    close $release_w;
    waitpid $pid, 0;
    exit 125;
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
  syswrite($release_w, "0");
  close $release_w;
  my $waited = waitpid $pid, 0;
  exit 125 if $waited < 0;
  exit 125;
}
syswrite($release_w, "1") == 1 or exit 125;
close $release_w;
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
my $waited = waitpid $pid, 0;
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
use Errno qw(ECHILD EINTR ESRCH);
use POSIX qw(:sys_wait_h);
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
my %handles;
my $close_handle = sub {
  my ($entry) = @_;
  POSIX::close($entry->{fd});
};
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
my $probe = sub {
  my ($fd) = @_;
  my $result = syscall($sys_pidfd_send_signal, $fd, 0, 0, 0);
  return 1 if defined $result && $result == 0;
  return 0 if defined $result && $result < 0 && $!{ESRCH};
  return;
};
my $reap_entry = sub {
  my ($entry) = @_;
  for (1 .. 50) {
    my $waited = waitpid($entry->{pid}, WNOHANG);
    return 1 if $waited == $entry->{pid};
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
my $terminate_entry = sub {
  my ($entry) = @_;
  my $term = syscall($sys_pidfd_send_signal, $entry->{fd}, 15, 0, 0);
  my $term_ok = defined $term && ($term == 0 || ($term < 0 && $!{ESRCH}));
  return 0 unless $term_ok;
  return 1 if $reap_entry->($entry);
  my $kill = syscall($sys_pidfd_send_signal, $entry->{fd}, 9, 0, 0);
  my $kill_ok = defined $kill && ($kill == 0 || ($kill < 0 && $!{ESRCH}));
  return 0 unless $kill_ok;
  return $reap_entry->($entry);
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
  my @parts;
  if (index($line, "\t") >= 0) {
    @parts = split /\t/, $line;
  } else {
    @parts = split /\|/, $line, 4;
  }
  my $command = shift @parts // "";
  if ($command eq "ping") {
    print "ping|ready\n";
    next;
  }
  if ($command eq "launch" && @parts == 10) {
    my ($key, $runner, $test_path, $job_root, $log_path, $start_gate, $abort_gate, $test_root, $timeout, $bounded_script) = @parts;
    my $pid = fork;
    if (!defined $pid) {
      print "$key|error-fork\n";
      next;
    }
    if (!$pid) {
      my $child_parent = getppid();
      syscall($sys_prctl, 1, 15, 0, 0, 0) == 0 or exit 125;
      exit 125 if getppid() != $child_parent;
      exec "/usr/bin/bash", $runner, $test_path, $job_root, $log_path, $start_gate, $abort_gate, $test_root, $timeout, $bounded_script;
      exit 127;
    }
    my $abort_child = sub {
      if (open my $abort, ">", $abort_gate) {
        close $abort;
      }
    };
    if ($ENV{FM_TEST_FORCE_SUPERVISOR_IDENTITY_FAILURE}) {
      $abort_child->();
      waitpid $pid, 0;
      print "$key|error-identity\n";
      next;
    }
    my $fd = syscall($sys_pidfd_open, $pid, 0);
    if (!defined $fd || $fd < 0) {
      $abort_child->();
      waitpid $pid, 0;
      print "$key|error-open\n";
      next;
    }
    my $current = $identity->($pid);
    if (!defined $current) {
      POSIX::close($fd);
      $abort_child->();
      waitpid $pid, 0;
      print "$key|error-identity\n";
      next;
    }
    my $alive = $probe->($fd);
    if (!defined $alive || !$alive) {
      POSIX::close($fd);
      $abort_child->();
      waitpid $pid, 0;
      print "$key|error-probe\n";
      next;
    }
    $handles{$key} = { fd => $fd, pid => $pid };
    next if $ENV{FM_TEST_SUPERVISOR_DROP_LAUNCH_RESPONSE};
    print "$key|registered|$pid|$current\n";
    next;
  }
  if ($command eq "abort" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    if (!defined $entry) {
      print "$key|gone\n";
      next;
    }
    if ($terminate_entry->($entry)) {
      $close_handle->($entry);
      delete $handles{$key};
      print "$key|aborted\n";
    } else {
      print "$key|error\n";
    }
    next;
  }
  if ($command eq "wait" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    if (!defined $entry) {
      print "$key|error\n";
      next;
    }
    if (!defined $entry->{status}) {
      my $waited = waitpid($entry->{pid}, WNOHANG);
      if ($waited == 0) {
        print "$key|running\n";
        next;
      }
      if ($waited < 0) {
        print "$key|error\n";
        next;
      }
      $entry->{status} = $?;
    }
    print "$key|exit|$entry->{status}\n";
    next;
  }
  if ($command eq "signal" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    if (!defined $entry) {
      print "$key|error\n";
      next;
    }
    my $sent = syscall($sys_pidfd_send_signal, $entry->{fd}, 15, 0, 0);
    if (defined $sent && $sent == 0) {
      print "$key|signaled\n";
    } elsif (defined $sent && $sent < 0 && $!{ESRCH}) {
      print "$key|gone\n";
    } else {
      print "$key|error\n";
    }
    next;
  }
  if ($command eq "state" && @parts == 1) {
    my $key = $parts[0];
    my $entry = $handles{$key};
    if (!defined $entry) {
      print "$key|error\n";
      next;
    }
    my $alive = $probe->($entry->{fd});
    if (!defined $alive) {
      print "$key|error\n";
    } elsif ($alive) {
      print "$key|alive\n";
    } else {
      print "$key|gone\n";
    }
    next;
  }
  if ($command eq "close" && @parts == 1) {
    my $key = $parts[0];
    my $entry = delete $handles{$key};
    $close_handle->($entry) if defined $entry;
    print "$key|closed\n";
    next;
  }
  if ($command eq "shutdown" && !@parts) {
    my $shutdown_ok = 1;
    for my $key (keys %handles) {
      my $entry = $handles{$key};
      if ($terminate_entry->($entry)) {
        $close_handle->($entry);
        delete $handles{$key};
      } else {
        $shutdown_ok = 0;
      }
    }
    print $shutdown_ok ? "shutdown|done\n" : "shutdown|error\n";
    last;
  }
  print "error|malformed\n";
}
my $cleanup_ok = 1;
for my $key (keys %handles) {
  my $entry = $handles{$key};
  if ($terminate_entry->($entry)) {
    $close_handle->($entry);
    delete $handles{$key};
  } else {
    $cleanup_ok = 0;
  }
}
for my $entry (values %handles) {
  $close_handle->($entry);
}
exit($cleanup_ok ? 0 : 125);
'
FM_TEST_SUPERVISOR_GUARD_PERL='
use Config;
use Errno qw(EAGAIN ECHILD EINTR ESRCH);
use Fcntl qw(F_GETFL F_SETFL F_SETFD FD_CLOEXEC O_NONBLOCK);
use POSIX qw(:sys_wait_h);
my ($worker_path, $input_path, $output_path, $control_path) = @ARGV;
my $arch = $Config{archname} // "";
my ($sys_pidfd_open, $sys_pidfd_send_signal);
if ($arch =~ /(?:x86_64|amd64)/) {
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
} elsif ($arch =~ /(?:aarch64|riscv64|s390x|ppc64|i[3-6]86|arm)/) {
  $sys_pidfd_open = 434;
  $sys_pidfd_send_signal = 424;
}
defined $sys_pidfd_open && defined $sys_pidfd_send_signal or exit 125;
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
my $fd = syscall($sys_pidfd_open, $pid, 0);
if (!defined $fd || $fd < 0) {
  close $gate_w;
  waitpid($pid, 0);
  exit 125;
}
my $probe = syscall($sys_pidfd_send_signal, $fd, 0, 0, 0);
if (!defined $probe || $probe != 0) {
  POSIX::close($fd);
  close $gate_w;
  waitpid($pid, 0);
  exit 125;
}
if (defined $ENV{FM_TEST_SUPERVISOR_BROKER_PID_FILE} &&
    length $ENV{FM_TEST_SUPERVISOR_BROKER_PID_FILE}) {
  open my $record, ">", $ENV{FM_TEST_SUPERVISOR_BROKER_PID_FILE} or exit 125;
  print $record "$pid:";
  open my $stat, "<", "/proc/$pid/stat" or exit 125;
  my $line = <$stat>;
  close $stat;
  my $comm_end = defined $line ? rindex($line, ")") : -1;
  exit 125 if $comm_end < 0;
  my @fields = split /\s+/, substr($line, $comm_end + 2);
  my $start = $fields[19];
  exit 125 unless defined $start && $start =~ /^\d+\z/;
  print $record "$start\n";
  close $record or exit 125;
}
syswrite($gate_w, "1") == 1 or exit 125;
close $gate_w;
open my $control, "<", $control_path or exit 125;
my $flags = fcntl($control, F_GETFL, 0);
defined $flags && defined fcntl($control, F_SETFL, $flags | O_NONBLOCK) or exit 125;
my $terminate = sub {
  my $sent = syscall($sys_pidfd_send_signal, $fd, 15, 0, 0);
  my $term_ok = defined $sent && ($sent == 0 || ($sent < 0 && $!{ESRCH}));
  return 0 unless $term_ok;
  for (1 .. 100) {
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  my $killed = syscall($sys_pidfd_send_signal, $fd, 9, 0, 0);
  my $kill_ok = defined $killed && ($killed == 0 || ($killed < 0 && $!{ESRCH}));
  return 0 unless $kill_ok;
  for (1 .. 100) {
    my $waited = waitpid($pid, WNOHANG);
    return 1 if $waited == $pid;
    return 1 if $waited < 0 && $!{ECHILD};
    return 0 if $waited < 0 && !$!{EINTR};
    select undef, undef, undef, 0.02;
  }
  return 0;
};
my $finish = sub {
  my ($status) = @_;
  POSIX::close($fd);
  exit $status;
};
my $terminate_command = sub {
  my $waited = waitpid($pid, WNOHANG);
  $finish->($?) if $waited == $pid;
  $finish->(125) if $waited < 0 && !$!{EINTR};
  $finish->($terminate->() ? 125 : 125);
};
while (1) {
  my $waited = waitpid($pid, WNOHANG);
  $finish->($?) if $waited == $pid;
  $finish->(125) if $waited < 0 && !$!{EINTR};
  my $readable = "";
  vec($readable, fileno($control), 1) = 1;
  my $selected = select($readable, undef, undef, 0.05);
  next unless defined $selected && $selected > 0 && vec($readable, fileno($control), 1);
  my $command = "";
  my $count = sysread($control, $command, 4096);
  if (!defined $count) {
    next if $!{EAGAIN} || $!{EINTR};
    $terminate_command->();
  }
  if ($count == 0) {
    $terminate_command->();
  }
  if ($command =~ /(?:^|\n)terminate(?:\n|$)/) {
    $terminate_command->();
  }
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
if [ -f "$gate_test" ] && ! run_bounded "$test_timeout" bash "$gate_test"; then
  printf '%s\n' 'FAIL: gate-refusal test failed; tests were not started' >&2
  exit 1
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
SUPERVISOR_HANDLE_READY=0
SUPERVISOR_HANDLE_WRITE=
SUPERVISOR_HANDLE_READ=
SUPERVISOR_HANDLE_CONTROL=
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
  local stat fields process_state current
  if [ ! -e "/proc/$SUPERVISOR_HANDLE_BROKER_PID/stat" ]; then
    return 0
  fi
  IFS= read -r stat <"/proc/$SUPERVISOR_HANDLE_BROKER_PID/stat" || return 2
  fields=${stat##*) }
  set -- $fields
  [ "$#" -ge 20 ] || return 2
  process_state=$1
  current=$(supervisor_handle_process_identity "$SUPERVISOR_HANDLE_BROKER_PID") || return 2
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
}
supervisor_handle_force_broker_teardown() {
  if [ -n "$SUPERVISOR_HANDLE_CONTROL" ]; then
    printf '%s\n' terminate >&"$SUPERVISOR_HANDLE_CONTROL" || true
  fi
}
supervisor_handle_broker_join() {
  local broker_state broker_status
  for ((broker_tick = 0; broker_tick < 200; broker_tick++)); do
    broker_state=0
    supervisor_handle_broker_state || broker_state=$?
    case "$broker_state" in
      0|3)
        wait "$SUPERVISOR_HANDLE_BROKER_PID" 2>/dev/null
        broker_status=$?
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
  local key=$1 response_key response_state raw_status
  while :; do
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
  local cleanup_ok=1 broker_shutdown_ok=1 entry key state still_alive
  for entry in "${RUNNING_TEST_PIDS[@]}"; do
    signal_running_supervisor "$entry" || cleanup_ok=0
  done
  for ((cleanup_tick = 0; cleanup_tick < 100; cleanup_tick++)); do
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
  if [ "$SUPERVISOR_HANDLE_READY" -eq 1 ]; then
    supervisor_handle_shutdown || {
      cleanup_ok=0
      broker_shutdown_ok=0
    }
    SUPERVISOR_HANDLE_READY=0
  fi
  [ "$broker_shutdown_ok" -eq 1 ] || supervisor_handle_force_broker_teardown
  supervisor_handle_close_channels
  if [ -n "$SUPERVISOR_HANDLE_BROKER_PID" ]; then
    supervisor_handle_broker_join || cleanup_ok=0
    SUPERVISOR_HANDLE_BROKER_PID=
  fi
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
supervisor_handle_worker="$suite_tmp/supervisor-handles-worker.pl"
if ! mkfifo "$supervisor_handle_input" "$supervisor_handle_output" "$supervisor_handle_control"; then
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
if ! printf '%s' "$FM_TEST_SUPERVISOR_HANDLE_PERL" >"$supervisor_handle_worker"; then
  printf '%s\n' 'FAIL: could not write supervisor handle worker' >&2
  exit 125
fi
perl -e "$FM_TEST_SUPERVISOR_GUARD_PERL" "$supervisor_handle_worker" \
  "$supervisor_handle_input" "$supervisor_handle_output" "$supervisor_handle_control" &
SUPERVISOR_HANDLE_BROKER_PID=$!
if ! SUPERVISOR_HANDLE_BROKER_IDENTITY=$(supervisor_handle_process_identity "$SUPERVISOR_HANDLE_BROKER_PID"); then
  printf '%s\n' 'FAIL: could not bind supervisor broker handle' >&2
  exit 125
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
