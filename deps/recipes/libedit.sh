# libedit 20260512-3.1 (NetBSD's editline) for the arm64 system, as HaikuPorts
# builds it (sys-libs/libedit/libedit-20260512_3.1.recipe): airos-works/libedit
# airos-20260512-3.1, the release tarball with HaikuPorts' patches (which
# change configure.ac, hence autoreconf), wide characters, against the
# arm64 base's ncurses6. Packaged as HaikuPorts' libedit; OpenSSH's sftp
# uses it. The headers, library and pkg-config file also go into DEPS.
VERSION=20260512_3.1
NO_PACKAGE=1
build() {
	[[ $ARCH == arm64 ]] || die "libedit is built for arm64 only"
	git clean -qfdx
	release_times
	autoreconf --force --install
	configure_ac --mandir=$PREFIX/documentation/man --enable-examples=no --enable-widec \
		--disable-static
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	local root=$STAGE$PREFIX pkg=$WORKDIR/libedit/package lib libVersion
	lib=$(cd "$root/lib" && ls libedit.so.0.*.*)
	libVersion=${lib#libedit.so.}
	rm -rf "$pkg"
	mkdir -p "$pkg/lib" "$pkg/documentation/man"
	cp -a "$root"/lib/libedit.so.0* "$pkg/lib/"
	${CROSS}strip --strip-debug "$pkg/lib/$lib"
	# editrc(5) and editline(7); the library pages (man3) are libedit_devel's
	cp -a "$root/documentation/man/man5" "$root/documentation/man/man7" "$pkg/documentation/man/"
	rm -rf "$root/documentation"
	cat > "$pkg/.PackageInfo" <<INFO
name			libedit
version			$VERSION-1
architecture	arm64
summary			"A BSD licensed replacement for the GNU readline library"
description		"libedit ${VERSION/_/-}, built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch)) as HaikuPorts builds it."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1992-2026 The NetBSD Foundation, Inc."
}
licenses {
	"BSD (3-clause)"
}
urls {
	"http://thrysoee.dk/editline/"
}
provides {
	libedit = $VERSION
	lib:libedit = $libVersion compat >= 0
}
requires {
	haiku >= r1~beta6
	lib:libncurses >= 6
}
INFO
	system_package "$pkg"
}
