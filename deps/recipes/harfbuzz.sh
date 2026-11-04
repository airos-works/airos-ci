# HarfBuzz 14.2.0 for the arm64 system, the version x86_64 images have from
# HaikuPorts, built as HaikuPorts builds it (media-libs/harfbuzz): meson from
# the release tarball, debugoptimized, C++17, FreeType and ICU, no Cairo,
# GLib or tests. Left out: Graphite2 (no arm64 build of it; only Graphite
# fonts use it) and GObject, introspection and documentation (nothing on
# arm64 uses them).
#
# Why: FreeType (freetype.sh, -Dharfbuzz=dynamic) dlopen()s libharfbuzz.so.0
# for its auto-hinter's OpenType coverage, and without HarfBuzz every program
# that loads FreeType logged "Cannot open file libharfbuzz.so.0 (needed by
# libfreetype.so.6...)". Summit carries a private HarfBuzz of its own
# (summit/build-deps.sh), outside the library search path.
#
# Packaged as harfbuzz with HaikuPorts' provides, which supplements
# libfreetype as HaikuPorts' does; the arm64 images install it
# (images/build-image.sh). Nothing goes into DEPS.
VERSION=14.2.0
NO_PACKAGE=1
SOURCE_URL=https://github.com/harfbuzz/harfbuzz/releases/download/$VERSION/harfbuzz-$VERSION.tar.xz
SOURCE_SHA256=94017020f96d025bb66ae91574e4cf334bcad23e8175a8a40565b3721bc2eaff
# rebuilt when FreeType changes
STAMP_EXTRA="freetype:$(fork_info freetype-system commit)"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "harfbuzz is built for arm64 only (x86_64 has HaikuPorts' harfbuzz)"
	local dir=$WORKDIR/harfbuzz lib name
	local install=$dir/install pkg=$dir/package pc=$dir/pkgconfig
	rm -rf "$install" "$pkg" "$pc"
	mkdir -p "$pc"
	# FreeType and libpng from DEPS (freetype.sh, libpng.sh), zlib and ICU
	# from the SDK (the arm64 repository's icu74_devel: the same ICU as the
	# image's icu74, icu74.sh), all by their absolute paths.
	local sys=$SYSROOT/boot/system ftVersion
	ftVersion=$(sed -n 's/^Version: *//p' "$DEPS/develop/lib/pkgconfig/freetype2.pc")
	[[ -n $ftVersion ]] || die "no FreeType in DEPS (freetype.sh)"
	cat > "$pc/freetype2.pc" <<PC
prefix=$DEPS
includedir=\${prefix}/develop/headers
libdir=\${prefix}/develop/lib
Name: FreeType 2
Description: A free, high-quality, and portable font engine.
Version: $ftVersion
Libs: -L\${libdir} -lfreetype
Cflags: -I\${includedir}/freetype2
PC
	cat > "$pc/libpng.pc" <<PC
prefix=$DEPS
includedir=\${prefix}/develop/headers/libpng16
libdir=\${prefix}/develop/lib
Name: libpng
Description: Loads and saves PNG files
Version: 1.6.44
Libs: -L\${libdir} -lpng16
Cflags: -I\${includedir}
PC
	cat > "$pc/zlib.pc" <<PC
prefix=$sys
includedir=\${prefix}/develop/headers
libdir=\${prefix}/develop/lib
Name: zlib
Description: zlib compression library
Version: 1.2.13
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
PC
	for name in uc i18n; do
		cat > "$pc/icu-$name.pc" <<PC
prefix=$sys
includedir=\${prefix}/develop/headers
libdir=\${prefix}/develop/lib
Name: icu-$name
Description: International Components for Unicode
Version: 74.1
Libs: -L\${libdir} -licu$name
Cflags: -I\${includedir}
PC
	done
	cat > _cross.ini <<CROSS
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'haiku'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$pc']

[built-in options]
c_args = ['--sysroot=$SYSROOT']
cpp_args = ['--sysroot=$SYSROOT']
c_link_args = ['--sysroot=$SYSROOT', '-specs=$UNWIND_SPECS', '-Wl,-rpath-link,$DEPS/lib']
cpp_link_args = ['--sysroot=$SYSROOT', '-specs=$UNWIND_SPECS', '-Wl,-rpath-link,$DEPS/lib']
CROSS
	rm -rf _b
	env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS PKG_CONFIG_SYSROOT_DIR= \
		meson setup _b . --cross-file=_cross.ini --wrap-mode=nofallback \
		--prefix=$PREFIX --libdir=lib --includedir=develop/headers --datadir=data \
		--buildtype=debugoptimized -Dcpp_std=c++17 \
		-Dfreetype=enabled -Dicu=enabled -Dpng=enabled -Dzlib=enabled \
		-Dcairo=disabled -Dchafa=disabled -Dglib=disabled -Dgobject=disabled \
		-Dgraphite2=disabled -Dintrospection=disabled -Ddocs=disabled \
		-Dtests=disabled -Dutilities=disabled -Dbenchmark=disabled
	ninja -C _b -j"$JOBS"
	DESTDIR=$install ninja -C _b install

	# libharfbuzz*.so.0.<version> and its .so.0 link, as HaikuPorts has them
	local root=$install$PREFIX provides="" libVersion=""
	mkdir -p "$pkg/lib" "$pkg/data/licenses"
	for lib in "$root"/lib/libharfbuzz*.so.0.*; do
		name=$(basename "$lib")
		cp -a "$lib" "$pkg/lib/"
		${CROSS}strip --strip-debug "$pkg/lib/$name"
		ln -s "$name" "$pkg/lib/${name%%.so.*}.so.0"
		libVersion=${name##*.so.}
		# resolvable names take no '-' (HaikuPorts: lib:libharfbuzz_icu)
		lib=${name%%.so.*}
		provides+="	lib:${lib//-/_} = $libVersion compat >= 0"$'\n'
	done
	[[ -n $provides && -e $pkg/lib/libharfbuzz.so.0 ]] || die "no libharfbuzz.so.0 built"
	cp COPYING "$pkg/data/licenses/HarfBuzz"
	cat > "$pkg/.PackageInfo" <<INFO
name			harfbuzz
version			$VERSION-1
architecture	arm64
summary			"An OpenType text shaping engine"
description		"HarfBuzz $VERSION, built by air/OS CI from $SOURCE_URL (sha256 $SOURCE_SHA256) as HaikuPorts builds it, without Graphite2, and with the shared unwinder (libgcc_s)."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"2010-2022 Google, Inc."
	"2015-2020 Ebrahim Byagowi"
	"2019,2020 Facebook, Inc."
	"2012,2015 Mozilla Foundation"
	"2011 Codethink Limited"
	"2008,2010 Nokia Corporation and/or its subsidiary(-ies)"
	"2009 Keith Stribley"
	"2011 Martin Hosken and SIL International"
	"2007 Chris Wilson"
	"2005,2006,2020,2021,2022,2023 Behdad Esfahbod"
	"2004,2007,2008,2009,2010,2013,2021,2022,2023 Red Hat, Inc."
	"1998-2005 David Turner and Werner Lemberg"
	"2016 Igalia S.L."
	"2022 Matthias Clasen"
	"2018,2021 Khaled Hosny"
	"2018,2019,2020 Adobe, Inc"
	"2013-2015 Alexei Podtelezhnikov"
}
licenses {
	"MIT"
}
urls {
	"https://www.freedesktop.org/wiki/Software/HarfBuzz/"
}
provides {
	harfbuzz = $VERSION compat >= 0.9
$provides}
requires {
	haiku >= r1~beta6
	lib:libfreetype >= 6.20.4
	lib:libicuuc >= 74.1
	lib:libpng16
	lib:libz
}
supplements {
	lib:libfreetype
}
INFO
	check_shared_unwinder "$pkg"/lib/*.so.0.*
	system_package "$pkg"
}
