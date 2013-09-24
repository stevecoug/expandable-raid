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
# Perl translation Copyright (c) 2013 Steve Meyers, David Oswald
#
# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. If a copy of the MPL was not distributed with this file, you can
# obtain one at http://mozilla.org/MPL/2.0/.
#

BEGIN { Getopt::Long::Configure('debug') if $ENV{EXPRAID_OPTIONS_DEBUG} }

our $VERSION = '1.0';

# CONVENTIONS: Constants are UPPER_CASED. Package Globals are $UPPER_CASED.
#              Lexicals are $lower_cased.

use constant {
    FALSE           => 0,
    TRUE            => 1,
    ERR_OK          => 1,
    DEFAULT_CHUNK   => 64,
    DEFAULT_LEVEL   => 5,
    VALID_LEVELS    => qr{^(?:0|1|5|10)$},
    VALID_RAID_DEV  => qr{^/dev/md[0-9]+$},
    MIN_VALID_CHUNK => 1,
    MAX_VALID_CHUNK => 1024,
};

our ( $MODE, $VOLGROUP, $RAIDDEV, $LAYOUT, $DRYRUN ) = (FALSE) x 5;
our ( $CHUNK, $LEVEL, @PARTITIONS ) = ( DEFAULT_CHUNK, DEFAULT_LEVEL, () );

$DRYRUN = TRUE if $ENV{EXPRAID_DEBUG};

GetOptions(
    'create|c'        => sub { $MODE     = 'create'; },
    'extend|x'        => sub { $MODE     = 'extend'; },
    'remove|rm'       => sub { $MODE     = 'remove'; },
    'volgroup|vg|v=s' => sub { $VOLGROUP = $_[1]; },
    'help|h|?' => sub { print usage(); exit(0); },
    'version' => sub { VersionMessage($VERSION); },
    'layout|l=s'             => \$LAYOUT,
    'dry-run|dryrun|debug|d' => \$DRYRUN,
    'partitions|p=s'         => sub {
        push @PARTITIONS, map {
            my $part = $_;
            $part =~ s{^([^/])}{/dev/$1};
            $part;
          } split /,/, $_[1];
    },
    'level|l=i' => sub {
        $LEVEL = $_[1];
        die "Invalid RAID level: $LEVEL\n" unless $LEVEL =~ VALID_LEVELS;
    },
    'raid|r=s' => sub {
        ( $RAIDDEV = $_[1] ) =~ s{^([^/])}{/dev/$1};
        die "Invalid RAID device: $RAIDDEV\n"
          unless $RAIDDEV =~ m{^/dev/md[0-9]+$};
    },
    'chunk=i' => sub {
        $CHUNK = $_[1];
        die "Chunk size must be between 1-1024.\n"
          if $CHUNK < MIN_VALID_CHUNK || $CHUNK > MAX_VALID_CHUNK;
    },
) or die usage();

warn "****    DRYRUN mode.    ****\n" if $DRYRUN;

eval {
    die "You must specify either --create or --extend\n" if !$MODE;
    die "Volume group must be specified\n"               if !$VOLGROUP;
    die "Partitions must be specified\n"
      if !@PARTITIONS && $MODE =~ m/^(?:create|extend)$/;
    die "RAID device must be specified\n" if $MODE eq 'extend' && !$RAIDDEV;
    1;    # Success.
} or die $@, usage();

my $sh_volgroup = php_escapeshellarg($VOLGROUP);

eval {
    for ($MODE) {
        /^(?:create)$       /x && do {
            $RAIDDEV = create_prep( \@PARTITIONS, $sh_volgroup );
        };
        /^(?:extend|remove)$/x && do {
            my @old_partitions = ();
            ( $LEVEL, $CHUNK, $LAYOUT, @old_partitions ) =
              extend_remove_prep( $RAIDDEV, $LEVEL, $CHUNK, $sh_volgroup );
            @PARTITIONS = (@old_partitions, @PARTITIONS);
        };
        /^(?:create|extend)$/x && do {
            create_raid( $RAIDDEV, $LAYOUT, $LEVEL, $CHUNK, $sh_volgroup,
                \@PARTITIONS );
        };
    }
    1;    # Success; no exceptions.
} or die "$@\n";


# ------------- actions ------------

sub create_prep {
    my ( $parts, $sh_vg ) = @_;
    foreach my $part ( @{$parts} ) {
        my $sh_part = php_escapeshellarg($part);
        if (
            run_command( "pvdisplay $sh_part >/dev/null 2>/dev/null", ERR_OK ) )
        {
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


sub extend_remove_prep {
    my ( $raiddev, $level, $chunk, $sh_vg ) = @_;
    my @old_partitions;
    my $dev = substr( $raiddev, 5 );
    print "Determining current partitions in $raiddev...\n";
    
    open my $mdstat_fh, '<', '/proc/mdstat' or die $!;

    while ( my $line = <$mdstat_fh> ) {
        next unless $line =~ m/^$dev : active raid([0-9]+) (.*)/;
        my $partition_info;
        ( $level, $partition_info ) = ( $1, $2 );
        die "ERROR: Unknown RAID level ($level)\n"
          unless $level =~ m/^(?:0|1|5|10)$/;
        die "ERROR: Could not get partition information from $partition_info\n"
          unless @old_partitions
            = $partition_info =~ /([a-z]+[0-9]+)\[[0-9]+\]/g;
    }
    close $mdstat_fh;

    die "ERROR: Could not get partition information for $raiddev\n"
      unless @old_partitions;

    # Get the chunk size for the existing RAID device
    if ( -e "/sys/block/$dev/md/chunk_size" ) {
        open my $cs_fh, '<', "/sys/block/$dev/md/chunk_size" or die $!;
        $chunk = int( <$cs_fh> / 1024 );
        close $cs_fh;
    }

    # Get the layout of the existing RAID device
    my $layout;
    if ( $level =~ m/^(?:5|10)$/ ) {
        my $output = `mdadm --detail $raiddev`;
        die "ERROR: Could not determine layout of $raiddev\n"
          unless $output =~ m/Layout : (.*)$/m;
        $layout = $1;

        if ( $level == 10 ) {
            my ( $layout_type, $layout_num ) = split /=/, $layout;
            $layout_num = int $layout_num;
            die "ERROR: $raiddev has an unknown layout: $layout\n"
              if $layout_num < 1 || $layout_type !~ m/^(?:near|far|offset)$/;
            $layout = substr( $layout_type, 0, 1 ) . $layout_num;
        }
        elsif ( $level == 5 ) {
            die "ERROR: $raiddev has an unknown layout: $layout\n"
              unless $layout =~ m/^(?:left|right)-a?symmetric$/;
        }
    }
    print "Removing RAID device: $raiddev\n";
    run_command( "pvmove --autobackup y $raiddev", ERR_OK );
    run_command("vgreduce --autobackup y $sh_vg $raiddev");
    run_command("pvremove $raiddev");

    print "Stopping RAID device $raiddev\n";
    run_command("mdadm --stop $raiddev");

    print "Zeroing superblocks for old RAID drives\n";
    my @partitions;
    foreach my $part (@old_partitions) {
        $part = "/dev/$part";
        print " + $part\n";
        run_command("mdadm --zero-superblock $part");
        push @partitions, $part;
    }
    return ( $level, $chunk, $layout, @partitions );
}


sub create_raid {
    my ( $raiddev, $layout, $level, $chunk, $sh_vg, $parts_aref ) = @_;

    print "Creating RAID devicd $raiddev\n";

    my $num_parts     = @$parts_aref;
    my $sh_partitions = join q{ }, map { php_escapeshellarg($_) } @$parts_aref;
    my $other_options = q{};
    $other_options = " --layout=" . php_escapeshellarg($layout);

    run_command( "mdadm --create --verbose $raiddev --level=$level "
                 . "--chunk=$chunk $other_options --raid-devices=$num_parts "
                 . "$sh_partitions"
    );
    run_command("pvcreate $raiddev");
    run_command("vgextend $sh_vg $raiddev");
    return; # Nothing.
}

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
    my ( $cmd, $err_ok ) = @_;
    print " + $cmd\n";
    return TRUE if $DRYRUN || system($cmd ) == 0;
    return FALSE if $err_ok;
    die "ERROR: Command did not complete successfully!\n";
}
