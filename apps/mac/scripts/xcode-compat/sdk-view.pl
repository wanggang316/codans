#!/usr/bin/perl
# Usage: sdk-view.pl <sdk> <view>
#
# Builds a view of <sdk> at <view> for zig 0.15.2 (see activate.sh).
# Directories that hold text stubs (.tbd) are real directories. Each stub
# gets `arm64-macos` next to `arm64e-macos` in every target list that lacks
# it. usr/include/math.h wraps the real header and adds fallbacks for
# INFINITY and NAN: the SDK's math.h gets them from Clang's float.h through
# `__need_infinity_nan`, which zig 0.15.2's bundled float.h predates, so
# libc++ does not compile. Everything else is a symlink to the real SDK.
# Symlinks inside the SDK are relative, so they are copied as-is and
# resolve inside the view.
use strict;
use warnings;
use File::Find;
use File::Path qw(make_path);

my ($sdk, $view) = @ARGV;
die "usage: $0 <sdk> <view>\n" unless defined $view;

# Real directories: every directory on the way to a stub, plus usr/include.
my %real_dirs;
find({ no_chdir => 1, wanted => sub {
  return unless -f $_ && !-l $_ && /\.tbd\z/;
  my $dir = $File::Find::dir;
  while (!$real_dirs{$dir}++ && $dir ne $sdk) {
    $dir =~ s{/[^/]*\z}{};
  }
} }, $sdk);
$real_dirs{"$sdk/usr/include"} = 1;
$real_dirs{"$sdk/usr"} = 1;

for my $dir (sort keys %real_dirs) {
  (my $rel = $dir) =~ s{\A\Q$sdk\E}{};
  make_path("$view$rel");
  opendir(my $dh, $dir) or die "opendir $dir: $!\n";
  for my $name (readdir $dh) {
    next if $name eq '.' || $name eq '..';
    my $from = "$dir/$name";
    my $to = "$view$rel/$name";
    if (-l $from) {
      symlink(readlink($from), $to) or die "symlink $to: $!\n";
    } elsif (-d $from && $real_dirs{$from}) {
      next;
    } elsif ($from eq "$sdk/usr/include/math.h") {
      write_file($to, <<"END");
#include "$from"

#ifndef INFINITY
#define INFINITY (__builtin_inff())
#endif

#ifndef NAN
#define NAN (__builtin_nanf(""))
#endif
END
    } elsif (-f $from && $name =~ /\.tbd\z/) {
      open(my $in, '<', $from) or die "open $from: $!\n";
      my $stub = do { local $/; <$in> };
      $stub =~ s{\[[^\]]*\]}{
        my $list = $&;
        ($list =~ /\barm64e-macos\b/ && $list !~ /\barm64-macos\b/)
          ? $list =~ s/\barm64e-macos\b/arm64-macos, arm64e-macos/r
          : $list
      }ge;
      write_file($to, $stub);
    } else {
      symlink($from, $to) or die "symlink $to: $!\n";
    }
  }
  closedir($dh);
}

sub write_file {
  my ($path, $contents) = @_;
  open(my $out, '>', $path) or die "open $path: $!\n";
  print $out $contents;
  close($out) or die "close $path: $!\n";
}
