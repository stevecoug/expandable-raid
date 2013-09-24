#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

$ENV{EXPRAID_DEBUG} = 1;

my $output = ` ./expandable-raid.pl --create --level 10 --chunk 32 --layout f2 --vg vg0 --partitions vdb1,vdc1,vdd1,vde1`;
ok(
  $output !~ /ARRAY\(0x\p{hex}+\)/,
  'No array-ref / array mismatches.'
);

done_testing;
