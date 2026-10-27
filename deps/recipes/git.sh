# git 2.56.0 for the arm64 system, as HaikuPorts builds it for x86_64
# (dev-vcs/git/git-2.56.0.recipe, its make variables): jmgasper/git
# airos-2.56.0, the release (tarball contents, manual pages, HTML
# documentation) with HaikuPorts' patches; HTTPS through air/OS's curl and
# OpenSSL, PCRE2 and libiconv (airos_curl, airos_openssl, airos_pcre2,
# airos_libiconv), nano as the default editor (deps/recipes/nano.sh). No
# translations: arm64 has no libintl, and GitHub Desktop reads Git's English
# anyway. Packaged as HaikuPorts' git, the main package of its recipe: the
# commands that HaikuPorts splits off into git_arch, git_cvs, git_daemon,
# git_email, git_gui, git_perl, git_scalar, git_svn and git_web are left out,
# so neither Perl, Python nor Tcl is needed (NO_PERL, NO_PYTHON, NO_TCLTK).
VERSION=2.56.0
NO_PACKAGE=1
# rebuilt when its libraries change
STAMP_EXTRA="curl:$(fork_info curl commit) openssl:$(fork_info openssl commit) pcre2:$(fork_info pcre2 commit) libiconv:$(sha256sum "$AIROS_CI/deps/recipes/libiconv.sh" | cut -c1-16)"
build() {
	[[ $ARCH == arm64 ]] || die "git is built for arm64 only"
	git clean -qfdx
	makeGit() {
		# uname_*: Haiku's, not the build machine's (config.mak.uname has no
		# Haiku section; the variables below are the recipe's)
		make prefix=$PREFIX \
			bindir_relative=bin \
			mandir=$PREFIX/documentation/man \
			infodir=$PREFIX/documentation/info \
			gitexecdir=$PREFIX/lib/git-core \
			sharedir=$PREFIX/data \
			template_dir=$PREFIX/data/git-core/templates \
			htmldir=$PREFIX/documentation/packages/git \
			sysconfdir=$PREFIX/settings \
			localedir=$PREFIX/data/locale \
			uname_S=Haiku uname_M=aarch64 uname_O=Haiku uname_R=1 uname_V=1 uname_P=aarch64 \
			CC="$CC" AR="$AR" STRIP="$STRIP" \
			CFLAGS="-O2" CPPFLAGS="-D_POSIX_THREAD_SAFE_FUNCTIONS $CPPFLAGS" LDFLAGS="$LDFLAGS" \
			CURL_CONFIG=false CURL_LDFLAGS=-lcurl \
			NO_GETTEXT=YesPlease \
			PTHREAD_LIBS= \
			USE_LIBPCRE2=YesPlease \
			NO_D_TYPE_IN_DIRENT=YesPlease \
			NO_MEMMEM=YesPlease \
			NEEDS_LIBICONV=YesPlease \
			NO_RUST=YesPlease \
			NO_PERL=YesPlease \
			NO_PYTHON=YesPlease \
			NO_TCLTK=YesPlease \
			OBJECT_CREATION_USES_RENAMES=YesPlease \
			NO_CROSS_DIRECTORY_HARDLINKS=YesPlease \
			NO_INSTALL_HARDLINKS=YesPlease \
			HAVE_DEV_TTY=YesPlease \
			DEFAULT_EDITOR=nano \
			DEFAULT_HELP_FORMAT=web \
			BASIC_LDFLAGS="-lnetwork -lbsd" \
			"$@"
	}
	makeGit -j"$JOBS" all
	makeGit strip

	local pkg=$WORKDIR/git/package root entry program
	rm -rf "$pkg"
	makeGit install DESTDIR="$pkg"
	mv "$pkg$PREFIX"/* "$pkg/"
	rm -rf "$pkg/boot"
	[[ -x $pkg/lib/git-core/git-remote-https ]] || die "git without HTTPS (curl)"
	# The manual pages and the HTML pages for git help (DEFAULT_HELP_FORMAT=web)
	mkdir -p "$pkg/documentation/man" "$pkg/documentation/packages/git"
	cp -rd manpages/* "$pkg/documentation/man/"
	cp -rd htmldocs/*.html "$pkg/documentation/packages/git/"
	# bash completion where HaikuPorts' package has it, and none in share/
	install -d -m 755 "$pkg/data/bash-completion/completions"
	install -m 644 contrib/completion/git-completion.bash "$pkg/data/bash-completion/completions/git"
	rm -rf "$pkg/share"
	# The system-wide gitconfig of HaikuPorts' recipe (BFS supports the
	# untracked cache).
	mkdir -p "$pkg/settings"
	printf "[core]\n\tuntrackedCache = true\n" > "$pkg/settings/gitconfig"
	# What HaikuPorts packages separately (git_arch, git_cvs, git_daemon,
	# git_email, git_gui, git_scalar, git_svn, git_web; Perl's modules are not
	# built), and the Perl and Tcl commands that NO_PERL and NO_TCLTK leave as
	# stubs.
	for entry in \
			documentation/packages/git/git-archimport.html documentation/man/man1/git-archimport.1 \
			lib/git-core/git-archimport \
			bin/git-cvsserver documentation/packages/git/git-cvsexportcommit.html \
			documentation/packages/git/git-cvsimport.html documentation/packages/git/git-cvsserver.html \
			documentation/man/man1/git-cvsexportcommit.1 documentation/man/man1/git-cvsimport.1 \
			documentation/man/man1/git-cvsserver.1 documentation/man/man7/gitcvs-migration.7 \
			lib/git-core/git-cvsexportcommit lib/git-core/git-cvsimport lib/git-core/git-cvsserver \
			documentation/packages/git/git-credential-cache--daemon.html \
			documentation/packages/git/git-credential-cache.html \
			documentation/packages/git/git-daemon.html \
			documentation/man/man1/git-credential-cache--daemon.1 \
			documentation/man/man1/git-credential-cache.1 documentation/man/man1/git-daemon.1 \
			lib/git-core/git-credential-cache--daemon lib/git-core/git-credential-cache \
			lib/git-core/git-daemon \
			documentation/packages/git/git-send-email.html documentation/man/man1/git-send-email.1 \
			lib/git-core/git-send-email \
			documentation/packages/git/git-gui.html documentation/packages/git/gitk.html \
			documentation/man/man1/git-gui.1 documentation/man/man1/gitk.1 \
			data/gitk data/git-gui lib/git-core/git-gui lib/git-core/git-gui--askpass \
			lib/git-core/git-citool bin/gitk \
			documentation/packages/git/scalar.html documentation/man/man1/scalar.1 \
			lib/git-core/scalar bin/scalar \
			documentation/packages/git/git-svn.html documentation/man/man1/git-svn.1 \
			lib/git-core/git-svn \
			documentation/packages/git/git-instaweb.html documentation/man/man1/gitweb.1 \
			documentation/man/man1/git-instaweb.1 documentation/man/man5/gitweb.conf.5 \
			data/gitweb lib/git-core/git-instaweb; do
		rm -rf "${pkg:?}/$entry"
	done
	rm -f "$pkg"/documentation/packages/git/gitweb*.html
	# The commands in bin/ are links to lib/git-core, as in HaikuPorts' package.
	for program in "$pkg"/bin/git*; do
		ln -sfn "../lib/git-core/$(basename "$program")" "$program"
	done
	cat > "$pkg/.PackageInfo" <<INFO
name			git
version			$VERSION-1
architecture	arm64
summary			"Fast, scalable, distributed revision control system"
description		"git $VERSION, built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch)) as HaikuPorts builds its main git package (HTTPS with curl and OpenSSL; no Perl, Python or Tcl commands)."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"2005-2025 Git Authors (see git web site for list)"
}
licenses {
	"GNU GPL v2"
}
urls {
	"https://git-scm.com/"
}
provides {
	git = $VERSION compat >= 2.3
	cmd:git = $VERSION compat >= 2.3
	cmd:git_receive_pack = $VERSION compat >= 2.3
	cmd:git_shell = $VERSION compat >= 2.3
	cmd:git_upload_archive = $VERSION compat >= 2.3
	cmd:git_upload_pack = $VERSION compat >= 2.3
}
requires {
	haiku >= r1~beta6
	cmd:nano
	lib:libcurl
	lib:libexpat
	lib:libiconv
	lib:libpcre2_8
	lib:libssl >= 3
	lib:libz
}
global-writable-files {
	"settings/gitconfig" auto-merge
}
user-settings-files {
	"settings/git" directory
}
INFO
	system_package "$pkg"
}
