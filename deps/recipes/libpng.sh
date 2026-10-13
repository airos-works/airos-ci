# libpng 1.6.44 (jmgasper/libpng airos-v1.6.44, the release tarball's
# contents) for the arm64 system, built and packaged as jmgasper/haiku's
# tools/rpi4/build-image-libs.sh does for the lab images: libpng16 and
# libpng16_devel with HaikuPorts' names and provides. The arm64 image builds
# hand both to Haiku's build (HAIKU_ARM64_LIBPNG_PACKAGES_DIR), whose libpng
# build feature makes the PNG translator, and put libpng16 in the image;
# FreeType (freetype.sh) links against it for PNG glyph bitmaps.
VERSION=1.6.44
NO_PACKAGE=1
build() {
	[[ $ARCH == arm64 ]] || die "libpng is built for arm64 only"
	cmake_build -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
		-DPNG_ARM_NEON=on -DCMAKE_SKIP_RPATH=ON \
		-DZLIB_INCLUDE_DIR="$SYSROOT/boot/system/develop/headers" \
		-DZLIB_LIBRARY="$SYSROOT/boot/system/develop/lib/libz.so"
	normalize_stage
	local root=$STAGE$PREFIX lib libVersion
	lib=$(cd "$root/lib" && ls libpng16.so.16.*.*)
	libVersion=${lib#libpng16.so.}
	sed -i 's|^libdir=.*|libdir=${prefix}/develop/lib|' "$root"/develop/lib/pkgconfig/libpng*.pc

	local base=$WORKDIR/libpng/package devel=$WORKDIR/libpng/package_devel header
	rm -rf "$base" "$devel"
	mkdir -p "$base/lib" "$devel/develop/headers/libpng16" "$devel/develop/lib"
	cp "$root/lib/$lib" "$base/lib/"
	${CROSS}strip --strip-unneeded "$base/lib/$lib"
	ln -s "$lib" "$base/lib/libpng16.so.16"
	# png.h, pngconf.h and pnglibconf.h, also under libpng16/ as HaikuPorts has them
	for header in png.h pngconf.h pnglibconf.h; do
		cp -L "$root/develop/headers/libpng16/$header" "$devel/develop/headers/"
		cp -L "$root/develop/headers/libpng16/$header" "$devel/develop/headers/libpng16/"
	done
	ln -s "../../lib/$lib" "$devel/develop/lib/libpng16.so"
	ln -s libpng16.so "$devel/develop/lib/libpng.so"
	cp -a "$root/develop/lib/pkgconfig" "$devel/develop/lib/"

	local description="libpng $VERSION, built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch)) for the arm64 system."
	cat > "$base/.PackageInfo" <<INFO
name			libpng16
version			$VERSION-1
architecture	arm64
summary			"libpng $VERSION PNG reference library"
description		"$description"
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1995-2024 The PNG Reference Library Authors"
}
licenses {
	"LibPNG"
}
urls {
	"http://www.libpng.org/pub/png/libpng.html"
}
provides {
	libpng16 = $VERSION compat >= 1.6
	lib:libpng16 = $libVersion compat >= 16
}
requires {
	haiku >= r1~beta6
	lib:libz >= 1
}
INFO
	cat > "$devel/.PackageInfo" <<INFO
name			libpng16_devel
version			$VERSION-1
architecture	arm64
summary			"libpng $VERSION PNG reference library, development files"
description		"$description"
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1995-2024 The PNG Reference Library Authors"
}
licenses {
	"LibPNG"
}
urls {
	"http://www.libpng.org/pub/png/libpng.html"
}
provides {
	libpng16_devel = $VERSION compat >= 1.6
	devel:libpng16 = $libVersion compat >= 16
	devel:libpng = $libVersion compat >= 16
}
requires {
	libpng16 == $VERSION
}
INFO
	local name dir file
	for name in libpng16 libpng16_devel; do
		dir=$base
		[[ $name == libpng16 ]] || dir=$devel
		file=$AIROS_PACKAGES/arm64/$name-$VERSION-1-arm64.hpkg
		with_lock packages-arm64 bash -c 'rm -f "$1"/"$2"-[0-9]*-arm64.hpkg' _ \
			"$AIROS_PACKAGES/arm64" "$name"
		"$TOOLS/package/package" create -q -C "$dir" "$file"
		echo "package: $file"
	done
}
