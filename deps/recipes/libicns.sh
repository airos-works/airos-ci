# libicns 0.8.1 for the arm64 system, the version x86_64 images have from
# HaikuPorts, built as HaikuPorts builds it (media-libs/libicns): autotools,
# shared, HaikuPorts' two patches (patches/libicns-0.8.1.patchset and the
# Debian OpenJPEG 2 support, patches/libicns-0.8.1-openjp2.patch), with PNG
# (libpng.sh) and OpenJPEG (openjpeg.sh) for the JPEG 2000 icons, as
# HaikuPorts' requires them. configure would take JasPer when it finds it;
# HaikuPorts' library uses OpenJPEG, and so does this one. Packaged as
# HaikuPorts' libicns and libicns_devel (build-deps.sh library_packages),
# without the icns2png, png2icns and icontainer2icns commands: Haiku's arm64
# build makes the ICNS translator with them.
VERSION=0.8.1
NO_PACKAGE=1
SOURCE_URL=https://downloads.sourceforge.net/project/icns/libicns-$VERSION.tar.gz
SOURCE_SHA256=335f10782fc79855cf02beac4926c4bf9f800a742445afbbf7729dab384555c2
STAMP_EXTRA="patches:$(cat "$AIROS_CI"/deps/recipes/patches/libicns-0.8.1*.patch* | sha256sum | cut -c1-16)"
SUMMARY="libicns Macintosh icon library"
COPYRIGHTS="2001-2012 Mathew Eis"
LICENSES="GNU LGPL v2.1"
HOMEPAGE=https://sourceforge.net/projects/icns
PACKAGE_REQUIRES="lib:libopenjp2 >= 7
lib:libpng16 >= 16
lib:libz >= 1"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/libicns-0.8.1.patchset"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/libicns-0.8.1-openjp2.patch"
}
build() {
	[[ $ARCH == arm64 ]] || die "libicns is built for arm64 only (x86_64 has HaikuPorts')"
	autoreconf -fi
	CPPFLAGS="$CPPFLAGS -I$DEPS/develop/headers/openjpeg-2.5" ac_cv_lib_jasper_jas_init=no \
		configure_ac --disable-static
	grep -q '^#define ICNS_OPENJPEG 2' config.h || die "libicns without OpenJPEG 2"
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	normalize_stage
	library_packages libicns
}
