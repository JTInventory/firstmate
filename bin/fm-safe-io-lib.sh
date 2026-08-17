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

fm_nofollow_read() {
  local path=$1
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    use Fcntl qw(:DEFAULT);
    my ($path) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined($nofollow) or exit 1;
    sysopen(my $fh, $path, O_RDONLY | $nofollow) or exit 1;
    binmode($fh);
    local $/;
    my $content = <$fh> // "";
    print STDOUT $content or exit 1;
    close($fh) or exit 1;
  ' "$path"
}

fm_nofollow_rename() {
  local source=$1 target=$2 exclusive=${3:-0}
  command -v perl >/dev/null 2>&1 || return 1
  case "$exclusive" in 0|1) ;; *) return 1 ;; esac
  perl -e '
    use Errno qw(ENOENT);
    my ($source, $target, $exclusive) = @ARGV;
    lstat($source) && !-l($source) && -f($source) or exit 1;
    if (lstat($target)) {
      (-l($target) || -d($target) || !-f($target)) and exit 1;
      $exclusive and exit 1;
    } elsif ($! != ENOENT) {
      exit 1;
    }
    rename($source, $target) or exit 1;
  ' "$source" "$target" "$exclusive"
}

fm_nofollow_chmod() {
  local path=$1 mode=$2
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    use Fcntl qw(:DEFAULT);
    my ($path, $mode) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined($nofollow) or exit 1;
    $mode =~ /\A[0-7]{3,4}\z/ or exit 1;
    sysopen(my $fh, $path, O_RDONLY | $nofollow) or exit 1;
    my $fd_dir = -d "/dev/fd" ? "/dev/fd" : "/proc/self/fd";
    chmod(oct($mode), "$fd_dir/" . fileno($fh)) == 1 or exit 1;
    close($fh) or exit 1;
  ' "$path" "$mode"
}

fm_nofollow_spawn_capture() {
  local path=$1
  shift
  [ "$#" -gt 0 ] || return 1
  command -v perl >/dev/null 2>&1 || return 1
  exec perl -e '
    use Fcntl qw(:DEFAULT);
    use POSIX ();
    my ($path, @command) = @ARGV;
    my $nofollow = eval { O_NOFOLLOW() };
    defined($nofollow) or exit 1;
    POSIX::setpgid(0, 0) == 0 or exit 125;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_TRUNC | $nofollow, 0600) or exit 1;
    open(STDOUT, ">&", $fh) or exit 1;
    open(STDERR, ">&", $fh) or exit 1;
    exec @command;
    exit 127;
  ' "$path" "$@"
}
