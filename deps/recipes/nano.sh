# GNU nano 9.1 for the arm64 system, as HaikuPorts builds it
# (app-editors/nano/nano-9.1.recipe): airos-works/nano airos-9.1, the release
# tarball, with its syntax files, against the arm64 base's ncurses6; no
# translations (arm64 has no libintl). Packaged as HaikuPorts' nano; git's
# default editor (deps/recipes/git.sh).
VERSION=9.1
NO_PACKAGE=1
build() {
	[[ $ARCH == arm64 ]] || die "nano is built for arm64 only"
	git clean -qfdx
	release_times
	configure_ac --mandir=$PREFIX/documentation/man --infodir=$PREFIX/documentation/info \
		--docdir=$PREFIX/documentation/packages/nano --disable-rpath --disable-nls
	make -j"$JOBS"
	local pkg=$WORKDIR/nano/package
	rm -rf "$pkg"
	make install DESTDIR="$pkg"
	mv "$pkg$PREFIX"/* "$pkg/"
	rm -rf "$pkg/boot" "$pkg/documentation/info/dir"
	${CROSS}strip "$pkg/bin/nano"
	[[ -L $pkg/bin/rnano ]] || die "no rnano link"
	cat > "$pkg/.PackageInfo" <<INFO
name			nano
version			$VERSION-1
architecture	arm64
summary			"Pico clone with more functionality under the GPL license"
description		"GNU nano $VERSION, a simple text editor for the command line. Built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch)) as HaikuPorts builds it."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1999-2022 Free Software Foundation, Inc."
}
licenses {
	"GNU GPL v3"
}
urls {
	"https://www.nano-editor.org/"
}
provides {
	nano = $VERSION compat >= 2
	cmd:nano = $VERSION compat >= 2
	cmd:rnano = $VERSION compat >= 2
}
requires {
	haiku >= r1~beta6
	lib:libncursesw >= 6
	lib:libz
}
INFO
	system_package "$pkg"
}
