# Zstandard 1.5.7 for the arm64 Haiku build, which the arm64 bootstrap
# repository does not supply, as jmgasper/haiku's tools/rpi4/build-zstd.sh
# builds it for the lab images: zstd, zstd_devel and zstd_source from the
# release tarball, under the names build/jam/BuildFeatures expects in
# HAIKU_ARM64_ZSTD_PACKAGES_DIR. With them, every arm64 Haiku build (the SDK's
# and the images', lib/env.sh zstd_build_feature) has the zstd build feature:
# packagefs, the boot loader and the package kit read zstd packages, and the
# images carry the zstd package that haiku then requires. The packages
# themselves are zlib-compressed, so a system without zstd support can
# install them.
#
# Into $AIROS_ROOT/image-inputs/arm64/zstd, not the package pool; nothing goes
# into DEPS.
VERSION=1.5.7
NO_PACKAGE=1
SOURCE_URL=https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
SOURCE_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "zstd is built for arm64 only (x86_64 has HaikuPorts' zstd)"
	local revision=1 dir=$WORKDIR/zstd out=$AIROS_ROOT/image-inputs/arm64/zstd
	local stage=$WORKDIR/zstd/package kind name architecture file link
	# Command-line LDFLAGS override make's own, so -shared and -pthread are
	# named here. The only dependency is libroot.
	make -C lib -j"$JOBS" libzstd CC="${CROSS}gcc --sysroot=$SYSROOT" AR="${CROSS}ar" \
		UNAME_TARGET_SYSTEM=Haiku CPPFLAGS= CFLAGS='-O3 -fPIC -fvisibility=hidden' \
		LDFLAGS='-shared -pthread -Wl,--hash-style=both'
	rm -rf "$stage"
	mkdir -p "$stage/base/lib" "$stage/base/data/licenses" \
		"$stage/devel/develop/headers" "$stage/devel/develop/lib" \
		"$stage/source/develop/sources/zstd-$VERSION-$revision/sources"
	cp "lib/libzstd.so.$VERSION" "$stage/base/lib/"
	${CROSS}strip --strip-unneeded "$stage/base/lib/libzstd.so.$VERSION"
	ln -s "libzstd.so.$VERSION" "$stage/base/lib/libzstd.so.1"
	cp LICENSE "$stage/base/data/licenses/Zstandard"
	cp lib/zstd.h lib/zstd_errors.h lib/zdict.h "$stage/devel/develop/headers/"
	ln -s "../../lib/libzstd.so.$VERSION" "$stage/devel/develop/lib/libzstd.so"
	# the release tarball itself, not the tree with the build's objects
	tar xf "$(fetch_file "$SOURCE_URL" "$SOURCE_SHA256")" --strip-components=1 \
		-C "$stage/source/develop/sources/zstd-$VERSION-$revision/sources"
	info() { # info KIND NAME ARCHITECTURE PROVIDES REQUIRES
		cat > "$stage/$1/.PackageInfo" <<INFO
name			$2
version			$VERSION-$revision
architecture	$3
summary			"Zstandard compression for air/OS arm64"
description		"Zstandard $VERSION, built by air/OS CI from $SOURCE_URL (sha256 $SOURCE_SHA256)."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"Meta Platforms, Inc. and affiliates"
}
licenses {
	"BSD (3-clause)"
}
urls {
	"https://github.com/facebook/zstd"
}
source-urls {
	"$SOURCE_URL"
}
provides {
$4
}
requires {
$5
}
INFO
	}
	info base zstd arm64 $'\tzstd = 1.5.7\n\tlib:libzstd = 1.5.7 compat >= 1' $'\thaiku >= r1~beta6'
	info devel zstd_devel arm64 $'\tzstd_devel = 1.5.7\n\tdevel:libzstd = 1.5.7 compat >= 1' \
		$'\tzstd == 1.5.7'
	info source zstd_source source $'\tzstd_source = 1.5.7' ''
	rm -rf "$out"
	mkdir -p "$out"
	for kind in base devel source; do
		case $kind in
			base) name=zstd architecture=arm64 ;;
			devel) name=zstd_devel architecture=arm64 ;;
			source) name=zstd_source architecture=source ;;
		esac
		# The host tools keep a symbolic link's attributes under its inode
		# number (system_package).
		while IFS= read -r -d '' link; do
			rm -rf "$ATTRS/symlink-$(stat -c %i "$link")"
		done < <(find "$stage/$kind" -type l -print0)
		file=$out/$name-$VERSION-$revision-$architecture.hpkg
		chmod -R go-w "$stage/$kind"
		"$TOOLS/package/package" create -q -z zlib -C "$stage/$kind" "$file"
		echo "package: $file"
	done
}
