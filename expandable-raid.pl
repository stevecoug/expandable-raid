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
  FALSE            => 0,                TRUE             => 1,
  DEFAULT_CHUNK    => 64,               DEFAULT_LEVEL    => 5,
  VALID_LEVELS     => [ 0, 1, 5, 10 ],  VALID_RAID_DEV   => qr{^/dev/md[0-9]+$},
  MIN_VALID_CHUNK  => 1,                MAX_VALID_CHUNK  => 1024,
};

BEGIN { Getopt::Long::Configure('debug') if $ENV{EXPRAID_OPTIONS_DEBUG} }

our( $mode, $volgroup, $raiddev, $layout, $dryrun )  =  ( FALSE ) x 5;
our( $chunk, $level, $partitions )  =  ( DEFAULT_CHUNK, DEFAULT_LEVEL, [] );

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
    push @{$partitions}, map { s{^([^/])}{/dev/$1}; $_; } split /,/, $_[1];
  },
  'level|l=i'                 => sub {
    $level = $_[1];
    die "Invalid RAID level: $level\n"
      unless grep{ $_==$level } @{+VALID_LEVELS};
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
    if ! @{$partitions} && $mode =~ m/^(?:create|extend)$/;
  die "RAID device must be specified\n"  if $mode eq 'extend' && ! $raiddev;
  1; # Success.
} or die $@, usage();


# I'd prefer using system PROGRAM LIST but changes would be too pervasive atm.
my $sh_volgroup = php_escapeshellarg($volgroup);

eval {

  if ( $mode eq 'create' ) {
    $raiddev = create_prep($partitions);
  }
  elsif ( $mode eq 'extend' || $mode eq 'remove' ) {
    extend_remove_prep();
  }

  if( $mode eq 'create' || $mode eq 'extend' ) {
    create_raid();
  }
  
  1; # Success; no exceptions.

} or die "$@\n";


# ------------- actions ------------

sub create_prep {
  my $parts = shift;
  foreach my $part ( @$parts ) {
    my $sh_part = php_escapeshellarg($part);
    if( run_command( "pvdisplay $sh_part >/dev/null 2>/dev/null", TRUE ) ) {
      print "Removing $part from volume group...\n";
      run_command("pvmove --autobackup y $sh_part", TRUE);
      run_command("vgreduce --autobackup y $sh_volgroup $sh_part");
      run_command("pvremove $sh_part");
    }
  }
  my $i = 0;
  $i++ while -e "/dev/md$i";
  return "/dev/md$i";
}

sub extend_remove_prep {
  my( $raid_device ) = @_;
  my $old_partitions = FALSE;
  my $dev = substr( $raid_device, 5 );

  print "Determining current partitions in $raid_device...\n";
  open my $mdstat, '<', '/proc/mdstat'
    or die "Couldn't read /proc/mdstat: $!\n";
  while( my $line = <$mdstat> ) {
    chomp;
    next unless $line =~ m{$dev : active raid([0-9]+) (.*)};
    # Can this be a lexical, and the sub return its value?  Or pass via param?
    $level = php_intval( $1 ); # Perl should DTRT without the explicit convrsn.
    my $partition_info = $2;
    die "ERROR: Unknown RAID level ($level)\n"
      unless grep { $level == $_ } @{+VALID_LEVELS};
    my( @matches ) = $partition_info =~ m/([a-z]+[0-9]+)\[[0-9]+\]/g;
    die "ERROR: Could not get partition information from $partition_info\n"
      unless scalar @matches;
    $old_partitions = $matches[1];
  }
  die "ERROR: Could not get partition information for $raiddev"
    unless $old_partitions;

  # Get the chunk size for the existing RAID device.
  my $md = substr( $raiddev, 5 );  # Can't we use $dev?
  my $cs_file = "/sys/block/$md/md/chunk_size";
  if( -e $cs_file ) {
    my $cs_content = do {
      local $/ = undef;
      open my $ifh, '<', $cs_file or die "$!\n";
      <$ifh>;
    };
    $chunk = php_intval( $cs_content / 1024 )
  }

  # Get the layout of the existing RAID device.
  if( grep { $level == $_ } ( 5, 10 ) ) {
    my $output = `mdadm --detail $raiddev`;
    die "Could not determine layout of $raiddev\n"
      unless $output =~ m/Layout : (.*)$/m;
    my $layout = $1;

    if( $level == 10 ) {
      my( $layout_type, $layout_num ) = split /=/, $layout;
      $layout_num = php_intval($layout_num); # Again, why?
      die "$raiddev has an unknown layout: $layout\n"
        if $layout_num < 1 || !grep {$layout_type eq $_} qw( near far offset );
      $layout = substr( $layout_type, 0, 1 ) . $layout_num;
    }
    elsif ( $level == 5 ) {
      die "$raiddev has an unknown layout: $layout\n"
        unless $layout =~ m/^(?:left|right)-(?:a?symmetric)$/;
    }
  }

  print "Removing RAID device: $raiddev\n";
  run_command( "pvmove --autobackup y $raiddev", TRUE );
  run_command( "vgreduce --autobackup y $sh_volgroup $raiddev" );
  run_command( "pvremove $raiddev" );

  print "Stopping RAID device $raiddev\n";
  run_command( "mdadm --stop $raiddev" );

  print "Zeroing superblocks for old RAID drives\n";
  foreach my $part ( $old_partitions ) {
    $part = "/dev/$part";
    print " + $part\n";
    run_command( "mdadm --zero-superblock $part" );
    push @{$partitions}, $part;
  }
}

sub create_raid { ... }
sub extend_raid { ... }

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

sub php_intval {
  # Theory: This is unnessary thanks to Perl's dwimery.
  return sprintf "%d", @_;
}

sub run_command {
  my( $cmd, $err_ok ) = @_;
  print " + $cmd\n";
  return TRUE if $dryrun || system( $cmd ) == 0;
  die "ERROR: Command did not complete successfully!\n" unless $err_ok;
  return FALSE;
}
