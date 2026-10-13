# FreeType 2.13.3 (jmgasper/freetype airos-VER-2-13-3, the release tarball's
# contents) for the arm64 system: app_server's font engine, in place of the
# bootstrap FreeType 2.6.3 of Haiku's arm64 repository. Packaged as HaikuPorts
# packages it, as freetype and freetype_devel: the image builds hand both to
# Haiku's build (HAIKU_ARM64_FREETYPE_PACKAGES_DIR, jmgasper/haiku
# build/jam/BuildFeatures), which compiles against freetype_devel and puts the
# freetype package in the image instead of the bootstrap one. The fork and
# options are Summit's engine's (summit/build-deps.sh) without PNG: zlib only,
# since the arm64 images have no libpng, libbz2, Brotli or HarfBuzz.
VERSION=2.13.3
NO_PACKAGE=1
build() {
	[[ $ARCH == arm64 ]] || die "FreeType is built for arm64 only"
	cmake_build -DBUILD_SHARED_LIBS=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
		-DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_REQUIRE_ZLIB=ON
	normalize_stage
	local root=$STAGE$PREFIX lib libVersion
	lib=$(cd "$root/lib" && ls libfreetype.so.6.*.*)
	libVersion=${lib#libfreetype.so.}
	# CMake's package configuration expects the library next to it, which the
	# Haiku layout does not have; pkg-config's libdir is develop/lib, as
	# HaikuPorts' fixPkgconfig makes it.
	rm -rf "$root/develop/lib/cmake"
	sed -i 's|^libdir=.*|libdir=${prefix}/develop/lib|' "$root/develop/lib/pkgconfig/freetype2.pc"

	local base=$WORKDIR/freetype/package devel=$WORKDIR/freetype/package_devel
	rm -rf "$base" "$devel"
	mkdir -p "$base/lib" "$base/data/licenses" "$devel/develop/lib" "$devel/data/licenses"
	cp -a "$root/lib/libfreetype.so.6" "$root/lib/$lib" "$base/lib/"
	${CROSS}strip --strip-debug "$base/lib/$lib"
	# Haiku has no "FreeType" licence of its own: each package carries it.
	cp docs/FTL.TXT "$base/data/licenses/FreeType"
	cp docs/FTL.TXT "$devel/data/licenses/FreeType"
	cp -a "$root/develop/headers" "$devel/develop/"
	cp -a "$root/develop/lib/libfreetype.so" "$root/develop/lib/pkgconfig" "$devel/develop/lib/"

	local description="FreeType $VERSION, built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch)) with zlib, without PNG, bzip2, Brotli or HarfBuzz; replaces the bootstrap FreeType of Haiku's arm64 repository."
	cat > "$base/.PackageInfo" <<INFO
name			freetype
version			$VERSION-1
architecture	arm64
summary			"A free, high-quality, and portable font engine"
description		"$description"
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1996-2024 David Turner, Robert Wilhelm, and Werner Lemberg"
}
licenses {
	"FreeType"
}
urls {
	"https://www.freetype.org/"
}
provides {
	freetype = $VERSION
	lib:libfreetype = $libVersion compat >= 6
}
requires {
	haiku >= r1~beta6
	lib:libz
}
INFO
	cat > "$devel/.PackageInfo" <<INFO
name			freetype_devel
version			$VERSION-1
architecture	arm64
summary			"A free, high-quality, and portable font engine (development files)"
description		"$description"
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1996-2024 David Turner, Robert Wilhelm, and Werner Lemberg"
}
licenses {
	"FreeType"
}
urls {
	"https://www.freetype.org/"
}
provides {
	freetype_devel = $VERSION
	devel:libfreetype = $libVersion compat >= 6
}
requires {
	freetype == $VERSION
	devel:libz
}
INFO
	local name file
	for name in freetype freetype_devel; do
		file=$AIROS_PACKAGES/arm64/$name-$VERSION-1-arm64.hpkg
		with_lock packages-arm64 bash -c 'rm -f "$1"/"$2"-[0-9]*-arm64.hpkg' _ \
			"$AIROS_PACKAGES/arm64" "$name"
		if [[ $name == freetype ]]; then
			"$TOOLS/package/package" create -q -C "$base" "$file"
		else
			"$TOOLS/package/package" create -q -C "$devel" "$file"
		fi
		echo "package: $file"
	done
}
