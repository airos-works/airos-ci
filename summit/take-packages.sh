#!/usr/bin/env bash
# summit/take-packages.sh ARCH (AIROS_TARGET=r1beta6: the packages for stock
# Haiku R1/beta6)
#
# On the main build server, after a Summit build on the Summit build server
# (airos-summit, which builds nothing else; server/setup-summit-server.sh):
# take what the image and application builds here read of it. That server
# serves its trees read-only to this one (rsync daemon, modules data1, data2
# and data4 for /data1/airos, /data2/airos and /data4/airos;
# AIROS_SUMMIT_HOST, default airos-summit.local):
#
#   1. the summit, summit_webkit and summit_webkitlegacy packages of its pool
#      into the air/OS package pool here ($AIROS_PACKAGES/ARCH), from which
#      the images take them (a release's into $AIROS_DATA/packages-RELEASE/ARCH)
#   2. air/OS only: the image's libraries the x86_64 engine links
#      ($AIROS_ROOT/summit/ARCH/system) and the engine into DEPS, for the
#      applications that link it (summit/engine-for-apps.sh)
#   3. the symbol store ($AIROS_SYMBOLS, served at /symbols/): a mirror of
#      that server's, the only one that files symbols
#
# A package the pool already has (same name and content) is left alone, so
# the script can run again at any time.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: take-packages.sh x86_64|arm64}
SDK_NAME=$(sdk_name "$ARCH")
HOST=${AIROS_SUMMIT_HOST:-airos-summit.local}
if [[ $SDK_NAME == "$ARCH" ]]; then
	remote=packages/$ARCH
	pool=$AIROS_PACKAGES/$ARCH
else
	remote=packages-$AIROS_TARGET/$ARCH
	pool=$AIROS_DATA/packages-$AIROS_TARGET/$ARCH
fi
fetch=(rsync -rlt --timeout=120)

note "Summit's $SDK_NAME packages from $HOST"
# Kept between runs: an unchanged package is not fetched again.
stage=$AIROS_WORK/summit-take/$SDK_NAME
mkdir -p "$stage" "$pool"
"${fetch[@]}" --delete --include="summit-[0-9]*-$ARCH.hpkg" --include="summit_webkit-[0-9]*-$ARCH.hpkg" \
	--include="summit_webkitlegacy-[0-9]*-$ARCH.hpkg" --exclude='*' "rsync://$HOST/data2/$remote/" "$stage/"
shopt -s nullglob
packages=("$stage"/*-"$ARCH".hpkg)
[[ ${#packages[@]} -gt 0 ]] || die "$HOST has no Summit packages in $remote"
engine=
for package in "${packages[@]}"; do
	name=$(basename "$package")
	base=${name%%-[0-9]*}
	[[ $base != summit_webkit ]] || engine=$pool/$name
	if cmp -s "$package" "$pool/$name"; then
		echo "pool: $pool/$name (unchanged)"
		continue
	fi
	# The pool keeps one version of each package: the newest build.
	with_lock "packages-$SDK_NAME" bash -c '
		rm -f "$1/$2"-[0-9]*-"$3".hpkg
		cp "$4" "$1/"' _ "$pool" "$base" "$ARCH" "$package"
	echo "pool: $pool/$name"
done

if [[ $SDK_NAME == "$ARCH" ]]; then
	[[ -n $engine ]] || die "$HOST has no summit_webkit package in $remote"
	# The staged image libraries are the Summit pipeline's (summit-ARCH lock).
	with_lock "summit-$ARCH" "${fetch[@]}" -c --delete --chmod=g+rwX --ignore-missing-args \
		"rsync://$HOST/data1/summit/$ARCH/system/" "$AIROS_ROOT/summit/$ARCH/system/"
	"$AIROS_CI/summit/engine-for-apps.sh" "$ARCH" "$engine"
fi

if [[ -n $AIROS_SYMBOLS ]]; then
	note "symbols"
	mkdir -p "$AIROS_SYMBOLS"
	with_lock symbols "${fetch[@]}" --delete --exclude=/.incoming --chmod=Dg+rwxs,Fg+rw \
		--ignore-missing-args "rsync://$HOST/data4/symbols/" "$AIROS_SYMBOLS/"
	echo "$(find "$AIROS_SYMBOLS/builds" -name '*.json' 2>/dev/null | wc -l) build lists in $AIROS_SYMBOLS"
fi
