# libffi 3.4.6 (arm64), for Python's ctypes and cffi (pgAdmin 4), as
# HaikuPorts builds it for x86_64 (dev-libs/libffi/libffi-3.4.6.recipe): the
# release tarball with its patchset (patches/libffi-3.4.6.patchset: Haiku
# allocates closures with PROT_WRITE | PROT_EXEC). Packaged as HaikuPorts'
# libffi (lib:libffi 8.1.4), the library only; the headers stay in DEPS.
VERSION=3.4.6
NO_PACKAGE=1
SOURCE_URL=https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
SOURCE_SHA256=b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
STAMP_EXTRA="patches:$(sha256sum "$AIROS_CI/deps/recipes/patches/libffi-3.4.6.patchset" | cut -c1-16)"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/libffi-3.4.6.patchset"
}
build() {
	[[ $ARCH == arm64 ]] || die "libffi is built for arm64 only (x86_64 has HaikuPorts' libffi)"
	release_times
	configure_ac --disable-static --disable-docs
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	rm -f "$STAGE$PREFIX"/lib/libffi.la

	local pkg=$WORKDIR/libffi/package
	rm -rf "$pkg"
	mkdir -p "$pkg/lib" "$pkg/data/licenses"
	cp -a "$STAGE$PREFIX"/lib/libffi.so.* "$pkg/lib/"
	${CROSS}strip --strip-unneeded "$pkg"/lib/libffi.so.8.*
	cp LICENSE "$pkg/data/licenses/libffi"
	cat > "$pkg/.PackageInfo" <<INFO
name			libffi
version			$VERSION-1
architecture	arm64
summary			"A portable, high level programming interface"
description		"libffi $VERSION, built by air/OS CI from the release tarball with HaikuPorts' patches. libffi is a foreign function interface library: Python's ctypes and cffi call C functions through it."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1996-2021 Anthony Green, Red Hat, Inc and others."
}
licenses {
	"MIT"
}
urls {
	"https://sourceware.org/libffi"
}
provides {
	libffi = $VERSION compat >= 3
	lib:libffi = 8.1.4 compat >= 8
}
requires {
	haiku >= r1~beta6
}
INFO
	system_package "$pkg"
}
