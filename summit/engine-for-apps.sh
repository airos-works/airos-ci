#!/usr/bin/env bash
# summit/engine-for-apps.sh ARCH SUMMIT_WEBKIT_PACKAGE
#
# The engine, as the summit_webkit package installs it, into DEPS
# ($AIROS_ROOT/deps/ARCH/boot/system: lib/summit-webkit and
# develop/headers/summit-webkit), so the builds of the applications that link
# it (Natter for Slack web sign-in, Mail, Aurora) find it. From
# summit/build-summit.sh after a build here, and from summit/take-packages.sh
# on the main build server when the Summit build server made the package.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: engine-for-apps.sh x86_64|arm64 SUMMIT_WEBKIT_PACKAGE}
engine=${2:?usage: engine-for-apps.sh x86_64|arm64 SUMMIT_WEBKIT_PACKAGE}
[[ -f $engine ]] || die "no package $engine"

note "engine for app builds"
# DEPS is read by app builds under the shared haiku-ARCH lock.
DEPS=${DEPS:-$AIROS_ROOT/deps/$ARCH/boot/system}
. "$AIROS_SDK/$ARCH/env.sh"
# x86_64: the image's libraries the engine links (summit/lib.sh SYSLIBS) that
# DEPS lacks, for the linker of programs that link the engine; DEPS's own
# are left alone.
syslibs=$AIROS_ROOT/summit/$ARCH/system/boot/system/lib
with_lock "haiku-$ARCH" bash -c '
	set -e
	rm -rf "$1/lib/summit-webkit" "$1/develop/headers/summit-webkit"
	"$2" extract -C "$1" "$3"
	rm -f "$1/.PackageInfo"
	rm -rf "$1/documentation/packages/summit_webkit"
	if [[ -d $4 ]]; then
		for lib in "$4"/*.so*; do
			[[ -e $1/lib/${lib##*/} || -L $1/lib/${lib##*/} ]] || cp -a "$lib" "$1/lib/"
		done
	fi
' _ "$DEPS" "$TOOLS/package/package" "$engine" "$syslibs"
echo "$(basename "$engine") -> $DEPS/lib/summit-webkit"
