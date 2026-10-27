# airos-ci common environment; source it from every script:
#   . "$(dirname "$0")/../lib/env.sh"
#
# Layout on the build server (airos-build). Everything can be overridden from
# the environment, so the scripts also run elsewhere.

AIROS_CI=${AIROS_CI:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
AIROS_ROOT=${AIROS_ROOT:-/data1/airos}        # sources, build trees, SDKs
AIROS_DATA=${AIROS_DATA:-/data2/airos}        # package pool, images, caches, logs

AIROS_SRC=${AIROS_SRC:-$AIROS_ROOT/src}           # git clones (fetch-only) and worktrees
AIROS_BUILD=${AIROS_BUILD:-$AIROS_ROOT/build}     # Haiku generated/ build directories
AIROS_SDK=${AIROS_SDK:-$AIROS_ROOT/sdk}           # <arch>/{env.sh,sysroot}: cross SDKs
AIROS_TOOLCHAIN=${AIROS_TOOLCHAIN:-$AIROS_ROOT/toolchain}  # jam and other host tools
AIROS_PACKAGES=${AIROS_PACKAGES:-$AIROS_DATA/packages}     # <arch>/*.hpkg: the air/OS package pool
AIROS_ARTIFACTS=${AIROS_ARTIFACTS:-$AIROS_DATA/artifacts}  # images, published over HTTP
AIROS_CACHE=${AIROS_CACHE:-$AIROS_DATA/cache}              # downloads, ccache
AIROS_LOCKS=${AIROS_LOCKS:-$AIROS_DATA/locks}
AIROS_WORK=${AIROS_WORK:-$AIROS_DATA/work}                 # per-job scratch space

GITHUB_OWNER=${GITHUB_OWNER:-airos-works}
HAIKU_REPO=${HAIKU_REPO:-https://github.com/$GITHUB_OWNER/haiku.git}
BUILDTOOLS_REPO=${BUILDTOOLS_REPO:-https://github.com/$GITHUB_OWNER/buildtools.git}

JOBS=${JOBS:-$(nproc)}
export PATH="$AIROS_TOOLCHAIN/bin:$PATH"
export TMPDIR=${TMPDIR_OVERRIDE:-$AIROS_DATA/tmp}
mkdir -p "$TMPDIR" "$AIROS_LOCKS" 2>/dev/null || true

die() { echo "error: $*" >&2; exit 1; }
note() { printf '\n== %s\n' "$*"; }

# with_lock NAME COMMAND...: run COMMAND holding an exclusive lock, so two jobs
# never write the same build tree (runners for different repos share the host).
with_lock() {
	local name=$1
	shift
	flock "$AIROS_LOCKS/$name.lock" "$@"
}

# haiku_arch_triplet ARCH
haiku_triplet() {
	case $1 in
		x86_64) echo x86_64-unknown-haiku ;;
		arm64) echo aarch64-unknown-haiku ;;
		*) die "unknown architecture $1" ;;
	esac
}

# What a build is for, AIROS_TARGET: "airos" (the default) builds for air/OS
# against the SDK of sdk/build-sdk.sh; a Haiku release ("r1beta6") builds for
# a stock installation of that release (and later Haiku) against the SDK of
# sdk/build-release-sdk.sh. Its packages never go into the air/OS pool.
# sdk_name ARCH: the name of that SDK under $AIROS_SDK (x86_64, x86_64-r1beta6),
# which also names the target's build trees.
sdk_name() {
	case ${AIROS_TARGET:-airos} in
		airos) echo "$1" ;;
		r1beta6) [[ $1 == x86_64 ]] || die "Haiku ${AIROS_TARGET} is released for x86_64 only"
			echo "$1-$AIROS_TARGET" ;;
		*) die "unknown AIROS_TARGET ${AIROS_TARGET} (airos or a Haiku release: r1beta6)" ;;
	esac
}

# json FILE EXPR: read a value from a JSON manifest (python3 is always there).
json() {
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2],{"d":d}); print(v if not isinstance(v,(list,dict)) else json.dumps(v))' "$1" "$2"
}

# build_stage NAME [DETAIL]: the image build being recorded for the build
# dashboard (BUILD_ID, lib/status.py) has reached a stage; nothing otherwise.
build_stage() {
	[[ -n ${BUILD_ID:-} ]] || return 0
	python3 "$AIROS_CI/lib/status.py" stage "$BUILD_ID" "$@" || true
}

# zstd_build_feature ARCH BUILD SOURCE: before a jam run in the Haiku build
# directory BUILD (tree SOURCE). arm64 builds get the zstd build feature from
# CI's zstd packages (deps/recipes/zstd.sh): packagefs, the boot loader and
# the package kit read zstd packages, while the packages the build makes stay
# zlib-compressed, which arm64 systems without zstd support can read. jam
# takes both settings from the environment (the SDK build has no
# UserBuildConfig). Every jam run in BUILD must have the same setting: jam
# does not compile objects again when only their flags change, so when it
# changes, BUILD's Haiku objects go and are built anew (the host tools stay).
# Only for a tree that has both settings, once the packages exist.
zstd_build_feature() {
	local arch=$1 build=$2 source=$3 dir=$AIROS_ROOT/image-inputs/arm64/zstd state=off
	unset HAIKU_ARM64_ZSTD_PACKAGES_DIR HAIKU_PACKAGE_DEFAULT_COMPRESSION
	[[ $arch == arm64 ]] || return 0
	if grep -q HAIKU_ARM64_ZSTD_PACKAGES_DIR "$source/build/jam/BuildFeatures" \
			&& grep -q HAIKU_PACKAGE_DEFAULT_COMPRESSION "$source/src/tools/package/Jamfile" \
			&& compgen -G "$dir/zstd-[0-9]*-arm64.hpkg" > /dev/null; then
		export HAIKU_ARM64_ZSTD_PACKAGES_DIR=$dir HAIKU_PACKAGE_DEFAULT_COMPRESSION=zlib
		state=zstd
	fi
	if [[ -d $build/objects/haiku && $(cat "$build/zstd-feature" 2>/dev/null || echo off) != "$state" ]]; then
		note "zstd build feature $state: the Haiku objects in $build are built again"
		rm -rf "$build/objects/haiku"
	fi
	mkdir -p "$build"
	echo "$state" > "$build/zstd-feature"
}
