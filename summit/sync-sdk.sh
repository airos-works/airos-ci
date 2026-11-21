#!/usr/bin/env bash
# summit/sync-sdk.sh SDK_NAME
#
# On the Summit build server (airos-summit), which builds nothing but Summit:
# mirror what the Summit pipeline reads of the SDK SDK_NAME (x86_64, arm64,
# x86_64-r1beta6) from the main build server, where sdk/build-sdk.sh, the
# dependency builds and the image builds make it. AIROS_SDK_FROM names the
# account there whose authorized_keys runs server/summit-sdk-serve.sh for this
# server's key (USER@airos-build.local). Everything lands at the path it has
# there, which the SDK's env.sh and the host tools name:
#
#   $AIROS_SDK/SDK_NAME               env.sh, the sysroot, the unwinder specs
#                                     (a release: its packages and tools too)
#   $AIROS_ROOT/gl/SDK_NAME[-mesa]    the GL stack, Summit's private Mesa
#   $AIROS_TOOLCHAIN/bin              jam
#   and for an air/OS SDK (a release's: the SDK it takes its compiler from),
#   of its Haiku build directory (HAIKU_BUILD):
#     the cross compiler, the host tools (objects/linux), the packages the
#     image is made of (download), and the MIME database with its attributes;
#     of its source tree (HAIKU_SOURCE) the licenses, which the package tool
#     checks a package's against (the path is compiled into it)
#   $AIROS_ROOT/deps/ARCH             the third-party prefix (DEPS), but for
#                                     the Summit engine in it, which this
#                                     server makes
#
# The SDK's lock on the main build server is held, shared, for the whole
# copy, so the mirror is the SDK as one build left it. An SDK or image build
# there holds that lock for its whole run (an hour, with several images in a
# row). When the lock is not free within AIROS_SDK_WAIT seconds (default 300)
# and a complete mirror exists, Summit is built against that mirror, the SDK
# as it was before that build began, and does not wait behind the images;
# the next build takes the new SDK. AIROS_SDK_WAIT= (empty) always waits.
#
# The host tools keep Haiku attributes in HAIKU_BUILD/attributes/ID, ID being
# the file's user.haiku.id (HAIKU_HOST_USE_XATTR_REF): the MIME database's
# files come with that xattr and their entries of the store, so mimeset knows
# the types here as it does there. The store's other entries are this
# server's own (its packages' staged files), removed after a week.
#
# Unchanged files are not copied again (size and time), so a run costs
# seconds; summit/lib.sh (summit_sdk) calls it before every snapshot.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

SDK_NAME=${1:?usage: sync-sdk.sh SDK_NAME}
FROM=${AIROS_SDK_FROM:?AIROS_SDK_FROM: the account on the main build server (USER@HOST)}
arch=${SDK_NAME%%-*}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30)
# Written when a mirror is complete (outside the SDK's directory, which is
# made the same as the one there).
mirrored=$AIROS_SDK/.mirrored-$SDK_NAME
mkdir -p "$AIROS_SDK" "$AIROS_TOOLCHAIN/bin" "$AIROS_WORK"

start=$SECONDS
seconds=${AIROS_SDK_WAIT-300}
[[ -f $mirrored && -f $AIROS_SDK/$SDK_NAME/env.sh ]] || seconds=
coproc LOCK { exec "${SSH[@]}" "$FROM" airos-sdk-lock "$SDK_NAME" $seconds; }
lock_pid=$LOCK_PID
state=
read -r state <&"${LOCK[0]}" || true
case $state in
	locked) ;;
	busy)
		echo "SDK $SDK_NAME: $FROM is building it (lock busy for $seconds s);" \
			"using the mirror of $(cat "$AIROS_SDK/$SDK_NAME/revision" 2>/dev/null || echo "$(date -r "$mirrored")")"
		exit 0 ;;
	*) die "cannot take the $SDK_NAME SDK's lock on $FROM (server/summit-sdk-serve.sh there?)" ;;
esac
# Hanging up releases the lock there.
trap 'kill "$lock_pid" 2>/dev/null || true; wait "$lock_pid" 2>/dev/null || true' EXIT

# pull [RSYNC OPTIONS] PATH...: directories under $AIROS_ROOT, as they are
# there (a path that does not exist there is skipped, and removed here).
pull() {
	local options=() sources=() path
	while [[ ${1:-} == -* ]]; do options+=("$1"); shift; done
	for path in "$@"; do
		sources+=("$FROM:${path#"$AIROS_ROOT"/}/")
	done
	# data/ssl/private (the sysroot's and DEPS's: empty, and only its owner's
	# to read there) stays behind.
	rsync -rlptR --delete --ignore-missing-args --chmod=Dg+rwxs,Fg+rw \
		--exclude=/boot/system/data/ssl/private --exclude='**/boot/system/data/ssl/private' "${options[@]}" \
		-e "${SSH[*]}" --rsync-path="airos-sdk $SDK_NAME" "${sources[@]}" "$AIROS_ROOT/"
}

# air_sdk ARCH: an air/OS SDK and what its env.sh names.
air_sdk() {
	local arch=$1
	rm -f "$AIROS_SDK/.mirrored-$arch"
	pull "$AIROS_SDK/$arch" "$AIROS_ROOT/gl/$arch" "$AIROS_ROOT/gl/$arch-mesa" "$AIROS_TOOLCHAIN/bin"
	[[ -f $AIROS_SDK/$arch/env.sh ]] || die "$FROM has no $arch SDK"
	(
		. "$AIROS_SDK/$arch/env.sh"
		[[ $HAIKU_BUILD == "$AIROS_ROOT"/* && $ATTRS == "$HAIKU_BUILD"/* && $HAIKU_SOURCE == "$AIROS_ROOT"/* ]] \
			|| die "the $arch SDK's trees ($HAIKU_BUILD, $HAIKU_SOURCE) are not under $AIROS_ROOT"
		mkdir -p "$ATTRS"
		pull --exclude=/deps/*/boot/system/lib/summit-webkit \
			--exclude=/deps/*/boot/system/develop/headers/summit-webkit \
			"${CROSS%/bin/*}" "$HAIKU_BUILD/objects/linux" "$HAIKU_BUILD/download" "$AIROS_ROOT/deps/$arch" \
			"$HAIKU_SOURCE/data/system/data/licenses"
		# The MIME database: every node with its attribute ID, then those
		# entries of the attribute store.
		pull -X "${MIMEDB%/*}"
		list=$AIROS_WORK/mime-attributes-$arch.list
		python3 - "${MIMEDB%/*}" > "$list" <<'EOF'
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
		[[ -s $list ]] || die "the MIME database ${MIMEDB%/*} came without attribute IDs (user.haiku.id)"
		rsync -rlpt --delete --chmod=Dg+rwxs,Fg+rw --files-from="$list" \
			-e "${SSH[*]}" --rsync-path="airos-sdk $SDK_NAME" "$FROM:${ATTRS#"$AIROS_ROOT"/}/" "$ATTRS/"
		# The other entries are of files this server's package builds staged
		# (every build stages anew): a week later nothing reads them.
		# (images/prune-attributes.py is for a store with a Haiku build's files.)
		python3 - "$ATTRS" "$list" <<'EOF'
import os, shutil, sys, time
store, keep = sys.argv[1], set(open(sys.argv[2]).read().split())
cutoff, removed = time.time() - 7 * 86400, 0
for entry in os.scandir(store):
    try:
        if entry.name not in keep and entry.stat(follow_symlinks=False).st_mtime < cutoff:
            shutil.rmtree(entry.path) if entry.is_dir(follow_symlinks=False) else os.unlink(entry.path)
            removed += 1
    except OSError:
        pass
if removed:
    print(f"attribute store {store}: {removed} entries older than a week removed")
EOF
	)
	touch "$AIROS_SDK/.mirrored-$arch"
}

air_sdk "$arch"
if [[ $SDK_NAME != "$arch" ]]; then
	# A release SDK: its own directory and Mesa; the compiler and host tools
	# are the air/OS SDK's.
	rm -f "$mirrored"
	pull "$AIROS_SDK/$SDK_NAME" "$AIROS_ROOT/gl/$SDK_NAME" "$AIROS_ROOT/gl/$SDK_NAME-mesa"
	[[ -f $AIROS_SDK/$SDK_NAME/env.sh ]] || die "$FROM has no $SDK_NAME SDK"
	touch "$mirrored"
fi
echo "SDK $SDK_NAME from $FROM: $(cat "$AIROS_SDK/$SDK_NAME/revision" 2>/dev/null || true) ($((SECONDS - start)) s)"
