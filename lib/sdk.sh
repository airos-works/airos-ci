# Source after lib/env.sh in scripts that build against an air/OS cross SDK.
#
#   AIROS_ARCH=x86_64|arm64 (required)
#   AIROS_TARGET=airos (default) or a Haiku release (r1beta6): which SDK
#
# Sets ARCH, CROSS, TRIPLET, SYSROOT, TOOLS, ATTRS, MIMEDB, UNWIND_SPECS,
# HAIKU_REVISION (from $AIROS_SDK/SDK_NAME/env.sh), SDK_NAME (lib/env.sh
# sdk_name) and DEPS, the staged third-party prefix (deps/stage-deps.sh; for
# a release, the SDK's sysroot). Holds the haiku-SDK_NAME lock shared
# for the life of the calling script, so build-sdk.sh cannot replace the SDK
# or rebuild its host tools under it.

ARCH=${AIROS_ARCH:?set AIROS_ARCH to x86_64 or arm64}
SDK_NAME=$(sdk_name "$ARCH")
[[ -f $AIROS_SDK/$SDK_NAME/env.sh ]] || die "no $SDK_NAME SDK; run sdk/build-sdk.sh $ARCH" \
	"(for a Haiku release: sdk/build-release-sdk.sh $ARCH ${AIROS_TARGET:-})"
if [[ ${AIROS_LOCKED:-} != haiku-$SDK_NAME ]]; then
	exec {AIROS_SDK_LOCK_FD}>"$AIROS_LOCKS/haiku-$SDK_NAME.lock"
	flock -s "$AIROS_SDK_LOCK_FD"
fi
# A release SDK has the compiler and host tools of the air/OS one.
if [[ $SDK_NAME != "$ARCH" && ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec {AIROS_BASE_SDK_LOCK_FD}>"$AIROS_LOCKS/haiku-$ARCH.lock"
	flock -s "$AIROS_BASE_SDK_LOCK_FD"
fi
. "$AIROS_SDK/$SDK_NAME/env.sh"
export AIROS_SDK_NAME=$SDK_NAME
# Outside the SDK directory, which build-sdk.sh replaces wholesale. A release
# SDK has its third-party devel packages in the sysroot.
if [[ $SDK_NAME == "$ARCH" ]]; then
	DEPS=${DEPS:-$AIROS_ROOT/deps/$ARCH/boot/system}
else
	DEPS=${DEPS:-$SYSROOT/boot/system}
fi
mkdir -p "$DEPS" "$AIROS_WORK"
