#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long qw( VersionMessage );

#
# expandable-raid.pl
#
# Use Linux RAID and LVM together to add disks to your RAID array without
# stopping it.
#
# Github repositories
# https://github.com/stevecoug/expandable-raid  (PHP)
# https://github.com/daoswald/expandable-raid   (Perl rewrite)
#
# Copyright (c) 2013 Steve Meyers.
# Perl adaptation Copyright (c) 2013 Steve Meyers, David Oswald
#
# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, you can
# obtain one at http://mozilla.org/MPL/2.0/.
#

our $VERSION = '1.0';

use constant {
  FALSE            => 0,          TRUE             => 1,           ERR_OK => 1,
  DEFAULT_CHUNK    => 64,                   DEFAULT_LEVEL    => 5,
  VALID_LEVELS     => qr{^(?:0|1|5|10)$},
  VALID_RAID_DEV   => qr{^/dev/md[0-9]+$},
  MIN_VALID_CHUNK  => 1,                    MAX_VALID_CHUNK  => 1024,
};

BEGIN { Getopt::Long::Configure('debug') if $ENV{EXPRAID_OPTIONS_DEBUG} }

our( $mode, $volgroup, $raiddev, $layout, $dryrun )  =  ( FALSE ) x 5;
our( $chunk, $level, @partitions )  =  ( DEFAULT_CHUNK, DEFAULT_LEVEL, () );

$dryrun = TRUE if $ENV{EXPRAID_DEBUG};

GetOptions(
  'create|c'                  => sub { $mode     = 'create';       },
  'extend|x'                  => sub { $mode     = 'extend';       },
  'remove|rm'                 => sub { $mode     = 'remove';       },
  'volgroup|vg|v=s'           => sub { $volgroup = $_[1];          },
  'help|h|?'                  => sub { print usage(); exit(0);     },
  'version'                   => sub { VersionMessage( $VERSION ); },
  'layout|l=s'                => \$layout,
  'dry-run|dryrun|debug|d'    => \$dryrun,
  'partitions|p=s'  => sub {
    push @partitions, map { s{^([^/])}{/dev/$1}; $_; } split /,/, $_[1];
  },
  'level|l=i'                 => sub {
    $level = $_[1];
    die "Invalid RAID level: $level\n" unless $level =~ VALID_LEVELS;
  },
  'raid|r=s'                  => sub {
    ( $raiddev = $_[1] ) =~ s{^([^/])}{/dev/$1};
    die "Invalid RAID device: $raiddev\n"
      unless $raiddev =~ m{^/dev/md[0-9]+$};
  },
  'chunk=i'                   => sub {
    $chunk = $_[1];
    die "Chunk size must be between 1-1024.\n"
      if $chunk < MIN_VALID_CHUNK || $chunk > MAX_VALID_CHUNK;
  },
) or die usage();

eval {
  die "You must specify either --create or --extend\n"  if ! $mode;
  die "Volume group must be specified\n"  if ! $volgroup;
  die "Partitions must be specified\n"
    if ! @partitions && $mode =~ m/^(?:create|extend)$/;
  die "RAID device must be specified\n"  if $mode eq 'extend' && ! $raiddev;
  1; # Success.
} or die $@, usage();


# I'd prefer using system PROGRAM LIST but changes would be too pervasive atm.
my $sh_volgroup = php_escapeshellarg($volgroup);

eval {
  for ( $mode ) {
    /^(?:create)$       /x && do { $raiddev = create_prep(\@partitions, $sh_volgroup );     };
    /^(?:extend|remove)$/x && do { extend_remove_prep(                    ); };
    /^(?:create|extend)$/x && do { create_raid(                           ); };
  }
  1; # Success; no exceptions.
} or die "$@\n";


# ------------- actions ------------

sub create_prep{
  my( $parts, $sh_vg ) = @_;
  foreach my $part ( @{$parts} ) {
    my $sh_part = escapeshellarg($part);
    if( run_command( "pvdisplay $sh_part >/dev/null 2>/dev/null", ERR_OK ) ) {
      print "Removing $part from volume group...\n";
      run_command( "pvmove --autobackup y $sh_part", ERR_OK );
      run_command( "vgreduce --autobackup y $sh_vg $sh_part" );
      run_command( "pvremove $sh_part" );
    }
  }
  my $i = 0;
  $i++ while -e "/dev/md$i";
  return "/dev/md$i";
}

sub extend_remove_prep { ... }
sub create_raid { ... }

# ------------- utility functions ------------

sub usage {
  return << 'USAGE';

Usage:
    expandable-raid.pl --create [--level RAIDLEVEL] [--chunk CHUNKKB] [--layout LAYOUT] --vg VOLGROUP --partitions PART1,PART2,PART3 [--dryrun]
    expandable-raid.pl --extend --vg VOLGROUP --raid RAIDDEV --partition PART1 [--dryrun]
    expandable-raid.pl --remove --vg VOLGROUP --raid RAIDDEV [--dryrun]
    expandable-raid.pl --version
    expandable-raid.pl --help

Setting EXPRAID_DEBUG forces "--dryrun mode". 

USAGE
}

sub php_escapeshellarg { 
  my $str = @_ ? shift : $_;
  $str =~ s/((?:^|[^\\])(?:\\\\)*)'/$1\\'/g;
  return "'$str'";
}

sub run_command {
  my( $cmd, $err_ok ) = @_;
  print " + $cmd\n";
  return TRUE if $dryrun || system( $cmd ) == 0;
  return FALSE if $err_ok;
  die "ERROR: Command did not complete successfully!\n";
}
