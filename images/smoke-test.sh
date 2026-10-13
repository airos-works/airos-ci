#!/usr/bin/env bash
# smoke-test.sh TARGET [IMAGE_DIR]
#
# Boot a built image in QEMU (no hardware) and check that it reaches the
# desktop: the serial log must show input_server loading its add-ons (it
# starts with the graphical session, after app_server), no kernel debugger
# entry, and a screenshot of the screen 30 seconds later must not be blank.
#   x86_64  qemu-system-x86_64 with KVM, booted twice: legacy BIOS with the
#           ISO as a CD (bios-cd), then UEFI firmware (OVMF) with the ISO
#           written to a USB stick, booting from its MBR's EFI system
#           partition as on a PC (uefi-usb)
#   arm64   qemu-system-aarch64 (virt, UEFI firmware), the ISO as a USB disk
#   rpi4    not booted (QEMU's raspi4b cannot run Haiku's Pi loader); the SD
#           image's partition table and boot files are checked instead
# Writes smoke.log, serial.log and screen.png (the first boot) next to the
# image; further boots add serial-NAME.log and screen-NAME.png. Every boot
# must pass.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

TARGET=${1:?usage: smoke-test.sh x86_64|arm64|rpi4 [image dir]}
DIR=${2:-$AIROS_ARTIFACTS/images/$TARGET/latest}
DIR=$(readlink -f "$DIR")
TIMEOUT=${SMOKE_TIMEOUT:-240}
# The image build's record (lib/status.py): the smoke test finishes it (the
# trap below).
BUILD_ID=${BUILD_ID:-$(python3 "$AIROS_CI/lib/status.py" current "$TARGET" 2>/dev/null || true)}
if [[ -n $BUILD_ID ]]; then
	if [[ -z ${BUILD_LOGGING:-} ]]; then
		exec > >(tee -a "$AIROS_DATA/builds/$BUILD_ID/log.txt") 2>&1
	fi
	build_stage "smoke test" "$TARGET in QEMU"
	python3 "$AIROS_CI/lib/status.py" set "$BUILD_ID" "smoke_pid=$$" || true
fi
work=$(mktemp -d "$AIROS_DATA/tmp/smoke-$TARGET-XXXXXX")
trap 'status=$?; kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"
	[[ -z $BUILD_ID ]] || python3 "$AIROS_CI/lib/status.py" end "$BUILD_ID" \
		$([[ $status == 0 ]] && echo done || echo failed) \
		"smoke=$([[ $status == 0 ]] && echo pass || echo fail)"' EXIT

image=$(ls "$DIR"/*.xz | head -n 1)
xz -dc "$image" > "$work/image"

if [[ $TARGET == rpi4 ]]; then
	{
		echo "partitions:"
		/sbin/sfdisk -l "$work/image"
		echo "boot partition files:"
		offset=$(( $(/sbin/sfdisk -J "$work/image" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"])') * 512 ))
		mdir -i "$work/image@@$offset" -b ::/ | sort
	} | tee "$DIR/smoke.log"
	for required in start4.elf fixup4.dat config.txt airos-loader.img airos-boot.tgz bcm2711-rpi-4-b.dtb; do
		grep -q "/$required" "$DIR/smoke.log" || die "the boot partition has no $required"
	done
	echo "SMOKE PASS: SD image has the boot files" | tee -a "$DIR/smoke.log"
	exit 0
fi

# qemu_for BOOT: the QEMU command line of one way to boot the image, in qemu.
qemu_for() {
	case $TARGET/$1 in
		x86_64/bios-cd)
			qemu=(qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4
				-cdrom "$work/image" -boot d -vga std) ;;
		x86_64/uefi-usb)
			# PC firmware boots a USB stick from the EFI system partition in
			# its MBR. OVMF would take the ISO's El Torito EFI image instead,
			# so the stick is an overlay whose El Torito boot record (sector
			# 17) has its identifier spoilt, which OVMF then ignores.
			qemu-img create -q -f qcow2 -b "$work/image" -F raw "$work/stick.qcow2"
			if [[ $(head -c 34846 "$work/image" | tail -c 23) == "EL TORITO SPECIFICATION" ]]; then
				qemu-io -f qcow2 -c "write -P 0x58 34823 1" "$work/stick.qcow2" >/dev/null
			fi
			# The stick is the only disk, so OVMF boots it by itself.
			cp /usr/share/OVMF/OVMF_VARS_4M.fd "$work/vars.fd"
			qemu=(qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4
				-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
				-drive if=pflash,format=raw,file="$work/vars.fd"
				-device qemu-xhci -device usb-kbd -device usb-tablet
				-drive if=none,id=stick,format=qcow2,file="$work/stick.qcow2"
				-device usb-storage,drive=stick,removable=on
				-vga std) ;;
		arm64/uefi-usb)
			fw=/usr/share/AAVMF/AAVMF_CODE.fd
			[[ -f $fw ]] || fw=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
			cp /usr/share/AAVMF/AAVMF_VARS.fd "$work/vars.fd" 2>/dev/null || truncate -s 64M "$work/vars.fd"
			qemu=(qemu-system-aarch64 -M virt -cpu cortex-a72 -m 4096 -smp 4
				-drive if=pflash,format=raw,readonly=on,file="$fw"
				-drive if=pflash,format=raw,file="$work/vars.fd"
				-device qemu-xhci -device usb-kbd -device usb-tablet
				-drive if=none,id=stick,format=raw,file="$work/image" -device usb-storage,drive=stick
				-device ramfb) ;;
		*) die "no QEMU set-up for $TARGET/$1" ;;
	esac
}

# boot BOOT SUFFIX: boot the image one way and check that it reaches the
# desktop. Copies its serial log and screenshot next to the image as
# serialSUFFIX.log and screenSUFFIX.png, sets result (PASS or FAIL) and appends
# a report to $work/report.
boot() {
	local name=$1 suffix=$2
	local serial=$work/$name.serial monitor=$work/$name.sock screen=$work/$name.png
	note "boot $name"
	rm -f "$DIR/serial$suffix.log" "$DIR/screen$suffix.png" "$DIR/screen$suffix.ppm"
	: > "$serial"
	qemu_for "$name"
	"${qemu[@]}" -display none -serial "file:$serial" -monitor "unix:$monitor,server,nowait" \
		-no-reboot &
	local qemu_pid=$! i
	result=FAIL
	for ((i = 0; i < TIMEOUT; i += 5)); do
		sleep 5
		kill -0 $qemu_pid 2>/dev/null || break
		if grep -aqE "Welcome to Kernel Debugging Land|PANIC:" "$serial"; then
			break
		fi
		if grep -aq "AddOnManager::" "$serial"; then
			result=PASS
			sleep 30   # let the desktop (or the first-start dialog) draw
			break
		fi
	done
	if kill -0 $qemu_pid 2>/dev/null; then
		printf 'screendump %s\n' "$work/$name.ppm" | socat - "UNIX-CONNECT:$monitor" >/dev/null 2>&1 || true
		sleep 2
		python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).save(sys.argv[2])' \
			"$work/$name.ppm" "$screen" 2>/dev/null || cp "$work/$name.ppm" "$DIR/screen$suffix.ppm" 2>/dev/null || true
		printf 'quit\n' | socat - "UNIX-CONNECT:$monitor" >/dev/null 2>&1 || kill $qemu_pid
	fi
	wait $qemu_pid 2>/dev/null || true
	cp "$serial" "$DIR/serial$suffix.log"
	[[ ! -f $screen ]] || cp "$screen" "$DIR/screen$suffix.png"
	local details colours
	details=$(grep -aE "Welcome to Kernel Debugging Land|PANIC:|AddOnManager::" "$serial" | head -5 || true)
	if [[ $result == PASS && -f $screen ]]; then
		# A drawn desktop has hundreds of colours; a blank or hung screen a few.
		colours=$(python3 -c 'import sys; from PIL import Image; print(len(Image.open(sys.argv[1]).getcolors(1 << 20) or []))' "$screen")
		details+=$'\n'"screenshot: $colours colours"
		(( colours > 64 )) || { result=FAIL; details+=" (the screen is blank)"; }
	fi
	{
		echo "$name: $result after ${i}s"
		[[ -z $details ]] || sed 's/^/  /' <<< "$details"
	} | tee -a "$work/report"
	summary+=("$name $result after ${i}s")
}

case $TARGET in
	x86_64) boots=(bios-cd uefi-usb) ;;
	arm64) boots=(uefi-usb) ;;
	*) die "unknown target $TARGET" ;;
esac
overall=PASS
summary=()
: > "$work/report"
for n in "${!boots[@]}"; do
	# The first boot's files keep the names the dashboard shows.
	suffix=-${boots[n]}
	(( n > 0 )) || suffix=
	boot "${boots[n]}" "$suffix"
	[[ $result == PASS ]] || overall=FAIL
done
printf -v summary_text '%s, ' "${summary[@]}"
{
	echo "SMOKE $overall: $TARGET $(basename "$image") (${summary_text%, })"
	cat "$work/report"
} > "$DIR/smoke.log"
head -n 1 "$DIR/smoke.log"
[[ $overall == PASS ]]
