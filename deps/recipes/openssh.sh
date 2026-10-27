# OpenSSH 10.6p1 for the arm64 system, as HaikuPorts builds it for x86_64
# (net-misc/openssh/openssh-10.6p1.recipe): jmgasper/openssh-portable
# airos-10.6p1, the release tag with HaikuPorts' patches and post-install
# scripts, libedit for sftp, against air/OS's OpenSSL 3. Packaged as
# HaikuPorts' openssh, with its users, groups, settings files and post-install
# scripts: at first boot package_daemon adds the sshd user and group and the
# settings in /boot/system/settings/ssh, and sshd_keymaker.sh makes the host
# keys; Haiku's network services settings start sshd.
#
# Built with the /boot/system paths air/OS's own builds use where HaikuPorts
# has /packages/openssh-<version>/... (which its post-install script rewrites
# in sshd_config): settings in /boot/system/settings/ssh, the helpers in
# /boot/system/lib/openssh, the privilege separation directory (the sshd
# user's home) /boot/system/data/openssh/empty, the PID file in
# /boot/system/var (which every system has; HaikuPorts' var/run is inside
# its read-only package, so its sshd cannot write one).
VERSION=10.6p1
NO_PACKAGE=1
# rebuilt when its libraries change
STAMP_EXTRA="libedit:$(fork_info libedit commit) openssl:$(fork_info openssl commit)"
build() {
	[[ $ARCH == arm64 ]] || die "openssh is built for arm64 only"
	git clean -qfdx
	release_times
	local defaultPath=".:/boot/home/config/non-packaged/bin:/boot/home/config/bin"
	defaultPath+=":/boot/system/non-packaged/bin:/boot/system/bin:/bin"
	defaultPath+=":/boot/system/apps:/boot/system/preferences"
	# What configure cannot run when cross-compiling: Haiku's malloc(0) and
	# realloc(NULL, 0) return pointers.
	ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes \
	PATH_PASSWD_PROG=/boot/system/bin/passwd LOGIN_PROGRAM=/boot/system/bin/login \
	configure_ac --sbindir=$PREFIX/bin --mandir=$PREFIX/documentation/man \
		--sysconfdir=$PREFIX/settings/ssh \
		--libexecdir=$PREFIX/lib/openssh \
		--with-privsep-path=$PREFIX/data/openssh/empty \
		--with-pid-dir=$PREFIX/var \
		--with-default-path="$defaultPath" \
		--with-maildir=/var/mail \
		--disable-utmpx \
		--disable-strip \
		--with-libedit
	# configure looks for /proc/<pid>/fd on the build machine; Haiku has none.
	sed -i '/^#define HAVE_PROC_PID 1$/d' config.h
	make -j"$JOBS"

	local pkg=$WORKDIR/openssh/package root
	rm -rf "$pkg"
	make install-nokeys DESTDIR="$pkg"
	root=$pkg$PREFIX
	mv "$root"/* "$pkg/"
	rm -rf "$pkg/boot"
	install -m 755 contrib/ssh-copy-id "$pkg/bin/"
	install -m 644 contrib/ssh-copy-id.1 "$pkg/documentation/man/man1/"
	${CROSS}strip "$pkg"/bin/scp "$pkg"/bin/sftp "$pkg"/bin/ssh "$pkg"/bin/ssh-add \
		"$pkg"/bin/ssh-agent "$pkg"/bin/ssh-keygen "$pkg"/bin/ssh-keyscan "$pkg"/bin/sshd \
		"$pkg"/lib/openssh/*
	mkdir -p "$pkg/boot/post-install" "$pkg/data/licenses" "$pkg/data/openssh/empty"
	install -m 755 haiku/net-misc/openssh/additional-files/sshd_keymaker.sh \
		haiku/net-misc/openssh/additional-files/fix_openssh_config_paths.sh "$pkg/boot/post-install/"
	cp LICENCE "$pkg/data/licenses/OpenSSH"
	# As HaikuPorts' INSTALL: the users' keys are in their settings directory.
	sed -i -e "s| ~/\.ssh/| /boot/home/config/settings/ssh/|" "$pkg/settings/ssh/ssh_config"
	cp "$pkg/settings/ssh/ssh_config" "$pkg/data/openssh/ssh_config.default"
	cp "$pkg/settings/ssh/sshd_config" "$pkg/data/openssh/sshd_config.default"
	cat > "$pkg/.PackageInfo" <<INFO
name			openssh
version			$VERSION-1
architecture	arm64
summary			"Secure Shell client and server (remote login program)"
description		"OpenSSH $VERSION: ssh, scp, sftp, sshd, ssh-add, ssh-agent, ssh-keygen and ssh-keyscan. Built by air/OS CI from $(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch)) as HaikuPorts builds it."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"2005-2020 Tatu Ylonen et al."
}
licenses {
	"OpenSSH"
}
urls {
	"http://www.openssh.com/"
}
provides {
	openssh = $VERSION compat >= 5
	cmd:scp = $VERSION compat >= 5
	cmd:sftp = $VERSION compat >= 5
	cmd:ssh = $VERSION compat >= 5
	cmd:ssh_add = $VERSION compat >= 5
	cmd:ssh_agent = $VERSION compat >= 5
	cmd:ssh_copy_id = $VERSION compat >= 5
	cmd:ssh_keygen = $VERSION compat >= 5
	cmd:ssh_keyscan = $VERSION compat >= 5
	cmd:sshd = $VERSION compat >= 5
}
requires {
	haiku >= r1~beta6
	cmd:grep
	cmd:login
	cmd:passwd
	cmd:sed
	lib:libcrypto >= 3
	lib:libedit
	lib:libncurses >= 6
	lib:libssl >= 3
	lib:libz
}
global-writable-files {
	"settings/ssh" directory keep-old
	"settings/ssh/ssh_config" keep-old
	"settings/ssh/sshd_config" keep-old
}
user-settings-files {
	"settings/ssh" directory
	"settings/ssh/ssh_config" template "data/openssh/ssh_config.default"
	"settings/ssh/sshd_config" template "data/openssh/sshd_config.default"
}
users {
	sshd real-name "sshd user" home "/boot/system/data/openssh/empty" shell "/bin/true" groups "sshd"
}
groups {
	sshd
}
post-install-scripts {
	"boot/post-install/sshd_keymaker.sh"
	"boot/post-install/fix_openssh_config_paths.sh"
}
INFO
	system_package "$pkg"
}
