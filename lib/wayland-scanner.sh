# Source after lib/env.sh. host_wayland_scanner WORKDIR: Mesa's Wayland code is
# generated on the build machine, by a wayland-scanner of the same version as
# the Haiku libwayland-client (meson checks): built from the source of
# HaikuPorts' wayland 1.21.0~git (X547/wayland), once, into $AIROS_CACHE/host.
# Sets HOSTPC to the directory of its wayland-scanner.pc, for a meson native
# file's pkg_config_path. Callers hold the haiku-x86_64 lock.
WAYLAND_REV=149e9d7e1bab3b66a93f92c19c8056db547dd066
WAYLAND_SHA256=c7cbbcdcedb2e89086351f6d03a79a561ad486c1471d598a3959643fe7f94348

host_wayland_scanner() {
	local work=$1/wayland
	local scanner=$AIROS_CACHE/host/wayland-scanner-${WAYLAND_REV:0:12}
	if [[ ! -x $scanner/bin/wayland-scanner ]]; then
		rm -rf "$work" "$scanner"
		mkdir -p "$work"
		curl -sfL --retry 3 -o "$work/wayland.tar.gz" \
			"https://github.com/X547/wayland/archive/$WAYLAND_REV.tar.gz"
		echo "$WAYLAND_SHA256  $work/wayland.tar.gz" | sha256sum -c --quiet \
			|| die "the wayland source does not match its SHA-256"
		tar -xzf "$work/wayland.tar.gz" -C "$work"
		meson setup "$work/build" "$work/wayland-$WAYLAND_REV" --prefix="$scanner" \
			-Dlibraries=false -Dscanner=true -Ddocumentation=false -Ddtd_validation=false \
			-Dtests=false > "$work/setup.log" 2>&1 \
			|| { tail -20 "$work/setup.log"; die "wayland-scanner configure failed"; }
		ninja -C "$work/build" install > "$work/build.log" 2>&1 \
			|| { tail -20 "$work/build.log"; die "wayland-scanner build failed"; }
	fi
	HOSTPC=$(dirname "$(find "$scanner" -name wayland-scanner.pc | head -n 1)")
	grep -H "^Version" "$HOSTPC/wayland-scanner.pc"
}
