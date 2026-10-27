# PostgreSQL 18.4's client side (arm64): libpq, psql, pg_dump, pg_dumpall and
# pg_restore, which pgAdmin 4 connects with and runs for backups, as
# HaikuPorts builds PostgreSQL for x86_64 (dev-db/postgresql/
# postgresql18-18.4.recipe): the release tarball with its patchset
# (patches/postgresql18-18.4.patchset) and the haiku template, against
# air/OS's OpenSSL and libedit. The release's configure is used as it is
# (PostgreSQL wants exactly autoconf 2.69 to make it again): the template is
# named, and -lnetwork given as HaikuPorts gives it. No server.
#
# Packaged as postgresql18, HaikuPorts' name (whose package has psql and the
# libraries; pg_dump and the others are in its postgresql18_server), with
# what pgAdmin needs of both; DEPS keeps libpq's headers for psycopg.
VERSION=18.4
NO_PACKAGE=1
SOURCE_URL=https://ftp.postgresql.org/pub/source/v18.4/postgresql-18.4.tar.bz2
SOURCE_SHA256=81a81ec695fb0c7901407defaa1d2f7973617154cf27ba74e3a7ab8e64436094
STAMP_EXTRA="patches:$(sha256sum "$AIROS_CI/deps/recipes/patches/postgresql18-18.4.patchset" | cut -c1-16)"
STAMP_EXTRA+=" openssl:$(fork_info openssl commit) libedit:$(fork_info libedit commit)"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/postgresql18-18.4.patchset"
}
build() {
	[[ $ARCH == arm64 ]] || die "PostgreSQL is built for arm64 only (x86_64 has HaikuPorts' postgresql18)"
	release_times
	# libroot has localeconv_l() but no header declares it (an implicit int
	# would cut the pointer), and Haiku's <sys/auxv.h> has no HWCAP_SVE.
	ac_cv_func_localeconv_l=no pgac_cv_sve_popcnt_intrinsics=no \
	CFLAGS="-D_BSD_SOURCE -O2" LDFLAGS="$LDFLAGS -lnetwork" \
		configure_ac --with-template=haiku \
		--with-openssl --with-libedit-preferred --without-icu --without-ldap \
		--without-pam --without-libxml --without-libxslt --without-lz4 --without-zstd \
		--disable-static
	local dir
	for dir in src/include src/interfaces/libpq src/bin/psql src/bin/pg_dump; do
		make -C "$dir" -j"$JOBS"
		make -C "$dir" install DESTDIR="$STAGE"
	done
	rm -f "$STAGE$PREFIX"/lib/libpq.a
	# The server's headers stay out of DEPS: only libpq's are for the clients.
	rm -rf "$STAGE$PREFIX"/include/postgresql/server "$STAGE$PREFIX"/develop/headers/postgresql/server

	local pkg=$WORKDIR/postgresql18/package bin
	rm -rf "$pkg"
	mkdir -p "$pkg/bin" "$pkg/lib" "$pkg/data/licenses"
	for bin in psql pg_dump pg_dumpall pg_restore; do
		install -m 755 "$STAGE$PREFIX/bin/$bin" "$pkg/bin/"
	done
	cp -a "$STAGE$PREFIX"/lib/libpq.so.* "$pkg/lib/"
	${CROSS}strip --strip-unneeded "$pkg"/bin/* "$pkg"/lib/libpq.so.5.*
	cp COPYRIGHT "$pkg/data/licenses/PostgreSQL"
	cat > "$pkg/.PackageInfo" <<INFO
name			postgresql18
version			$VERSION-1
architecture	arm64
summary			"PostgreSQL's client: libpq, psql, pg_dump, pg_dumpall, pg_restore"
description		"The client side of PostgreSQL $VERSION, built by air/OS CI from the release tarball with HaikuPorts' patches, cross-compiled from Linux: the libpq library and the psql, pg_dump, pg_dumpall and pg_restore commands. No server."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"1996-2026 The PostgreSQL Global Development Group"
	"1994 The Regents of the University of California"
}
licenses {
	"PostgreSQL"
}
urls {
	"https://www.postgresql.org/"
}
provides {
	postgresql18 = $VERSION compat >= 18
	cmd:psql = $VERSION compat >= 18
	cmd:pg_dump = $VERSION compat >= 18
	cmd:pg_dumpall = $VERSION compat >= 18
	cmd:pg_restore = $VERSION compat >= 18
	lib:libpq = 5.18 compat >= 5
}
requires {
	haiku >= r1~beta6
	lib:libcrypto >= 3
	lib:libedit
	lib:libssl >= 3
	lib:libz
}
INFO
	system_package "$pkg"
}
