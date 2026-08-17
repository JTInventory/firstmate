#!/usr/bin/env bash

fm_nofollow_write() {
  local path=$1
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    use Fcntl qw(:DEFAULT);
    my ($path) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined($nofollow) or exit 1;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_TRUNC | $nofollow, 0600) or exit 1;
    binmode($fh);
    local $/;
    my $content = <STDIN> // "";
    print $fh $content or exit 1;
    close($fh) or exit 1;
  ' "$path"
}

fm_nofollow_append() {
  local path=$1
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    use Fcntl qw(:DEFAULT);
    my ($path) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined($nofollow) or exit 1;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_APPEND | $nofollow, 0600) or exit 1;
    binmode($fh);
    local $/;
    my $content = <STDIN> // "";
    print $fh $content or exit 1;
    close($fh) or exit 1;
  ' "$path"
}

fm_nofollow_spawn_capture() {
  local path=$1
  shift
  [ "$#" -gt 0 ] || return 1
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    use Fcntl qw(:DEFAULT);
    use POSIX ();
    my ($path, @command) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined($nofollow) or exit 1;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_TRUNC | $nofollow, 0600) or exit 1;
    my $pid = fork();
    defined($pid) or exit 1;
    if ($pid == 0) {
      POSIX::setpgid(0, 0) == 0 or exit 125;
      open(STDOUT, ">&", $fh) or exit 1;
      open(STDERR, ">&", $fh) or exit 1;
      exec @command;
      exit 127;
    }
    eval { POSIX::setpgid($pid, $pid); };
    print "$pid\n" or exit 1;
  ' "$path" "$@"
}
