#!/usr/bin/env bash
# summit/sync-sdk.sh SDK_NAME
#
# On the Summit build server (airos-summit), which builds nothing but Summit:
# mirror what the Summit pipeline reads of the SDK SDK_NAME (x86_64, arm64,
# x86_64-r1beta6) from the main build server, where sdk/build-sdk.sh, the
# dependency builds and the image builds make it. AIROS_SDK_FROM names the
# account there whose authorized_keys runs server/summit-sdk-serve.sh for this
# server's key (USER@airos-build.local); that script holds the SDK's lock,
# shared, for each copy. Everything lands at the path it has there, which the
# SDK's env.sh and the host tools name:
#
#   $AIROS_SDK/SDK_NAME               env.sh, the sysroot, the unwinder specs
#                                     (a release: its packages and tools too)
#   $AIROS_ROOT/gl/SDK_NAME[-mesa]    the GL stack, Summit's private Mesa
#   $AIROS_TOOLCHAIN/bin              jam
#   and for an air/OS SDK, of its Haiku build directory (HAIKU_BUILD):
#     the cross compiler, the host tools (objects/linux), the packages the
#     image is made of (download), and the MIME database with its attributes
#   $AIROS_ROOT/deps/ARCH             the third-party prefix (DEPS), but for
#                                     the Summit engine in it, which this
#                                     server makes
#
# The host tools keep Haiku attributes in HAIKU_BUILD/attributes/ID, ID being
# the file's user.haiku.id (HAIKU_HOST_USE_XATTR_REF): the MIME database's
# files come with that xattr and their entries of the store, so mimeset knows
# the types here as it does there. The store's other entries are this
# server's own (its packages' staged files), pruned here once a day.
#
# Unchanged files are not copied again (size and time), so a run costs
# seconds; summit/lib.sh (summit_sdk) calls it before every snapshot.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

SDK_NAME=${1:?usage: sync-sdk.sh SDK_NAME}
FROM=${AIROS_SDK_FROM:?AIROS_SDK_FROM: the account on the main build server (USER@HOST)}
arch=${SDK_NAME%%-*}

# A release SDK's compiler and host tools are the air/OS SDK's.
[[ $SDK_NAME == "$arch" ]] || "$0" "$arch"

# pull [RSYNC OPTIONS] PATH...: directories under $AIROS_ROOT, as they are
# there (a path that does not exist there is skipped, and removed here).
pull() {
	local options=() sources=() path
	while [[ ${1:-} == -* ]]; do options+=("$1"); shift; done
	for path in "$@"; do
		sources+=("$FROM:${path#"$AIROS_ROOT"/}/")
	done
	rsync -rlptR --delete --ignore-missing-args --chmod=Dg+rwxs,Fg+rw "${options[@]}" \
		-e "ssh -o BatchMode=yes -o ConnectTimeout=20" --rsync-path="airos-sdk $SDK_NAME" \
		"${sources[@]}" "$AIROS_ROOT/"
}

start=$SECONDS
mkdir -p "$AIROS_SDK" "$AIROS_TOOLCHAIN/bin"
pull "$AIROS_SDK/$SDK_NAME" "$AIROS_ROOT/gl/$SDK_NAME" "$AIROS_ROOT/gl/$SDK_NAME-mesa" "$AIROS_TOOLCHAIN/bin"
[[ -f $AIROS_SDK/$SDK_NAME/env.sh ]] || die "$FROM has no $SDK_NAME SDK"
if [[ $SDK_NAME == "$arch" ]]; then
	. "$AIROS_SDK/$SDK_NAME/env.sh"
	[[ $HAIKU_BUILD == "$AIROS_ROOT"/* && $ATTRS == "$HAIKU_BUILD"/* ]] \
		|| die "the $SDK_NAME SDK's build directory $HAIKU_BUILD is not under $AIROS_ROOT"
	mkdir -p "$ATTRS"
	pull --exclude=/deps/*/boot/system/lib/summit-webkit --exclude=/deps/*/boot/system/develop/headers/summit-webkit \
		"${CROSS%/bin/*}" "$HAIKU_BUILD/objects/linux" "$HAIKU_BUILD/download" "$AIROS_ROOT/deps/$arch"
	# The MIME database: every node with its attribute ID, then those entries
	# of the attribute store.
	pull -X "${MIMEDB%/*}"
	python3 - "${MIMEDB%/*}" <<'EOF' > "$AIROS_WORK/mime-attributes-$arch.list"
import os, sys
ids = set()
for directory, names, files in os.walk(sys.argv[1]):
    for path in [directory] + [os.path.join(directory, name) for name in files]:
        try:
            ids.add(os.getxattr(path, 'user.haiku.id', follow_symlinks=False).decode())
        except OSError:
            pass
print('\n'.join(sorted(ids)))
EOF
	[[ -s $AIROS_WORK/mime-attributes-$arch.list ]] \
		|| die "the MIME database ${MIMEDB%/*} came without attribute IDs (user.haiku.id)"
	rsync -rlpt --delete --chmod=Dg+rwxs,Fg+rw --files-from="$AIROS_WORK/mime-attributes-$arch.list" \
		-e "ssh -o BatchMode=yes -o ConnectTimeout=20" --rsync-path="airos-sdk $SDK_NAME" \
		"$FROM:${ATTRS#"$AIROS_ROOT"/}/" "$ATTRS/"
	prune_attributes "$HAIKU_BUILD"
fi
echo "SDK $SDK_NAME from $FROM: $(cat "$AIROS_SDK/$SDK_NAME/revision" 2>/dev/null || true) ($((SECONDS - start)) s)"
