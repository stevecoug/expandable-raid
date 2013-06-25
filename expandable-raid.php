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
			break;
			
			case "-p":
			case "--partition":
			case "--partitions":
				$partitions = explode(",", $argv[++$i]);
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
