#!/usr/bin/env bash
# summit/build-summit.sh ARCH [SUMMIT_DIR]
#
# The Summit pipeline for ARCH, from a Summit checkout (default
# $GITHUB_WORKSPACE):
#
#   1. summit/build-deps.sh    the engine's libraries, from the airos-works forks
#   2. summit/build-engine.sh  WebKit with Summit's Haiku port (incremental)
#   3. the summit_webkit, summit and summit_webkitlegacy packages
#      (apps/build-app-packages.sh), into the air/OS package pool, from which
#      the images take them; summit_webkitlegacy is HaikuWebKit's BWebView
#      API (WebPositive's) on the engine, in place of HaikuPorts' haikuwebkit
#      (air/OS only)
#   4. the engine, as the summit_webkit package installs it, into DEPS, so
#      Natter's builds link it for Slack web sign-in
#
# With AIROS_TARGET=r1beta6 the same, for a stock Haiku R1/beta6 installation:
# against that release's SDK (sdk/build-release-sdk.sh), in trees of its own,
# and the packages go to $AIROS_DATA/packages-r1beta6/ARCH, not to the air/OS
# pool (step 4 is left out).
#
# Writes the package paths to $OUT_LIST (default $RUNNER_TEMP/packages.txt).
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-summit.sh x86_64|arm64 [SUMMIT_DIR]}
SUMMIT_DIR=$(cd "${2:-${GITHUB_WORKSPACE:?no Summit checkout}}" && pwd)
SDK_NAME=$(sdk_name "$ARCH")
if [[ ${AIROS_SUMMIT_LOCKED:-} != summit-$SDK_NAME ]]; then
	exec env AIROS_SUMMIT_LOCKED=summit-$SDK_NAME flock "$AIROS_LOCKS/summit-$SDK_NAME.lock" "$0" "$ARCH" "$SUMMIT_DIR"
fi
JOBTMP=${RUNNER_TEMP:-$AIROS_WORK/tmp-summit}
export OUT_LIST=${OUT_LIST:-$JOBTMP/packages.txt}
mkdir -p "$JOBTMP"

# A release's SDK and private Mesa, the first time (later sdk-deps.yml
# keeps them current).
if [[ $SDK_NAME != "$ARCH" ]]; then
	[[ -f $AIROS_SDK/$SDK_NAME/env.sh ]] || "$AIROS_CI/sdk/build-release-sdk.sh" "$ARCH" "$AIROS_TARGET"
	[[ -d $AIROS_ROOT/gl/$SDK_NAME-mesa/lib ]] || "$AIROS_CI/deps/build-gl-x86_64.sh"
fi
"$AIROS_CI/summit/build-deps.sh" "$ARCH"
"$AIROS_CI/summit/build-engine.sh" "$ARCH" "$SUMMIT_DIR"

note "packages"
before=$(wc -l < "$OUT_LIST" 2>/dev/null || echo 0)
apps=summit_webkit,summit
# summit_webkitlegacy for air/OS only: on a stock Haiku installation it would
# take haikuwebkit's place under the release's own WebPositive, which stays
# the user's choice (Summit's tools/package-summit-webkitlegacy.sh).
[[ $SDK_NAME != "$ARCH" ]] || apps+=,summit_webkitlegacy
"$AIROS_CI/apps/ci-build-app.sh" "$ARCH" "$apps" summit "$SUMMIT_DIR"
engine=$(tail -n +"$((before + 1))" "$OUT_LIST" | grep '/summit_webkit-[^/]*\.hpkg$' | tail -n 1)
[[ -n $engine ]] || die "no summit_webkit package was made"
# Natter's builds are for air/OS.
[[ $SDK_NAME == "$ARCH" ]] || exit 0

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
