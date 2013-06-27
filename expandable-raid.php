#!/usr/bin/php
<?

$mode = false;
$partitions = [];
$volgroup = false;
$raiddev = false;
$chunk = 32;
$level = 5;

try {
	while ($i = 1; $i < $argc; $i++) {
		switch ($argv[$i]) {
			case "-c":
			case "--create":
				$mode = "create";
			break;
			
			case "-x":
			case "--extend":
				$mode = "extend";
			break;
			
			case "-v":
			case "--vg":
				$volgroup = $argv[++$i];
			break;
			
			case "-l":
			case "--level":
				$level = intval($argv[++$i]);
				if (!in_array($level, [ 0, 1, 5 ])) throw new Exception("Invalid RAID level: $level");
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
			
			default:
				throw new Exception("Invalid argument: ".$argv[$i]);
			break;
		}
	}
	
	if ($mode === false) throw new Exception("You must specify either --create or --extend");
	
	if ($volgroup === false) throw new Exception("Volume group must be specified");
	if (count($partitions) == 0) throw new Exception("Partitions must be specified");
	
	if ($mode == "extend") {
		if ($raiddev === false) throw new Exception("RAID device must be specified");
	}
} catch (Exception $e) {
	printf("ERROR: %s\n", $e->getMessage());
	echo "\n";
	echo "Usage:\n";
	echo "    expandable-raid.php --create [--level RAIDLEVEL] [--chunk CHUNKKB] --vg VOLGROUP --partitions PART1,PART2,PART3\n";
	echo "    expandable-raid.php --extend --vg VOLGROUP --raid RAIDDEV --partition PART1\n";
	echo "\n";
	exit(1);
}



function run_command($cmd, $err_ok = false) {
	echo " + $cmd\n";
	return true;
	
	system($cmd, $retval);
	if ($retval > 0) {
		if ($err_ok) return false;
		echo "ERROR: command did not complete successfully!\n";
		echo "$cmd\n";
		exit(1);
	}
	return true;
}


// Some common escaping...
$sh_volgroup = escapeshellarg($volgroup);


if ($mode === "create") {
	//************************** BEGIN CREATE MODE PREPARATION ****************************
	
	// Make sure any partitions being used in a volume group are moved off
	foreach ($partitions as $part) {
		$sh_part = escapeshellarg($part);
		if (run_command("pvdisplay $sh_part >/dev/null 2>/dev/null", true)) {
			echo "Removing $part from volume group...\n";
			run_command("pvmove --autobackup y $sh_part");
			run_command("vgreduce --autobackup y $sh_volgroup $sh_part");
			run_command("pvremove --autobackup y $sh_part");
		}
	}
	
	for ($i = 0; file_exists("/dev/md$i"); $i++);
	$raiddev = "/dev/md$i";
	
	//************************** END CREATE MODE PREPARATION ****************************
} else if ($mode === "extend") {
	//************************** BEGIN EXTEND MODE PREPARATION ****************************
	
	echo "Removing RAID device: $raiddev\n";
	run_command("pvmove --autobackup y $raiddev");
	run_command("vgreduce --autobackup y $sh_volgroup $raiddev");
	run_command("pvremove --autobackup y $raiddev");
	
	echo "Determining current partitions in the RAID device...\n";
	$old_partitions = false;
	$dev = substr($raiddev, 5);
	foreach (file("/proc/mdstat") as $line) {
		if (!preg_match("/^$dev : active raid([0-9]) (.*)/", $line, $regs)) continue;
		
		$level = intval($regs[1]);
		if (!in_array($level, [ 0, 1, 5 ])) {
			echo "ERROR: Unknown RAID level ($level)\n";
			exit(2);
		}
		
		if (!preg_match_all('/([a-z]+[0-9]+)\[[0-9]+\]/', $regs[2], $matches)) {
			echo "ERROR: Could not get partition information from $regs[2]\n";
			exit(2);
		}
		$old_partitions = $matches[1];
	}
	if ($old_partitions === false) {
		echo "ERROR: Could not get partition information for $raiddev\n";
		exit(2);
	}
	foreach ($old_partitions as $part) {
		$partitions[] = $part;
		echo " + $part\n";
	}
	
	echo "Stopping RAID device $raiddev\n";
	run_command("mdadm --stop $raiddev");
	
	//************************** END EXTEND MODE PREPARATION ****************************
}




//************************** BEGIN RAID DEVICE CREATION ****************************

echo "Creating RAID device: $raiddev\n";

$num_parts = count($partitions);
$sh_partitions = "";
foreach ($partitions as $part) {
	$sh_partitions .= escapeshellarg($part) . " ";
}

run_command("mdadm --create --verbose /dev/md$raiddev --level=$level --raid-devices=$num_parts $sh_partitions");
run_command("pvcreate /dev/md$raiddev");
run_command("vgextend $sh_volgroup /dev/md$raiddev");

//************************** END RAID DEVICE CREATION ****************************

