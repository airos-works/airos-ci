# FreeType 2.14.3 for the arm64 system: app_server's font engine, in place of
# the bootstrap FreeType 2.6.3 of Haiku's arm64 repository, built as HaikuPorts
# builds it for x86_64 (media-libs/freetype/freetype-2.14.3.recipe): the
# freetype-system fork (jmgasper/freetype airos-VER-2-14-3, the release
# tarball with HaikuPorts' patches, which enable the validation modules), meson
# with error strings, HarfBuzz loaded at run time, PNG (libpng.sh) and zlib.
# Only bzip2 is left out: the arm64 images have no libbz2. Packaged as
# HaikuPorts packages it, as freetype and freetype_devel: the image builds hand
# both to Haiku's build (HAIKU_ARM64_FREETYPE_PACKAGES_DIR, jmgasper/haiku
# build/jam/BuildFeatures), which compiles against freetype_devel and puts the
# freetype package in the image instead of the bootstrap one.
VERSION=2.14.3
FORK=freetype-system
NO_PACKAGE=1
# rebuilt when libpng changes
STAMP_EXTRA="libpng:$(fork_info libpng commit)"
build() {
	[[ $ARCH == arm64 ]] || die "FreeType is built for arm64 only"
	# zlib from the SDK and libpng from DEPS (libpng.sh) by their absolute
	# paths: the SDK's own pkg-config files name /packages/... directories.
	local pc=$WORKDIR/freetype/pkgconfig
	rm -rf "$pc"
	mkdir -p "$pc"
	cat > "$pc/zlib.pc" <<PC
prefix=$SYSROOT/boot/system
includedir=\${prefix}/develop/headers
libdir=\${prefix}/develop/lib
Name: zlib
Description: zlib compression library
Version: 1.2.13
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
PC
	cat > "$pc/libpng.pc" <<PC
prefix=$DEPS
includedir=\${prefix}/develop/headers/libpng16
libdir=\${prefix}/develop/lib
Name: libpng
Description: Loads and saves PNG files
Version: 1.6.44
Requires.private: zlib
Libs: -L\${libdir} -lpng16
Cflags: -I\${includedir}
PC
	cat > _cross.ini <<CROSS
[binaries]
c = '${CROSS}gcc'
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
c_link_args = ['--sysroot=$SYSROOT', '-specs=$UNWIND_SPECS', '-Wl,-rpath-link,$DEPS/lib']
CROSS
	rm -rf _b
	env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS PKG_CONFIG_SYSROOT_DIR= \
		meson setup _b . --cross-file=_cross.ini --wrap-mode=nofallback \
		--prefix=$PREFIX --libdir=lib --includedir=develop/headers --datadir=data \
		--buildtype=debugoptimized -Derror_strings=true -Dharfbuzz=dynamic \
		-Dpng=enabled -Dzlib=system -Dbzip2=disabled -Dbrotli=disabled -Dtests=disabled
	ninja -C _b -j"$JOBS"
	DESTDIR=$STAGE ninja -C _b install
	normalize_stage
	local root=$STAGE$PREFIX lib libVersion
	lib=$(cd "$root/lib" && ls libfreetype.so.6.*.*)
	libVersion=${lib#libfreetype.so.}
	# pkg-config's libdir is develop/lib, as HaikuPorts' fixPkgconfig makes it.
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

	local description="FreeType $VERSION, built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch)) as HaikuPorts builds 2.14.3 (error strings, HarfBuzz at run time, PNG, zlib; no bzip2); replaces the bootstrap FreeType of Haiku's arm64 repository."
	cat > "$base/.PackageInfo" <<INFO
name			freetype
version			$VERSION-1
architecture	arm64
summary			"A free, high-quality, and portable font engine"
description		"$description"
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1996-2026 David Turner, Robert Wilhelm, and Werner Lemberg"
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
	lib:libpng16
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
	"1996-2026 David Turner, Robert Wilhelm, and Werner Lemberg"
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
	devel:libpng16
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
