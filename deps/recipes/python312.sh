# CPython 3.12.15 (arm64), which pgAdmin 4's server runs on, as HaikuPorts
# builds it for x86_64 (dev-lang/python/python3.12-3.12.15.recipe): the release
# tarball with its patchset (patches/python3.12-3.12.15.patchset; configure is
# made again from the patched configure.ac, which knows Haiku, and
# python3.12-3.12.15-airos-cross.patch lets it cross-build for Haiku), a shared
# libpython, editline for the REPL, and air/OS's OpenSSL, SQLite, libffi
# (deps/recipes/libffi.sh) and libedit. A cross build: a Linux CPython of the
# same version (python-build-standalone's, BUILD_PYTHON_URL) runs the build's
# own Python steps, and compiles the standard library's bytecode at install.
# Left out, as the arm64 base has no libraries for them: bz2 and lzma (tarfile
# and zipfile do without), tkinter, uuid's libuuid and the locale module's
# gettext; expat is the bundled copy.
#
# Packaged as HaikuPorts' python3.12 (cmd:python3.12, lib:libpython3.12) with
# its headers; DEPS keeps the whole tree (lib/python3.12 with the
# sysconfigdata and config-3.12), which cross-builds of Python modules
# (Aurora's ports/pgadmin4/cross.sh) build against.
VERSION=3.12.15
NO_PACKAGE=1
SOURCE_URL=https://www.python.org/ftp/python/3.12.15/Python-3.12.15.tar.xz
SOURCE_SHA256=c2c4321961fab0fb999d66e0cecf521c2ab3994c7992873ea99e306c1094fd5a
BUILD_PYTHON_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.12.15+20261021-x86_64-unknown-linux-gnu-install_only.tar.gz
BUILD_PYTHON_SHA256=5ff9f0602ce964a529ed1e8555d3abab6341926d724402ba9a15e9e877191124
# rebuilt when its libraries change
STAMP_EXTRA="patches:$(cat "$AIROS_CI"/deps/recipes/patches/python3.12-3.12.15* | sha256sum | cut -c1-16)"
STAMP_EXTRA+=" openssl:$(fork_info openssl commit) sqlite:$(fork_info sqlite commit) libedit:$(fork_info libedit commit)"
STAMP_EXTRA+=" libffi:$(sha256sum "$AIROS_CI/deps/recipes/libffi.sh" | cut -c1-16)"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/python3.12-3.12.15.patchset"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/python3.12-3.12.15-airos-cross.patch"
}
build() {
	[[ $ARCH == arm64 ]] || die "Python is built for arm64 only (x86_64 has HaikuPorts' python3.12)"
	local host=$WORKDIR/python312/build-python
	if [[ ! -x $host/bin/python3.12 ]]; then
		local tarball
		tarball=$(fetch_file "$BUILD_PYTHON_URL" "$BUILD_PYTHON_SHA256")
		rm -rf "$host"
		mkdir -p "$host"
		tar xzf "$tarball" -C "$host" --strip-components=1
	fi
	release_times
	autoconf
	# What configure cannot run when cross-compiling, as Haiku answers it.
	cat > config.site <<EOF
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
EOF
	CONFIG_SITE=$PWD/config.site BASECFLAGS="-pipe -D_BSD_SOURCE" OPT="-Wall -O3" \
		CFLAGS= CXXFLAGS= \
		configure_ac --mandir=$PREFIX/documentation/man \
		--with-build-python="$host/bin/python3.12" \
		--enable-shared \
		--with-ensurepip=no \
		--with-readline=editline \
		--with-tzpath=$PREFIX/data/zoneinfo \
		--without-static-libpython \
		--disable-test-modules
	make -j"$JOBS"
	make altinstall DESTDIR="$STAGE"
	local root=$STAGE$PREFIX
	rm -f "$root/lib/libpython3.so"
	rm -rf "$root/lib/python3.12/test" "$root/lib/python3.12/idlelib/idle_test" "$root/bin/idle3.12"
	# The compiler on Haiku is gcc, not this machine's cross compiler.
	sed -i -e "s| --sysroot=$SYSROOT||g" -e "s| -specs=$UNWIND_SPECS||g" -e "s|$CROSS||g" \
		"$root"/lib/python3.12/_sysconfigdata_*.py "$root"/lib/python3.12/config-3.12/Makefile
	find "$root/lib/python3.12" -name '_sysconfigdata_*.cpython-312*.pyc' -delete
	# As HaikuPorts: modules pip installs go below non-packaged.
	mkdir -p "$root/lib/python3.12/vendor-packages" "$root/non-packaged/lib/python3.12"
	echo 'This directory contains packaged python modules.' \
		> "$root/lib/python3.12/vendor-packages/README"
	mv "$root/lib/python3.12/site-packages" "$root/non-packaged/lib/python3.12/"
	# lib-dynload's modules link libpython, which is in lib/.
	${CROSS}strip --strip-unneeded "$root"/bin/python3.12 "$root"/lib/libpython3.12.so.1.0 \
		"$root"/lib/python3.12/lib-dynload/*.so

	local pkg=$WORKDIR/python312/package
	rm -rf "$pkg"
	mkdir -p "$pkg/develop/headers" "$pkg/data/licenses"
	cp -a "$root/bin" "$root/lib" "$root/non-packaged" "$pkg/"
	cp -a "$root/develop/headers/python3.12" "$pkg/develop/headers/"
	rm -rf "$pkg/lib/pkgconfig"
	cp LICENSE "$pkg/data/licenses/Python"
	cat > "$pkg/.PackageInfo" <<INFO
name			python3.12
version			$VERSION-1
architecture	arm64
summary			"An interpreted, interactive, object-oriented programming language"
description		"Python $VERSION, built by air/OS CI from the release tarball with HaikuPorts' patches as HaikuPorts builds it, cross-compiled from Linux. Without the bz2, lzma and tkinter modules."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1990-2026 Python Software Foundation"
}
licenses {
	"Python"
}
urls {
	"https://www.python.org"
}
provides {
	python3.12 = $VERSION compat >= 3.12
	cmd:pydoc3.12 = $VERSION compat >= 3.12
	cmd:python3.12 = $VERSION compat >= 3.12
	cmd:python3.12_config = $VERSION compat >= 3.12
	lib:libpython3.12 = 1.0
}
requires {
	haiku >= r1~beta6
	lib:libcrypto >= 3
	lib:libedit
	lib:libffi >= 8
	lib:libncursesw >= 6
	lib:libsqlite3
	lib:libssl >= 3
	lib:libz
}
global-writable-files {
	"non-packaged/lib/python3.12/site-packages" directory keep-old
}
INFO
	system_package "$pkg"
}
