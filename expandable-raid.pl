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

# CONVENTIONS: Constants are UPPER_CASED. Package Globals are $UPPER_CASED.
#              Lexicals are $lower_cased.  This eases the transition to an
#              encapsulated-procedural (sometimes called "Skimmable Code")
#              coding paradigm, vital to cleanly transition from PHP to Perl.

use constant {
  FALSE            => 0,          TRUE             => 1,           ERR_OK => 1,
  DEFAULT_CHUNK    => 64,                   DEFAULT_LEVEL    => 5,
  VALID_LEVELS     => qr{^(?:0|1|5|10)$},
  VALID_RAID_DEV   => qr{^/dev/md[0-9]+$},
  MIN_VALID_CHUNK  => 1,                    MAX_VALID_CHUNK  => 1024,
};

BEGIN { Getopt::Long::Configure('debug') if $ENV{EXPRAID_OPTIONS_DEBUG} }

our( $MODE, $VOLGROUP, $RAIDDEV, $LAYOUT, $DRYRUN )  =  ( FALSE ) x 5;
our( $CHUNK, $LEVEL, @PARTITIONS )  =  ( DEFAULT_CHUNK, DEFAULT_LEVEL, () );

$DRYRUN = TRUE if $ENV{EXPRAID_DEBUG};

GetOptions(
  'create|c'                  => sub { $MODE     = 'create';       },
  'extend|x'                  => sub { $MODE     = 'extend';       },
  'remove|rm'                 => sub { $MODE     = 'remove';       },
  'volgroup|vg|v=s'           => sub { $VOLGROUP = $_[1];          },
  'help|h|?'                  => sub { print usage(); exit(0);     },
  'version'                   => sub { VersionMessage( $VERSION ); },
  'layout|l=s'                => \$LAYOUT,
  'dry-run|dryrun|debug|d'    => \$DRYRUN,
  'partitions|p=s'  => sub {
    push @PARTITIONS, map { s{^([^/])}{/dev/$1}; $_; } split /,/, $_[1];
  },
  'level|l=i'                 => sub {
    $LEVEL = $_[1];
    die "Invalid RAID level: $LEVEL\n" unless $LEVEL =~ VALID_LEVELS;
  },
  'raid|r=s'                  => sub {
    ( $RAIDDEV = $_[1] ) =~ s{^([^/])}{/dev/$1};
    die "Invalid RAID device: $RAIDDEV\n"
      unless $RAIDDEV =~ m{^/dev/md[0-9]+$};
  },
  'chunk=i'                   => sub {
    $CHUNK = $_[1];
    die "Chunk size must be between 1-1024.\n"
      if $CHUNK < MIN_VALID_CHUNK || $CHUNK > MAX_VALID_CHUNK;
  },
) or die usage();

eval {
  die "You must specify either --create or --extend\n"  if ! $MODE;
  die "Volume group must be specified\n"  if ! $VOLGROUP;
  die "Partitions must be specified\n"
    if ! @PARTITIONS && $MODE =~ m/^(?:create|extend)$/;
  die "RAID device must be specified\n"  if $MODE eq 'extend' && ! $RAIDDEV;
  1; # Success.
} or die $@, usage();


# I'd prefer using system PROGRAM LIST but changes would be too pervasive atm.
my $sh_volgroup = php_escapeshellarg($VOLGROUP);

eval {
  for ( $MODE ) {
    /^(?:create)$       /x
      && do { $RAIDDEV = create_prep(\@PARTITIONS, $sh_volgroup ); };
    /^(?:extend|remove)$/x
      && do { ( $LEVEL, $CHUNK ) = extend_remove_prep( $RAIDDEV, $LEVEL, $CHUNK         ); };
    /^(?:create|extend)$/x
      && do { create_raid(                           ); };
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


# Globals read:
# Globals written/modified:
# Globals created:
sub extend_remove_prep {
  my( $raiddev, $level, $chunk ) = @_;
  my @old_partitions;
  my $dev = substr( $raiddev, 5 );
  print "Determining current partitions in $raiddev...\n";
  {
    open my $mdstat_fh, '<', '/proc/mdstat' or die $!;
    while( my $line = <$mdstat_fh> ) {
      next unless $line =~ m/^$dev : active raid([0-9]+) (.*)/;
      my $partition_info;
      ( $level, $partition_info ) = ( $1, $2 );
      die "ERROR: Unknown RAID level ($level)\n"
        unless $level =~ m/^(?:0|1|5|10)$/;
      die "ERROR: Could not get partition information from $partition_info\n"
        unless @old_partitions = $partition_info =~ /([a-z]+[0-9]+)\[[0-9]+\]/g;
    }
  } # Implicit close of $mdstat_fh.
  die "ERROR: Could not get partition information for $raiddev\n"
    unless @old_partitions;
    
  # Get the chunk size for the existing RAID device
  if( -e "/sys/block/$dev/md/chunk_size" ) {
    open my $cs_fh, '<', "/sys/block/$dev/md/chunk_size" or die $!;
    $chunk = int( <$cs_fh> / 1024 );
  } # Implicit close of $cs_fh;

  # Get the layout of the existing RAID device
}


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
  return TRUE if $DRYRUN || system( $cmd ) == 0;
  return FALSE if $err_ok;
  die "ERROR: Command did not complete successfully!\n";
}
