#!/usr/bin/python3
# early-command of the airos-summit autoinstall: write the storage section of
# /autoinstall.yaml for this machine: the three 600 GB disks as one RAID1 (/),
# each with an EFI system partition. The 1.2 TB disks are left for later.
import json, subprocess, sys, yaml
out = subprocess.run(["lsblk", "-J", "-b", "-d", "-o", "NAME,SIZE,TYPE,TRAN,RM,MODEL,SERIAL,WWN"],
	capture_output=True, text=True, check=True).stdout
disks = [d for d in json.loads(out)["blockdevices"]
	if d["type"] == "disk" and d.get("tran") != "usb" and not d.get("rm")
	and 500e9 < int(d["size"]) < 700e9]
disks.sort(key=lambda d: d["name"])
subprocess.run("(date; lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,LABEL,MODEL,SERIAL,WWN; cat /proc/mdstat; "
	"blkid) > /run/airos-pre-install.txt 2>&1", shell=True)
if len(disks) != 3:
	sys.exit("expected three 600 GB disks, found: %r" % disks)
config = []
members = []
for i, d in enumerate(disks):
	config += [
		{"type": "disk", "id": f"d{i}", "path": "/dev/" + d["name"], "ptable": "gpt",
			"wipe": "superblock-recursive", "preserve": False, "grub_device": False},
		{"type": "partition", "id": f"d{i}p1", "device": f"d{i}", "number": 1, "size": "1G",
			"flag": "boot", "grub_device": True, "wipe": "superblock", "preserve": False},
		{"type": "format", "id": f"d{i}p1f", "volume": f"d{i}p1", "fstype": "fat32", "preserve": False},
		{"type": "partition", "id": f"d{i}p2", "device": f"d{i}", "number": 2, "size": -1,
			"wipe": "superblock", "preserve": False},
	]
	members.append(f"d{i}p2")
config += [
	{"type": "raid", "id": "md0", "name": "md0", "raidlevel": 1, "devices": members,
		"spare_devices": [], "preserve": False},
	{"type": "format", "id": "rootfs", "volume": "md0", "fstype": "ext4", "preserve": False},
	{"type": "mount", "id": "mount-root", "device": "rootfs", "path": "/"},
	{"type": "mount", "id": "mount-esp", "device": "d0p1f", "path": "/boot/efi"},
]
path = "/autoinstall.yaml"
doc = yaml.safe_load(open(path))
target = doc["autoinstall"] if "autoinstall" in doc else doc
target["storage"] = {"swap": {"size": 0}, "config": config}
with open(path, "w") as f:
	yaml.safe_dump(doc, f, default_flow_style=False)
print("storage:", [d["name"] for d in disks])
