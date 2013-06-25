expandable-raid
===============

Use Linux RAID and LVM together to add disks to your RAID array without stopping it

### Usage

```
expandable-raid.php --create [--level RAIDLEVEL] [--chunk CHUNKKB] --vg VOLGROUP --partitions PART1,PART2,PART3
expandable-raid.php --extend --vg VOLGROUP --raid RAIDDEV --partition PART1
```
