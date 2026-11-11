#!/bin/bash
# setup-data4.sh: build /data4, a RAID10 of the four 1.2 TB SAS disks added to
# airos-build on 2026-11-11 (they carry old ZFS labels), for symbol tables and
# debug information of the CI's builds (apps/store-symbols.py), kept apart from
# the build and data disks. lib/env.sh takes /data4/airos/symbols as
# AIROS_SYMBOLS once it exists; this script copies the store kept so far
# (/data3/airos/artifacts/symbols) there and restarts nginx with it mounted at
# /symbols/ (images/serve-artifacts.sh).
#
# Run as the owner (needs sudo): sudo server/setup-data4.sh
# Every step checks what is already done, so the script can be run again after
# an interruption. It wipes the four disks only after you type WIPE.
set -euo pipefail
[[ $EUID == 0 ]] || exec sudo "$0" "$@"

# The disks by WWN (sdX names change between boots).
DISKS="wwn-0x5000cca01d734028 wwn-0x5000c50076a28b27 wwn-0x5000c50076a262b7
 wwn-0x5000c50076a0aab3"
MD=/dev/md/data4
MNT=/data4
OLD_STORE=/data3/airos/artifacts/symbols

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
	read -rp $'\nType WIPE to erase these four disks and build the RAID10: ' answer
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

	note "creating $MD (RAID10, near-2: two mirrored pairs)"
	# near-2 mirrors adjacent members: the ids above pair up 1+2 and 3+4.
	mdadm --create "$MD" --run --level=10 --layout=n2 --raid-devices=4 --chunk=512 \
		--bitmap=internal --name=data4 $(printf '/dev/disk/by-id/%s ' $DISKS)
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
	# 512 KiB chunks = 128 blocks; two data-bearing pairs
	mkfs.ext4 -q -L data4 -m 1 -E stride=128,stripe_width=256 "$MD"
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

note "symbol store"
store=$MNT/airos/symbols
install -d -o ghrunner -g airos -m 2775 "$store"
# From here CI writes the new store (lib/env.sh); copy what it kept so far,
# twice, so a build list written meanwhile comes along (objects never change).
if [[ -d $OLD_STORE ]] && ! mountpoint -q "$OLD_STORE"; then
	for pass in 1 2; do
		sudo -u ghrunner rsync -a --update "$OLD_STORE/" "$store/"
		sleep 5
	done
	rm -rf "$OLD_STORE"
fi
# The mount point nginx's container needs inside the read-only artifacts tree.
install -d -o root -g root -m 755 "$OLD_STORE"
du -sh "$store"

note "nginx"
owner=$(stat -c %U "$(dirname "$0")/..")
sudo -u "$owner" "$(cd "$(dirname "$0")/.." && pwd)/images/serve-artifacts.sh"

note "done"
cat /proc/mdstat
df -h /data1 /data2 /data3 "$MNT"
echo "The RAID10 resyncs in the background for an hour or two (cat /proc/mdstat);"
echo "/data4 is usable meanwhile."
