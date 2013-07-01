#!/usr/bin/php
<?

/* vim set noexpandtab */

/**
 * 
 * expandable-raid.php
 * 
 * Use Linux RAID and LVM together to add disks to your RAID array without stopping it
 * 
 * https://github.com/stevecoug/expandable-raid
 * 
 * Copyright (c) 2013 Steve Meyers
 * 
 * This Source Code Form is subject to the terms of the Mozilla Public License,
 * v. 2.0. If a copy of the MPL was not distributed with this file, You can
 * obtain one at http://mozilla.org/MPL/2.0/.
 *
 */


$mode = false;
$partitions = [];
$volgroup = false;
$raiddev = false;
$chunk = 64;
$level = 5;
$layout = false;
$dryrun = false;

try {
	for ($i = 1; $i < $argc; $i++) {
		switch ($argv[$i]) {
			case "-c":
			case "--create":
				$mode = "create";
			break;
			
			case "-x":
			case "--extend":
				$mode = "extend";
			break;
			
			case "--remove":
				$mode = "remove";
			break;
			
			case "-v":
			case "--vg":
			case "--volgroup":
				$volgroup = $argv[++$i];
			break;
			
			case "-l":
			case "--level":
				$level = intval($argv[++$i]);
				if (!in_array($level, [ 0, 1, 5, 10 ])) throw new Exception("Invalid RAID level: $level");
			break;
			
			case "-r":
			case "--raid":
				$raiddev = $argv[++$i];
				if ($raiddev[0] !== "/") $raiddev = "/dev/$raiddev";
				if (!preg_match('|^/dev/md[0-9]+$|', $raiddev)) throw new Exception("Invalid RAID device: $raiddev");
			break;
			
			case "-p":
			case "--partition":
			case "--partitions":
				$partitions = [];
				$tmp = explode(",", $argv[++$i]);
				foreach ($tmp as $part) {
					if ($part[0] !== "/") $part = "/dev/$part";
					$partitions[] = $part;
				}
			break;
			
			case "--chunk":
				$chunk = intval($argv[++$i]);
				if ($chunk < 1 || $chunk > 1024) throw new Exception("Chunk size must be between 1-1024");
			break;
			
			case "--layout":
				$layout = $argv[++$i];
			break;
			
			case "--dry-run":
				$dryrun = true;
			break;
			
			default:
				throw new Exception("Invalid argument: ".$argv[$i]);
			break;
		}
	}
	
	if ($mode === false) throw new Exception("You must specify either --create or --extend");
	
	if ($volgroup === false) throw new Exception("Volume group must be specified");
	if (count($partitions) == 0 && in_array($mode, [ "create", "extend" ])) throw new Exception("Partitions must be specified");
	
	if ($mode == "extend") {
		if ($raiddev === false) throw new Exception("RAID device must be specified");
	}
} catch (Exception $e) {
	printf("ERROR: %s\n", $e->getMessage());
	echo "\n";
	echo "Usage:\n";
	echo "    expandable-raid.php --create [--level RAIDLEVEL] [--chunk CHUNKKB] [--layout LAYOUT] --vg VOLGROUP --partitions PART1,PART2,PART3\n";
	echo "    expandable-raid.php --extend --vg VOLGROUP --raid RAIDDEV --partition PART1\n";
	echo "    expandable-raid.php --remove --vg VOLGROUP --raid RAIDDEV\n";
	echo "\n";
	exit(1);
}



function run_command($cmd, $err_ok = false) {
	echo " + $cmd\n";
	
	if ($GLOBALS['dryrun']) return true;
	
	system($cmd, $retval);
	if ($retval > 0) {
		if ($err_ok) return false;
		throw new Exception("ERROR: command did not complete successfully!");
	}
	return true;
}


// Some common escaping...
$sh_volgroup = escapeshellarg($volgroup);


try {
	if ($mode === "create") {
		//************************** BEGIN CREATE MODE PREPARATION ****************************
		
		// Make sure any partitions being used in a volume group are moved off
		foreach ($partitions as $part) {
			$sh_part = escapeshellarg($part);
			if (run_command("pvdisplay $sh_part >/dev/null 2>/dev/null", true)) {
				echo "Removing $part from volume group...\n";
				run_command("pvmove --autobackup y $sh_part", true);
				run_command("vgreduce --autobackup y $sh_volgroup $sh_part");
				run_command("pvremove $sh_part");
			}
		}
		
		for ($i = 0; file_exists("/dev/md$i"); $i++);
		$raiddev = "/dev/md$i";
		
		//************************** END CREATE MODE PREPARATION ****************************
	} else if ($mode === "extend" || $mode === "remove") {
		//************************** BEGIN EXTEND MODE PREPARATION (OR REMOVE MODE) ****************************
		
		$old_partitions = false;
		$dev = substr($raiddev, 5);
		
		echo "Determining current partitions in $raiddev...\n";
		foreach (file("/proc/mdstat") as $line) {
			if (!preg_match("/^$dev : active raid([0-9]+) (.*)/", $line, $regs)) continue;
			
			$level = intval($regs[1]);
			if (!in_array($level, [ 0, 1, 5, 10 ])) {
				throw new Exception("ERROR: Unknown RAID level ($level)");
			}
			
			if (!preg_match_all('/([a-z]+[0-9]+)\[[0-9]+\]/', $regs[2], $matches)) {
				throw new Exception("ERROR: Could not get partition information from $regs[2]");
			}
			$old_partitions = $matches[1];
		}
		if ($old_partitions === false) {
			throw new Exception("ERROR: Could not get partition information for $raiddev");
		}
		
		// Get the chunk size for the existing RAID device
		$md = substr($raiddev, 5);
		if (file_exists("/sys/block/$md/md/chunk_size")) {
			$chunk = intval(file_get_contents("/sys/block/$md/md/chunk_size")) / 1024;
		}
		
		// Get the layout of the existing RAID device
		if (in_array($level, [ 5, 10 ])) {
			$output = shell_exec("mdadm --detail $raiddev");
			if (!preg_match('/Layout : (.*)$/m', $output, $regs)) throw new Exception("Could not determine layout of $raiddev");
			$layout = $regs[1];
			
			if ($level == 10) {
				list($layout_type, $layout_num) = explode("=", $layout);
				$layout_num = intval($layout_num);
				if ($layout_num < 1 || !in_array($layout_type, [ "near", "far", "offset" ])) {
					throw new Exception("$raiddev has an unknown layout: $layout");
				}
				$layout = $layout_type[0] . $layout_num;
			} else if ($level == 5) {
				if (!in_array($layout, [ "left-asymmetric", "left-symmetric", "right-asymmetric", "right-symmetric" ])) {
					throw new Exception("$raiddev has an unknown layout: $layout");
				}
			}
		}
		
		echo "Removing RAID device: $raiddev\n";
		run_command("pvmove --autobackup y $raiddev", true);
		run_command("vgreduce --autobackup y $sh_volgroup $raiddev");
		run_command("pvremove $raiddev");
		
		echo "Stopping RAID device $raiddev\n";
		run_command("mdadm --stop $raiddev");
		
		echo "Zeroing superblocks for old RAID drives\n";
		foreach ($old_partitions as $part) {
			$part = "/dev/$part";
			echo " + $part\n";
			run_command("mdadm --zero-superblock $part");
			$partitions[] = $part;
		}
		
		//************************** END EXTEND MODE PREPARATION ****************************
	}
	
	
	
	
	if ($mode === "create" || $mode === "extend") {
		//************************** BEGIN RAID DEVICE CREATION ****************************
		
		echo "Creating RAID device: $raiddev\n";
		
		$num_parts = count($partitions);
		$sh_partitions = "";
		foreach ($partitions as $part) {
			$sh_partitions .= escapeshellarg($part) . " ";
		}
		
		$other_options = "";
		if ($layout !== false) $other_options .= " --layout=".escapeshellarg($layout);
		
		run_command("mdadm --create --verbose $raiddev --level=$level --chunk=$chunk $other_options --raid-devices=$num_parts $sh_partitions");
		run_command("pvcreate $raiddev");
		run_command("vgextend $sh_volgroup $raiddev");
		
		//************************** END RAID DEVICE CREATION ****************************
	}
} catch (Exception $e) {
	printf("ERROR: %s\n", $e->getMessage());
	exit(2);
}
