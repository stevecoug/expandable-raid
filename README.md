expandable-raid
===============

Use Linux RAID and LVM together to add disks to your RAID array without stopping it, similar to how a Drobo works.  I have no
idea how Drobo actually accomplishes this, but this script will accomplish some of the same magic.

### Usage

```
expandable-raid.php --create [--level RAIDLEVEL] [--chunk CHUNKKB] [--layout LAYOUT] --vg VOLGROUP --partitions PART1,PART2,PART3
expandable-raid.php --extend --vg VOLGROUP --raid RAIDDEV --partition PART1
```

### Filesystem hints

You can achieve better performance from your filesystem if it is properly aligned to your RAID devices.  See the following page for more information: http://erikugel.wordpress.com/2011/04/14/the-quest-for-the-fastest-linux-filesystem/

This page has a calculator for the ext4 filesystem's tuning parameters: http://uclibc.org/~aldot/mkfs_stride.html

### How it works

Have you ever wanted to have a Drobo-like ability to add a disk to your RAID array and have the storage just expand to fill it?  I’ve been toying around with a way to do just that.

The theory is that you create stripes across your disks of RAID arrays, and then combine them into an LVM volume group.  In order to expand onto another disk, you do the following:

1. Create partitions on the new disk the same size as the partitions in your existing RAID device stripes
1. Add those partitions to the volume group, if you need free space during the expansion

Once you've done that, use expandable-raid.php to extend your RAID arrays.  You will need to run it once for each RAID device in your volume group.  It will:

1. Remove the new partition from the volume group, if applicable
1. Use pvmove to move all logical volumes off of the existing RAID device
1. Use vgreduce to remove the RAID device from the volume group
1. Use pvremove to make it no longer an LVM pv
1. Stop the RAID device with mdadm, and zero the superblocks
1. Recreate the RAID device with mdadm, including the new partition
1. Make the new RAID device an LVM pv with pvcreate
1. Add the new pv to the volume group using vgextend

### Roadmap

In the future, this utility may handle the partition management as well, but that is a little more tricky.  I'll probably also rewrite it in Perl or Python, since those are more likely to be already installed on a server.

### License and copyright

Copyright (c) 2013 Steve Meyers

This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.

