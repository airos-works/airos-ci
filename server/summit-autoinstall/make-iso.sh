#!/usr/bin/env bash
# make-iso.sh UBUNTU_ISO OUTPUT_DIR
#
# The unattended Ubuntu Server install of airos-summit, the Summit build
# server: remakes Ubuntu's live server ISO (ubuntu-26.04.1-live-server-amd64.iso)
# as OUTPUT_DIR/airos-summit.iso with
#   - the autoinstall configuration (user-data.in) as a NoCloud seed in
#     /nocloud, and make-storage.py, which writes its storage section on the
#     machine (/ on a RAID1 of the three 600 GB disks)
#   - a boot menu that starts the installer by itself, with the serial
#     console (GRUB's too), and takes everything but GRUB over the server's
#     own network port: GRUB fetches the kernel and the initrd from SERVE
#     (OUTPUT_DIR/vmlinuz and initrd, extracted here), and the installer the
#     ISO (url=). CIMC's virtual DVD reads at about 1 MB/s over a link that
#     loses packets under load: loading the kernel from it stalled, and
#     under the installer it gave read errors.
#
# PASSWORD_HASH: the account's password (openssl passwd -6); KEYS: a file of
# SSH public keys for it (default ~/.ssh/authorized_keys and ~/.ssh/*.pub);
# SERVE: where OUTPUT_DIR is served from (serve.py), as the installer and
# CIMC reach it (default http://THIS_HOST'S_ADDRESS:8099).
#
# Then, with OUTPUT_DIR served (./serve.py OUTPUT_DIR), in the CIMC command
# line (ssh admin@CIMC):
#   scope bios; set boot-mode Uefi; commit            (UEFI, as airos-build)
#   scope vmedia; map-www airos SERVE/ airos-summit.iso
#   scope bios; create-boot-device airos-dvd VMEDIA; scope boot-device airos-dvd
#     set subtype CIMCDVD; set state Enabled; set order 1; commit
#   scope sol; set enabled yes; commit                (ssh -p 2400 admin@CIMC: the console)
#   scope chassis; power cycle
# When the installer's last command reports (serve.py prints PHONE-HOME), the
# machine reboots: unmap the ISO at once (scope vmedia; unmap airos), or it
# installs again. For the disks to boot before the EFI shell:
#   scope bios; create-boot-device disk LOCALHDD; scope boot-device disk
#     set slot HBA; set state Enabled; set order 2; commit
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ISO=${1:?usage: make-iso.sh UBUNTU_ISO OUTPUT_DIR}
OUT=${2:?usage: make-iso.sh UBUNTU_ISO OUTPUT_DIR}
HASH=${PASSWORD_HASH:?PASSWORD_HASH: openssl passwd -6}
SERVE=${SERVE:-http://$(hostname -I | awk '{print $1}'):8099}
KEYS=${KEYS:-}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/nocloud" "$work/airos" "$OUT"
if [[ -n $KEYS ]]; then cat "$KEYS"; else cat ~/.ssh/authorized_keys ~/.ssh/*.pub; fi \
	| grep -E '^(ssh|ecdsa)-' | sort -u > "$work/keys"
[[ -s $work/keys ]] || { echo "error: no SSH public keys" >&2; exit 1; }
python3 - "$HERE/user-data.in" "$work/keys" "$HASH" "$SERVE" > "$work/nocloud/user-data" <<'PY'
import sys
template, keys, password, serve = sys.argv[1:5]
keys = [line.strip() for line in open(keys)]
text = open(template).read()
text = text.replace('@KEYS4@', '\n'.join('      - ' + key for key in keys))
text = text.replace('@KEYS3@', '\n'.join('      - ' + key for key in keys))
print(text.replace('@HASH@', password).replace('@SERVE@', serve), end='')
PY
echo "instance-id: airos-summit-install" > "$work/nocloud/meta-data"
cp "$HERE/make-storage.py" "$work/airos/"
# The kernel and the initrd, for GRUB to fetch over the network.
rm -f "$OUT/vmlinuz" "$OUT/initrd"
xorriso -osirrox on -indev "$ISO" -extract /casper/vmlinuz "$OUT/vmlinuz" -extract /casper/initrd "$OUT/initrd" 2>/dev/null
chmod 644 "$OUT/vmlinuz" "$OUT/initrd"
server=${SERVE#http://}
options="ip=dhcp url=$SERVE/airos-summit.iso autoinstall \"ds=nocloud;s=/cdrom/nocloud/\" console=ttyS0,115200n8 console=tty0 ---"
cat > "$work/grub.cfg" <<GRUB
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial
set timeout=5
set default=0

menuentry "Install airos-summit (kernel over the network)" {
    set gfxpayload=keep
    echo "network..."
    net_bootp
    net_ls_addr
    echo "kernel..."
    linux (http,$server)/vmlinuz $options
    echo "initrd..."
    initrd (http,$server)/initrd
    echo "boot"
}
menuentry "Install airos-summit (kernel from this disc)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz $options
    initrd /casper/initrd
}
menuentry 'UEFI Firmware Settings' {
    fwsetup
}
GRUB
rm -f "$OUT/airos-summit.iso"
xorriso -indev "$ISO" -outdev "$OUT/airos-summit.iso" -boot_image any replay \
	-map "$work/nocloud" /nocloud -map "$work/airos" /airos -map "$work/grub.cfg" /boot/grub/grub.cfg 2>&1 | tail -1
# It holds the password hash.
chmod 600 "$OUT/airos-summit.iso"
ls -l "$OUT/airos-summit.iso"
