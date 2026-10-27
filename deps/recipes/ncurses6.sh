# ncurses 6.6 for the arm64 system, in place of the arm64 repository's
# bootstrap ncurses6, with HaikuPorts' configuration
# (sys-libs/ncurses/ncurses6-6.6.recipe) from the release tarball HaikuPorts
# uses: wide characters, shared libraries only, terminfo with symbolic links,
# the programs. ncurses' own Haiku shared library rules instead of libtool,
# so HaikuPorts' patch (libtool's install paths) does not apply.
#
# Why: the bootstrap libncurses++w was linked against libgcc's static
# unwinder, so it carries a private copy of it, and a C++ exception that
# passes through it terminates the program. These link libgcc_s
# (UNWIND_SPECS) like everything else CI builds. Their terminfo is
# /boot/system/data/terminfo, where the package puts it (the bootstrap
# build's was /packages/ncurses6_bootstrap-6.6-1/...).
#
# Packaged as ncurses6 with the bootstrap package's contents and provides:
# the image builds hand it to Haiku's build (AIROS_CI_BASE_PACKAGES), which
# puts it in the image instead of the repository's. Nothing goes into DEPS.
VERSION=6.6
NO_PACKAGE=1
SOURCE_URL=https://github.com/ThomasDickey/ncurses-snapshots/archive/refs/tags/v6_6.tar.gz
SOURCE_SHA256=5109f372b0e80f59603808947f6fc63c8fd4146768ebfa13982459946113effd
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "ncurses6 is built for arm64 only (x86_64 has HaikuPorts' ncurses6)"
	local dir=$WORKDIR/ncurses6 lib name
	local install=$dir/install pkg=$dir/package
	rm -rf "$install" "$pkg"
	# tic for the terminfo database and the build's generators run here
	CPPFLAGS= LDFLAGS= ./configure --host="$TRIPLET" --build="$BUILD_TRIPLET" \
		--prefix=$PREFIX --bindir=$PREFIX/bin --libdir=$PREFIX/lib \
		--includedir=$PREFIX/develop/headers --datadir=$PREFIX/data \
		--mandir=$PREFIX/documentation/man \
		--with-build-cc=gcc --with-tic-path=/usr/bin/tic --with-infocmp-path=/usr/bin/infocmp \
		--with-shared --with-cxx-shared --without-normal --without-debug \
		--disable-relink --disable-root-access --enable-root-environ \
		--disable-setuid-environ --disable-static --disable-stripping --enable-hard-tabs \
		--enable-pc-files \
		--enable-symlinks --enable-termcap --enable-widec --without-ada --without-tests \
		--with-pkg-config-libdir=$PREFIX/develop/lib/pkgconfig
	make -j"$JOBS"
	make install DESTDIR="$install"
	local root=$install$PREFIX
	mkdir -p "$pkg/lib" "$pkg/documentation/man"
	cp -a "$root/bin" "$pkg/"
	rm -f "$pkg/bin/ncursesw6-config"
	for name in "$pkg"/bin/*; do
		[[ -L $name ]] || ${CROSS}strip --strip-debug "$name"
	done
	mkdir -p "$pkg/data"
	cp -a "$root/data/terminfo" "$root/data/tabset" "$pkg/data/"
	# the programs' and the database's pages (man3 is the library's)
	cp -a "$root/documentation/man/man1" "$root/documentation/man/man5" \
		"$root/documentation/man/man7" "$pkg/documentation/man/"
	rm -f "$pkg/documentation/man/man1/ncursesw6-config.1"*
	# libXw.so.6.6, libXw.so.6 and libX.so.6 -> libXw.so.6
	for lib in form menu ncurses ncurses++ panel; do
		cp -a "$root/lib/lib${lib}w.so.6" "$root/lib/lib${lib}w.so.$VERSION" "$pkg/lib/"
		${CROSS}strip --strip-debug "$pkg/lib/lib${lib}w.so.$VERSION"
		ln -s "lib${lib}w.so.6" "$pkg/lib/lib${lib}.so.6"
	done
	local compat="$VERSION compat >= 6" libCompat="$VERSION.0 compat >= 6"
	cat > "$pkg/.PackageInfo" <<INFO
name			ncurses6
version			$VERSION-1
architecture	arm64
summary			"New curses library"
description		"ncurses $VERSION, built by air/OS CI from $SOURCE_URL (sha256 $SOURCE_SHA256) with HaikuPorts' configuration and the shared unwinder (libgcc_s)."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"2018-2023,2024 Thomas E. Dickey"
	"1998-2017,2018 Free Software Foundation, Inc."
}
licenses {
	"MIT"
}
urls {
	"https://invisible-island.net/ncurses/"
}
provides {
	ncurses6 = $VERSION
	lib:libform = $libCompat
	lib:libformw = $libCompat
	lib:libmenu = $libCompat
	lib:libmenuw = $libCompat
	lib:libncurses = $libCompat
	lib:libncursesw = $libCompat
	lib:libncurses++ = $libCompat
	lib:libncurses++w = $libCompat
	lib:libpanel = $libCompat
	lib:libpanelw = $libCompat
	cmd:captoinfo = $compat
	cmd:clear = $compat
	cmd:infocmp = $compat
	cmd:infotocap = $compat
	cmd:reset = $compat
	cmd:tabs = $compat
	cmd:tic = $compat
	cmd:toe = $compat
	cmd:tput = $compat
	cmd:tset = $compat
}
requires {
	haiku >= r1~beta6
}
INFO
	check_shared_unwinder "$pkg"/lib/*.so.$VERSION
	system_package "$pkg"
}
