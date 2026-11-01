#!/bin/bash
# setup-data3.sh: build /data3, a RAID10 of the six 1.2 TB SAS disks on
# airos-build (four added 2026-10-28, two that sat unused with old ZFS
# labels), and move the CI's bulky, mostly sequential data onto it:
#
#   /data2/airos/artifacts  images, release feeds, CI status (nginx serves it)
#   /data2/airos/cache      downloads, HaikuPorts packages, fork git caches
#
# Each moves to /data3/airos/NAME and is bind-mounted back at its old path, so
# airos-ci, the nginx container, the dashboard and every script that names
# /data2/airos keep working unchanged. Build trees (/data1/airos/build), job
# scratch (/data2/airos/work, tmp) and runner work dirs stay on the SSDs: they
# are small-file heavy, and the Haiku host tools' attribute sidecar is keyed by
# inode, so copying files that have attributes would detach them.
#
# Run as the owner (needs sudo): sudo server/setup-data3.sh
# Every step checks what is already done, so the script can be run again after
# an interruption. It wipes the six disks only after you type WIPE.
set -euo pipefail
[[ $EUID == 0 ]] || exec sudo "$0" "$@"

# The disks by WWN (sdX names change between boots).
DISKS="wwn-0x5000cca01d751be8 wwn-0x5000cca01d7523ac wwn-0x5000cca01d696168
 wwn-0x5000cca01d73f6b8 wwn-0x5000cca01d7517b4 wwn-0x5000c50076a2045f"
MD=/dev/md/data3
MNT=/data3
MOVE="artifacts cache"
RUNNERS="actions.runner.*"

note() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

note "disks"
devs=()
for id in $DISKS; do
	d=$(readlink -f "/dev/disk/by-id/$id") || die "$id is missing"
	[[ -b $d ]] || die "$id is missing"
	devs+=("$d")
	echo "$id -> $d ($(lsblk -dno SIZE,MODEL "$d"))"
done

if [[ ! -e $MD ]]; then
	for d in "${devs[@]}"; do
		lsblk -nro MOUNTPOINTS "$d" | grep -q . && die "$d (or a partition) is mounted"
		[[ -z $(ls "/sys/class/block/${d##*/}/holders") ]] || die "$d is in use (holders)"
		for p in /sys/class/block/"${d##*/}"/"${d##*/}"*; do
			[[ -e $p ]] || continue
			[[ -z $(ls "$p/holders") ]] || die "/dev/${p##*/} is in use (holders)"
		done
	done
	note "signatures that will be destroyed"
	for d in "${devs[@]}"; do wipefs -n "$d" "$d"?* 2>/dev/null || true; done
	read -rp $'\nType WIPE to erase these six disks and build the RAID10: ' answer
	[[ $answer == WIPE ]] || die "cancelled"

	note "wiping"
	for d in "${devs[@]}"; do
		# ZFS keeps two labels at each end of its partition and wipefs may
		# not find them all: zero both ends of every partition and the disk.
		for p in "$d"?* "$d"; do
			[[ -b $p ]] || continue
			sectors=$(blockdev --getsz "$p")
			dd if=/dev/zero of="$p" bs=1M count=8 conv=fsync status=none
			dd if=/dev/zero of="$p" bs=512 seek=$((sectors - 16384)) count=16384 conv=fsync status=none
			wipefs -aq "$p"
		done
		sgdisk --zap-all "$d" >/dev/null
		partprobe "$d" 2>/dev/null || true
	done
	udevadm settle

	note "creating $MD (RAID10, near-2: three mirrored pairs)"
	# near-2 mirrors adjacent members: the ids above pair up 1+2, 3+4, 5+6.
	mdadm --create "$MD" --run --level=10 --layout=n2 --raid-devices=6 --chunk=512 \
		--bitmap=internal --name=data3 $(printf '/dev/disk/by-id/%s ' $DISKS)
	udevadm settle
fi

note "mdadm.conf + initramfs"
uuid=$(mdadm --detail --export "$MD" | sed -n 's/^MD_UUID=//p')
if ! grep -q "$uuid" /etc/mdadm/mdadm.conf; then
	mdadm --detail --brief "$MD" >> /etc/mdadm/mdadm.conf
	update-initramfs -u
fi

note "filesystem"
if [[ $(blkid -p -s TYPE -o value "$MD" 2>/dev/null) != ext4 ]]; then
	# 512 KiB chunks = 128 blocks; three data-bearing pairs
	mkfs.ext4 -q -L data3 -m 1 -E stride=128,stripe_width=384 "$MD"
fi
blkid -p "$MD"
fs_uuid=$(blkid -s UUID -o value "$MD")
mkdir -p "$MNT"
grep -q "^UUID=$fs_uuid " /etc/fstab \
	|| echo "UUID=$fs_uuid $MNT ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$MNT" || mount "$MNT"
install -d -o ghrunner -g airos -m 2775 "$MNT/airos"
df -h "$MNT"

# Copies DIR to /data3 while CI runs (the long part), so the final pass with
# the runners stopped only has to catch up.
moving=()
for name in $MOVE; do
	mountpoint -q "/data2/airos/$name" && { echo "/data2/airos/$name already on $MNT"; continue; }
	moving+=("$name")
done
if (( ${#moving[@]} )); then
	for name in "${moving[@]}"; do
		# A run that stopped after moving the old tree aside copies from there.
		[[ -d /data2/airos/$name.pre-data3 ]] && continue
		note "copying /data2/airos/$name (live)"
		rsync -aHAX --numeric-ids --delete "/data2/airos/$name/" "$MNT/airos/$name/"
	done

	note "waiting for running CI jobs to finish"
	while pgrep -f Runner.Worker >/dev/null; do
		printf '\r%s jobs running ... ' "$(pgrep -fc Runner.Worker)"
		sleep 20
	done
	echo
	note "stopping runners, dashboard and nginx"
	systemctl stop "$RUNNERS" airos-dashboard.service
	docker stop airos-artifacts >/dev/null
	trap 'echo "restarting services"; docker start airos-artifacts >/dev/null; systemctl start airos-dashboard.service $(systemctl list-unit-files --no-legend "$RUNNERS" | cut -d" " -f1)' EXIT

	for name in "${moving[@]}"; do
		src=/data2/airos/$name dst=$MNT/airos/$name
		if [[ ! -d $src.pre-data3 ]]; then
			note "$name: final copy"
			rsync -aHAX --numeric-ids --delete "$src/" "$dst/"
			mv "$src" "$src.pre-data3"
		fi
		# Root-owned and empty: if the bind mount is ever missing, jobs fail
		# instead of quietly filling /data2 again.
		install -d -o root -g root -m 755 "$src"
		[[ -z $(ls -A "$src") ]] || die "$src is not empty"
		grep -q "^$dst $src " /etc/fstab \
			|| echo "$dst $src none bind,nofail,x-systemd.requires-mounts-for=$MNT 0 0" >> /etc/fstab
		systemctl daemon-reload
		mount "$src"
		# ci/ is rewritten every minute by the status cron job
		changes=$(rsync -aHAXn --numeric-ids --delete --itemize-changes --exclude=/ci/ \
			"$src.pre-data3/" "$src/")
		if [[ -z $changes ]]; then
			rm -rf "$src.pre-data3"
			echo "$name: moved, old copy removed"
		else
			echo "$name: copy differs from $src.pre-data3, which is kept:"
			head -20 <<<"$changes"
		fi
	done
fi

note "done"
cat /proc/mdstat
df -h /data1 /data2 "$MNT"
echo "The RAID10 resyncs in the background for a few hours (cat /proc/mdstat);"
echo "/data3 is usable meanwhile."
