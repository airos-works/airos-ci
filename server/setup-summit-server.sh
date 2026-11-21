#!/bin/bash
# setup-summit-server.sh: set up airos-summit, the build server that builds
# nothing but Summit (the WebKit engine takes most of a build server's time
# and memory; the main build server, airos-build, keeps the SDKs, the images
# and every other application). Run it on airos-summit after the Ubuntu 26.04
# Server install (server/summit-autoinstall/), as an account that may sudo:
#
#   sudo server/setup-summit-server.sh
#
# The machine: a Cisco UCS C240 M4SX, two Xeon E5-2680 v4 (56 threads), 88 GB,
# a pass-through SAS HBA with
#   3 x 600 GB    one RAID1, / (the installer makes it; an EFI system
#                 partition on each disk)
#   8 x 1.2 TB    one RAID10, /data (4.4 TB): this script
#
# The air/OS trees are at the main build server's paths, because the SDKs'
# env.sh files and the Haiku host tools name them: /data1, /data2 and /data4
# are bind mounts of /data/data1, /data/data2 and /data/data4.
#
# What it sets up (every step checks what is done already, so it can be run
# again; it wipes the eight disks only after you type WIPE, or with WIPE=1):
#   - /data and the bind mounts
#   - the airos group and the ghrunner user, with the IDs they have on
#     airos-build, and the trees lib/env.sh names
#   - the packages of server/provision.sh, and a swap file
#   - an rsync daemon that lets the main build server (MAIN_IP) read the
#     trees: summit/take-packages.sh there takes the packages and symbols
#   - an SSH key for ghrunner, which summit/sync-sdk.sh reads the SDKs of the
#     main build server with; its public half goes into authorized_keys there
#     with server/summit-sdk-serve.sh as its command (printed at the end)
# Then register the runner (runner/register-runner.sh, RUNNER_LABEL=airos-summit).
set -euo pipefail
[[ $EUID == 0 ]] || exec sudo WIPE="${WIPE:-}" MAIN_IP="${MAIN_IP:-}" "$0" "$@"
HERE=$(cd "$(dirname "$0")" && pwd)

USER_NAME=${USER_NAME:-jmgasper}
MAIN_IP=${MAIN_IP:-192.168.1.200}       # airos-build
SWAP_GB=${SWAP_GB:-32}
MD=/dev/md/data
MNT=/data

note() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

note "network"
# The 10 GbE card (enic) is the server's network port, by DHCP. The cabled
# 1 GbE port (igb) is CIMC's (shared LOM) and gets no address here: a second
# address on the same network made avahi see its own name as a conflict
# (airos-summit-2.local), and the name resolved to the slow port.
netplan=/etc/netplan/50-airos-summit.yaml
if [[ ! -f $netplan ]]; then
	cat > "$netplan" <<'NETPLAN'
# air/OS Summit build server (airos-ci server/setup-summit-server.sh)
network:
  version: 2
  ethernets:
    lan:
      match:
        driver: enic
      dhcp4: true
      optional: true
    # Named here so that nothing else configures them (the initramfs leaves a
    # DHCP default for every port no file matches).
    cimc:
      match:
        driver: igb
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      optional: true
NETPLAN
	chmod 600 "$netplan"
	# the installer's: DHCP on every port
	rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config.yaml
	netplan apply
	! systemctl -q is-active avahi-daemon || systemctl restart avahi-daemon
fi
ip -br addr | grep -v '^lo'

note "disks"
# The eight 1.2 TB disks, by WWN (sdX names change between boots): every
# whole SAS disk of that size.
mapfile -t ids < <(lsblk -dbno NAME,SIZE,TYPE,TRAN,WWN | awk '$3 == "disk" && $4 == "sas" && $2 > 1.1e12 && $2 < 1.3e12 {print "wwn-" $5}' | sort)
[[ ${#ids[@]} == 8 ]] || die "expected eight 1.2 TB SAS disks, found ${#ids[@]}: ${ids[*]}"
devs=()
for id in "${ids[@]}"; do
	d=$(readlink -f "/dev/disk/by-id/$id")
	[[ -b $d ]] || die "$id is missing"
	devs+=("$d")
	echo "$id -> $d ($(lsblk -dno SIZE,MODEL,SERIAL "$d"))"
done

if [[ ! -e $MD ]]; then
	for d in "${devs[@]}"; do
		lsblk -nro MOUNTPOINTS "$d" | grep -q . && die "$d (or a partition) is mounted"
	done
	note "signatures that will be destroyed"
	lsblk -o NAME,SIZE,FSTYPE,LABEL "${devs[@]}"
	if [[ ${WIPE:-} != 1 ]]; then
		read -rp $'\nType WIPE to erase these eight disks and build the RAID10: ' answer
		[[ $answer == WIPE ]] || die "cancelled"
	fi

	note "wiping"
	# What is left of an earlier use (LVM, arrays, ZFS) lets go of the disks.
	for d in "${devs[@]}"; do
		for holder in /sys/class/block/"${d##*/}"*/holders/*; do
			[[ -e $holder ]] || continue
			name=${holder##*/}
			case $name in
				md*) mdadm --stop "/dev/$name" || true ;;
				dm-*) dmsetup remove -f "$(cat "$holder/dm/name")" || true ;;
			esac
		done
	done
	for d in "${devs[@]}"; do
		[[ -z $(find /sys/class/block/"${d##*/}"*/holders/ -mindepth 1 2>/dev/null) ]] \
			|| die "$d is still in use (holders)"
		# ZFS keeps two labels at each end of its partition and wipefs may
		# not find them all: zero both ends of every partition and the disk.
		for p in "$d"?* "$d"; do
			[[ -b $p ]] || continue
			sectors=$(blockdev --getsz "$p")
			dd if=/dev/zero of="$p" bs=1M count=8 conv=fsync status=none
			(( sectors <= 16384 )) \
				|| dd if=/dev/zero of="$p" bs=512 seek=$((sectors - 16384)) count=16384 conv=fsync status=none
			wipefs -aq "$p"
		done
		sgdisk --zap-all "$d" >/dev/null
		partprobe "$d" 2>/dev/null || true
	done
	udevadm settle

	note "creating $MD (RAID10, near-2: four mirrored pairs)"
	mdadm --create "$MD" --run --level=10 --layout=n2 --raid-devices=8 --chunk=512 \
		--bitmap=internal --name=data $(printf '/dev/disk/by-id/%s ' "${ids[@]}")
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
	# 512 KiB chunks = 128 blocks; four data-bearing pairs
	mkfs.ext4 -q -L data -m 1 -E stride=128,stripe_width=512 "$MD"
fi
blkid -p "$MD"
fs_uuid=$(blkid -s UUID -o value "$MD")
mkdir -p "$MNT"
grep -q "^UUID=$fs_uuid " /etc/fstab \
	|| echo "UUID=$fs_uuid $MNT ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$MNT" || mount "$MNT"
for n in 1 2 4; do
	mkdir -p "$MNT/data$n" "/data$n"
	grep -q "^$MNT/data$n /data$n " /etc/fstab \
		|| echo "$MNT/data$n /data$n none bind,nofail,x-systemd.requires-mounts-for=$MNT 0 0" >> /etc/fstab
done
systemctl daemon-reload
for n in 1 2 4; do mountpoint -q "/data$n" || mount "/data$n"; done
df -h "$MNT"

note "users"
# The IDs they have on airos-build.
getent group airos >/dev/null || groupadd -g 1001 airos
getent group ghrunner >/dev/null || groupadd -g 1002 ghrunner
getent passwd ghrunner >/dev/null || useradd -u 1001 -g ghrunner -G airos -d /data1/runner -M \
	-s /bin/bash -c "GitHub Actions runner (air/OS CI)" ghrunner
usermod -aG airos "$USER_NAME"
install -d -o ghrunner -g ghrunner -m 755 /data1/runner
id ghrunner

note "trees"
for dir in /data1/airos /data1/airos/{src,build,sdk,summit,gl,deps,toolchain,toolchain/bin} \
		/data2/airos /data2/airos/{packages,cache,locks,work,tmp,runner-work,artifacts} \
		/data4/airos /data4/airos/symbols; do
	install -d -o ghrunner -g airos -m 2775 "$dir"
done

note "packages"
USER_NAME=$USER_NAME "$HERE/provision.sh"
apt-get -y -q install mdadm libnss-mdns expect sshpass

note "swap"
if ! swapon --show=NAME --noheadings | grep -qx /swap.img; then
	[[ -f /swap.img ]] || { fallocate -l "${SWAP_GB}G" /swap.img; chmod 600 /swap.img; mkswap -q /swap.img; }
	grep -q '^/swap.img' /etc/fstab || printf '/swap.img\tnone\tswap\tsw\t0\t0\n' >> /etc/fstab
	swapon /swap.img
fi
swapon --show

note "rsync daemon (read-only, for $MAIN_IP)"
cat > /etc/rsyncd.conf <<EOF
# air/OS: the main build server reads the Summit build server's trees
# (airos-ci summit/take-packages.sh). Made by server/setup-summit-server.sh.
uid = ghrunner
gid = airos
use chroot = yes
read only = yes
list = no
hosts allow = $MAIN_IP 127.0.0.1
max connections = 8

[data1]
	path = /data1/airos
[data2]
	path = /data2/airos
[data4]
	path = /data4/airos
EOF
systemctl enable -q rsync
systemctl restart rsync
systemctl is-active rsync

note "ghrunner's SSH key (reads the SDKs of the main build server)"
key=/data1/runner/.ssh/id_ed25519
install -d -o ghrunner -g ghrunner -m 700 /data1/runner/.ssh
[[ -f $key ]] || sudo -u ghrunner ssh-keygen -q -t ed25519 -N '' -C "ghrunner@$(hostname)" -f "$key"

note "done"
cat /proc/mdstat
df -h / "$MNT"
echo
echo "The RAID10 resyncs in the background for some hours (cat /proc/mdstat); /data is usable meanwhile."
echo "On the main build server, add to ~/.ssh/authorized_keys of an account in the airos group:"
echo "command=\"/home/$USER_NAME/.local/bin/summit-sdk-serve\",restrict $(cat "$key.pub")"
