#!/usr/bin/env bash
# build-release-sdk.sh ARCH RELEASE
#
# A cross SDK for a stock Haiku release (not air/OS), for programs that must
# run on a plain Haiku installation, such as Summit's Haiku build:
#
#   $AIROS_SDK/ARCH-RELEASE/env.sh    as sdk/build-sdk.sh writes it (source it,
#                                     or set AIROS_SDK_NAME=ARCH-RELEASE)
#   $AIROS_SDK/ARCH-RELEASE/sysroot   boot/system of a fresh installation of
#                                     the release: every package of its image,
#                                     its haiku_devel, the private headers of
#                                     its commit, and the HaikuPorts devel
#                                     packages below, whose link names lead
#                                     to the image's own libraries
#   $AIROS_SDK/ARCH-RELEASE/packages  the packages the sysroot was made from
#                                     (haikuports.py reads their provides)
#
# Nothing comes from the air/OS fork except what does not end up in a
# binary: the cross compiler (the same GCC as the release's gcc_syslibs) and
# the host tools (package, rc, xres, mimeset, bfs_shell) of the ARCH SDK.
# The compiler, rc and xres are copied into the SDK (cross-tools/,
# host-tools/), so building against it does not wait for air/OS image
# builds, which hold the ARCH SDK's lock; packaging still uses the ARCH SDK's
# tools and attribute store under its lock.
#
# Whatever is in sysroot/boot/system/lib is on every installation of the
# release, so a program links the release's libraries rather than carrying
# its own copies (two copies of a library in one process clash: a system
# add-on loaded there gets the program's older one). Only the devel parts of
# HaikuPorts packages are added for those, whose headers may be a little
# newer than the image's libraries: linking against the image's libraries
# catches a symbol the release lacks. Scintilla and Lexilla, which the image
# lacks, are added whole; packages that link them have to require them.
#
# The image's packages come from the release's ISO, checked against its
# published SHA-256, haiku_devel from the release's build in the Haiku
# repository, checked against that repository's checksum.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-release-sdk.sh x86_64 r1beta6}
RELEASE=${2:?usage: build-release-sdk.sh x86_64 r1beta6}
NAME=$ARCH-$RELEASE
case $ARCH-$RELEASE in
	x86_64-r1beta6)
		# The image's haiku package is r1~beta6_hrev59866_79 (874f0cea9d).
		VERSION=r1~beta6_hrev59866_79
		COMMIT=874f0cea9d07c6091817acf8e2cef61f2b2c453f
		ISO=haiku-r1beta6-x86_64-anyboot.iso
		ISO_SHA256=bb7743474fd175aea511be1799764ba054465285bbdf54c4722ca61d1fb4f5c9
		ISO_URLS=(https://mirrors.rit.edu/haiku/r1beta6/$ISO
			https://ftp.osuosl.org/pub/haiku/r1beta6/$ISO
			https://mirror.aarnet.edu.au/pub/haiku/r1beta6/$ISO)
		;;
	*) die "no release $RELEASE for $ARCH" ;;
esac
HAIKU_REPO_URL=https://eu.hpkg.haiku-os.org/haiku/$RELEASE/$ARCH/$VERSION
UPSTREAM=${HAIKU_UPSTREAM:-https://github.com/haiku/haiku.git}
# Devel packages for libraries the image has (the ones Summit's engine and
# browser use), and two libraries it lacks.
HAIKUPORTS=(gcc_syslibs_devel zlib_devel curl_devel openssl3_devel nghttp2_devel libpsl_devel
	sqlite_devel libxml2_devel libxslt_devel libjpeg_turbo_devel libpng16_devel libwebp_devel
	lcms_devel brotli_devel woff2_devel freetype_devel expat_devel fontconfig_devel harfbuzz_devel
	libavif1.0_devel libexecinfo_devel scintilla scintilla_devel lexilla lexilla_devel)

if [[ ${AIROS_LOCKED:-} != haiku-$NAME ]]; then
	exec env AIROS_LOCKED=haiku-$NAME flock "$AIROS_LOCKS/haiku-$NAME.lock" "$0" "$@"
fi
# The compiler and host tools of the air/OS SDK, read under its lock.
exec {base_lock}>"$AIROS_LOCKS/haiku-$ARCH.lock"
flock -s "$base_lock"
[[ -f $AIROS_SDK/$ARCH/env.sh ]] || die "no $ARCH SDK for the compiler and host tools; run sdk/build-sdk.sh $ARCH"
. "$AIROS_SDK/$ARCH/env.sh"
BASE_CROSS=$CROSS BASE_TOOLS=$TOOLS
[[ -x $TOOLS/bfs_shell/bfs_shell ]] || die "no bfs_shell in $TOOLS (jam '<build>bfs_shell' in $HAIKU_BUILD)"

CACHE=$AIROS_CACHE/haiku-release/$NAME
SDK=$AIROS_SDK/$NAME
mkdir -p "$CACHE"
package=$TOOLS/package/package

note "$ISO"
if [[ ! -f $CACHE/$ISO ]] || ! echo "$ISO_SHA256  $CACHE/$ISO" | sha256sum -c --status; then
	for url in "${ISO_URLS[@]}"; do
		curl -fsSL --retry 3 -o "$CACHE/$ISO.part" "$url" && mv "$CACHE/$ISO.part" "$CACHE/$ISO" && break
		echo "warning: $url failed" >&2
	done
	echo "$ISO_SHA256  $CACHE/$ISO" | sha256sum -c --status || die "$ISO does not match its SHA-256"
fi
images=$CACHE/image-packages
if [[ ! -f $images/.done ]]; then
	# The BFS partition of the anyboot image (the first MBR entry).
	read -r start size < <(python3 - "$CACHE/$ISO" <<'EOF'
import struct, sys
mbr = open(sys.argv[1], "rb").read(512)
for i in range(4):
    entry = mbr[446 + 16 * i: 462 + 16 * i]
    if entry[4] == 0xeb:  # BeOS/Haiku BFS
        lba, count = struct.unpack("<II", entry[8:16])
        print(lba * 512, count * 512)
        break
else:
    sys.exit("no BFS partition in the image")
EOF
)
	rm -rf "$images" "$CACHE/copy"
	mkdir -p "$CACHE/copy"
	printf 'cp -r /myfs/system/packages :%s/copy/\nquit\n' "$CACHE" \
		| "$TOOLS/bfs_shell/bfs_shell" --start-offset "$start" --end-offset "$((start + size))" "$CACHE/$ISO" > "$CACHE/copy.log"
	mv "$CACHE/copy/packages" "$images"
	rm -rf "$CACHE/copy"
	ls "$images"/haiku-"$VERSION"-*.hpkg > /dev/null || die "the image has no haiku $VERSION package"
	touch "$images/.done"
fi

note "haiku_devel $VERSION"
curl -fsSL --retry 3 -o "$CACHE/repo" "$HAIKU_REPO_URL/repo"
"$TOOLS/package_repo/package_repo" list -v "$CACHE/repo" > "$CACHE/repo.txt"
checksum() { # checksum NAME: the repository's SHA-256 of package NAME
	awk -v n="$1" '$1 == "name:" { cur = $2 } $1 == "checksum:" && cur == n { print $2 }' "$CACHE/repo.txt"
}
devel=haiku_devel-$VERSION-1-$ARCH.hpkg
if [[ ! -f $CACHE/$devel ]] || [[ $(sha256sum < "$CACHE/$devel" | cut -d' ' -f1) != "$(checksum haiku_devel)" ]]; then
	curl -fsSL --retry 3 -o "$CACHE/$devel" "$HAIKU_REPO_URL/packages/$devel"
fi
[[ $(sha256sum < "$CACHE/$devel" | cut -d' ' -f1) == "$(checksum haiku_devel)" ]] || die "$devel does not match the repository"
[[ $(sha256sum < "$images/haiku-$VERSION-1-$ARCH.hpkg" | cut -d' ' -f1) == "$(checksum haiku)" ]] \
	|| die "the image's haiku package is not the repository's $VERSION"

note "private headers ($COMMIT)"
src=$CACHE/haiku-headers
if [[ $(git -C "$src" rev-parse HEAD 2>/dev/null) != "$COMMIT" ]]; then
	rm -rf "$src"
	git init -q "$src"
	git -C "$src" remote add origin "$UPSTREAM"
	git -C "$src" sparse-checkout set --no-cone /headers/private/
	git -C "$src" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
	git -C "$src" checkout -q FETCH_HEAD
fi

note "sysroot $NAME"
new=$SDK.new
rm -rf "$new"
root=$new/sysroot/boot/system
mkdir -p "$root" "$new/packages"
# Everything a fresh installation has, but documentation, fonts and firmware.
for file in "$images"/*.hpkg; do
	case $(basename "$file") in
		haiku_userguide*|haiku_welcome*|be_book*|*_firmwares*|*_firmware-*|noto*|timgmsoundfont*|*sounds*) continue ;;
	esac
	cp "$file" "$new/packages/"
done
cp "$CACHE/$devel" "$new/packages/"
for file in "$new"/packages/*.hpkg; do
	"$package" extract -C "$root" "$file" > /dev/null
done
rm -f "$root/.PackageInfo"
mkdir -p "$root/develop/headers"
cp -a "$src/headers/private" "$root/develop/headers/"
printf '*libgcc:\n-lgcc_s -lgcc\n\n' > "$new/shared-unwinder.specs"
# The compiler, and the host rc and xres with their libraries.
rsync -rl "${BASE_CROSS%/bin/*}/" "$new/cross-tools/"
mkdir -p "$new/host-tools/bin" "$new/host-tools/lib"
cp -L "$TOOLS/rc/rc" "$TOOLS/xres" "$new/host-tools/bin/"
for lib in $(ldd "$TOOLS/rc/rc" "$TOOLS/xres" | awk '$3 ~ /objects\/linux\/lib/ {print $3}' | sort -u); do
	cp -L "$lib" "$new/host-tools/lib/"
done
for tool in "$new"/host-tools/bin/*; do
	patchelf --set-rpath '$ORIGIN/../lib' "$tool"
done
cat > "$new/env.sh" <<EOF
# Haiku $RELEASE $ARCH cross SDK (stock Haiku, not air/OS): the image of
# $VERSION ($COMMIT), made by airos-ci sdk/build-release-sdk.sh.
# Compiler (CROSS) and host rc and xres (HOST_TOOLS) are copies of the air/OS
# $ARCH SDK's; TOOLS, ATTRS and MIMEDB are that SDK's (use them under its lock).
AIROS_ARCH=$ARCH
AIROS_SDK_NAME=$NAME
HAIKU_RELEASE=$RELEASE
HAIKU_REVISION=$VERSION
HAIKU_SHA=$COMMIT
HAIKU_BUILD=$HAIKU_BUILD
HAIKU_PACKAGES=$SDK/packages
CROSS=$SDK/cross-tools/bin/$TRIPLET-
HOST_TOOLS=$SDK/host-tools
TRIPLET=$TRIPLET
SYSROOT=$SDK/sysroot
TOOLS=$BASE_TOOLS
ATTRS=$ATTRS
MIMEDB=$MIMEDB
UNWIND_SPECS=$SDK/shared-unwinder.specs
EOF
echo "$VERSION" > "$new/revision"
rm -rf "$SDK.old"
[[ -e $SDK ]] && mv "$SDK" "$SDK.old"
mv "$new" "$SDK"
rm -rf "$SDK.old"

note "HaikuPorts devel packages"
AIROS_SDK_NAME=$NAME "$AIROS_CI/deps/haikuports.py" fetch --no-deps "$ARCH" "${HAIKUPORTS[@]}" > "$CACHE/haikuports.txt"
while read -r file; do
	cp "$file" "$SDK/packages/"
	"$package" extract -C "$SDK/sysroot/boot/system" "$file" > /dev/null
done < "$CACHE/haikuports.txt"
rm -f "$SDK/sysroot/boot/system/.PackageInfo"
# Links that name /boot/system point into the sysroot; the link names of a
# devel package of a newer HaikuPorts build lead to the image's libraries.
python3 "$AIROS_CI/lib/fix-devel-links.py" "$SDK/sysroot/boot/system"
# The server's trees belong to the group (CI and people replace each
# other's), but packages carry 0755 directories and 0700 ones, and the
# package tool gives what it extracts the user's own group.
chgrp -R -h "$(stat -c %G "$AIROS_SDK")" "$SDK"
chmod -R g+rwX "$SDK"
echo "SDK ready: $SDK ($VERSION; $(ls "$SDK/packages" | wc -l) packages)"
