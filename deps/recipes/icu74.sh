# ICU 74.1 for the arm64 system, in place of the arm64 repository's bootstrap
# icu74, built as HaikuPorts builds it (dev-libs/icu/icu74-74.1.recipe): the
# release tarball with HaikuPorts' patches (patches/icu74-74.1.patchset,
# HaikuPorts 5768ca04e4; they change configure.ac, hence autoconf), the data
# as an archive file, -fno-semantic-interposition, -Bsymbolic-functions. A
# cross build: ICU's tools and data come from a build for this machine first
# (--with-cross-build).
#
# Why: the bootstrap libicuuc, libicui18n and libicuio were linked against
# libgcc's static unwinder, so each carries a private copy of it, and a C++
# exception that passes through them terminates the program. These link
# libgcc_s (UNWIND_SPECS) like everything else CI builds. They also look for
# their data in /boot/system/data/icu/74.1, where the package puts it (the
# bootstrap build's was /packages/icu74_bootstrap-74.1-1/...).
#
# Packaged as icu74 with the bootstrap package's contents and provides: the
# image builds hand it to Haiku's build (AIROS_CI_BASE_PACKAGES), which puts
# it in the image instead of the repository's. Haiku itself still compiles
# against the repository's icu74_devel, the same ICU. Nothing goes into DEPS.
VERSION=74.1
NO_PACKAGE=1
SOURCE_URL=https://github.com/unicode-org/icu/releases/download/release-74-1/icu4c-74_1-src.tgz
SOURCE_SHA256=86ce8e60681972e60e4dcb2490c697463fcec60dd400a5f9bffba26d0b52b8d0
STAMP_EXTRA="patches:$(sha256sum "$AIROS_CI/deps/recipes/patches/icu74-74.1.patchset" | cut -c1-16)"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/icu74-74.1.patchset"
}
build() {
	[[ $ARCH == arm64 ]] || die "icu74 is built for arm64 only (x86_64 has HaikuPorts' icu74)"
	local dir=$WORKDIR/icu74 lib
	local host=$dir/host target=$dir/target install=$dir/install pkg=$dir/package
	(cd source && autoconf)
	rm -rf "$host" "$target" "$install" "$pkg"
	mkdir -p "$host" "$target"
	# the tools and data for the cross build
	(cd "$host" && env -u CC -u CXX -u AR -u RANLIB -u STRIP -u NM -u LD -u OBJDUMP \
		-u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR \
		"$SRC/source/configure" --disable-samples --disable-extras --disable-tests \
		&& env -u CC -u CXX make -j"$JOBS")
	(cd "$target" && CPPFLAGS= CFLAGS="-O2 -fno-semantic-interposition" \
		CXXFLAGS="-O2 -fno-semantic-interposition" LDFLAGS=-Wl,-Bsymbolic-functions \
		"$SRC/source/configure" --host="$TRIPLET" --build="$BUILD_TRIPLET" \
		--with-cross-build="$host" --prefix=$PREFIX --bindir=$PREFIX/bin --sbindir=$PREFIX/bin \
		--libdir=$PREFIX/lib --includedir=$PREFIX/develop/headers --datadir=$PREFIX/data \
		--mandir=$PREFIX/documentation/man \
		--disable-samples --disable-extras --disable-tests --disable-tools \
		--with-data-packaging=archive)
	# The prebuilt data archive is already the target's (little-endian), and
	# then the data Makefile writes its file list without making the directory.
	mkdir -p "$target/data/out/tmp"
	(cd "$target" && make -j"$JOBS" && make install DESTDIR="$install")
	local root=$install$PREFIX
	mkdir -p "$pkg/lib" "$pkg/data/licenses"
	for lib in libicudata libicui18n libicuio libicuuc; do
		cp "$root/lib/$lib.so.$VERSION" "$pkg/lib/"
		${CROSS}strip --strip-debug "$pkg/lib/$lib.so.$VERSION"
		ln -s "$lib.so.$VERSION" "$pkg/lib/$lib.so.${VERSION%%.*}"
	done
	cp -a "$root/data/icu" "$pkg/data/"
	[[ -f $pkg/data/icu/$VERSION/icudt74l.dat ]] || die "no ICU data archive in the install"
	cp "$SRC/LICENSE" "$pkg/data/licenses/ICU"
	cat > "$pkg/.PackageInfo" <<INFO
name			icu74
version			$VERSION-1
architecture	arm64
summary			"Libraries to support Unicode and globalization"
description		"ICU $VERSION, built by air/OS CI from $SOURCE_URL (sha256 $SOURCE_SHA256) with HaikuPorts' patches, as HaikuPorts builds it, with the shared unwinder (libgcc_s)."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1995-2020 IBM Corporation and others."
}
licenses {
	"ICU"
}
urls {
	"http://www.icu-project.org"
}
provides {
	icu74 = $VERSION compat >= 74
	lib:libicudata = $VERSION compat >= 74
	lib:libicui18n = $VERSION compat >= 74
	lib:libicuio = $VERSION compat >= 74
	lib:libicuuc = $VERSION compat >= 74
}
requires {
	haiku >= r1~beta6
}
INFO
	check_shared_unwinder "$pkg"/lib/*.so.$VERSION
	system_package "$pkg"
}
