#!/usr/bin/env bash
# build-deps.sh ARCH [RECIPE...]
#
# Cross-build third-party libraries from the jmgasper forks (pinned in
# forks/forks.lock.json) with the air/OS SDK of ARCH. For each recipe in
# deps/recipes/ (default: all of them, in dependency order):
#
#   1. check out the fork at its pinned commit;
#   2. build it and install into a stage with the Haiku layout: libraries in
#      lib/, headers in develop/headers/, static libraries, the libX.so links
#      and pkg-config files in develop/lib/;
#   3. merge the stage into $AIROS_ROOT/deps/ARCH/boot/system (DEPS), which app
#      builds and later recipes compile against;
#   4. package it as airos_<name>-<version>-ARCH.hpkg into the package pool
#      ($AIROS_PACKAGES/ARCH), from which the images install it. Recipes that
#      make a system package (wpa_supplicant, libpng, freetype, and OpenSSH
#      and its libedit, which x86_64 gets from HaikuPorts) set NO_PACKAGE and
#      package it under its own name themselves (system_package below).
#
# A recipe is skipped when its fork commit and recipe are unchanged since the
# last build (stamp in the work tree), unless FORCE=1.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-deps.sh x86_64|arm64 [recipe...]}
shift
# Exclusive: app builds read DEPS under the shared haiku-ARCH lock.
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec env AIROS_LOCKED=haiku-$ARCH flock "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$ARCH" "$@"
fi
export AIROS_ARCH=$ARCH
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

if [[ $ARCH == arm64 ]]; then
	# libedit and openssh: ssh and sshd, which x86_64 has from HaikuPorts and
	# the arm64 repository does not have, under HaikuPorts' names.
	ORDER=(openssl nghttp2 curl sqlite libiconv taglib pcre2 scintilla lexilla x264 x265 svt_av1 libvpx lame
		rock5_ffmpeg wpa_supplicant fluidlite libpng freetype nodejs22 libedit openssh)
else
	ORDER=(haikuports)
fi
RECIPES=("${@:-${ORDER[@]}}")
WORKDIR=$AIROS_WORK/deps-$ARCH
PREFIX=/boot/system
mkdir -p "$WORKDIR" "$AIROS_PACKAGES/$ARCH" "$DEPS"

# --- cross environment the recipes use -------------------------------------
DEPS_ROOT=${DEPS%/boot/system}
export CC="${CROSS}gcc --sysroot=$SYSROOT -specs=$UNWIND_SPECS"
export CXX="${CROSS}g++ --sysroot=$SYSROOT -specs=$UNWIND_SPECS"
export AR=${CROSS}ar RANLIB=${CROSS}ranlib STRIP=${CROSS}strip NM=${CROSS}nm LD=${CROSS}ld \
	OBJDUMP=${CROSS}objdump
export CPPFLAGS="-I$DEPS/develop/headers"
export CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC"
export LDFLAGS="-L$DEPS/develop/lib -L$DEPS/lib -Wl,-rpath-link,$DEPS/lib -Wl,-rpath-link,$SYSROOT/boot/system/lib"
export PKG_CONFIG_LIBDIR=$DEPS/develop/lib/pkgconfig PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=$DEPS_ROOT
BUILD_TRIPLET=$(uname -m)-pc-linux-gnu
TOOLCHAIN_FILE=$WORKDIR/toolchain.cmake
case $ARCH in arm64) PROCESSOR=aarch64 ;; x86_64) PROCESSOR=x86_64 ;; esac
cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR $PROCESSOR)
set(CMAKE_SYSROOT $SYSROOT)
set(CMAKE_C_COMPILER ${CROSS}gcc)
set(CMAKE_CXX_COMPILER ${CROSS}g++)
set(CMAKE_C_FLAGS_INIT "-fPIC -I$DEPS/develop/headers")
set(CMAKE_CXX_FLAGS_INIT "-fPIC -I$DEPS/develop/headers")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-specs=$UNWIND_SPECS -L$DEPS/develop/lib -Wl,-rpath-link,$DEPS/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-specs=$UNWIND_SPECS -L$DEPS/develop/lib -Wl,-rpath-link,$DEPS/lib")
set(CMAKE_FIND_ROOT_PATH $SYSROOT/boot/system $SYSROOT/boot/system/develop $DEPS $DEPS/develop)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# configure_ac [args]: autotools cross configure into the Haiku layout.
configure_ac() {
	./configure --host="$TRIPLET" --build="$BUILD_TRIPLET" --prefix=$PREFIX \
		--libdir=$PREFIX/lib --includedir=$PREFIX/develop/headers \
		--datarootdir=$PREFIX/data --sysconfdir=$PREFIX/settings "$@"
}
# fetch_tarball URL SHA256: SRC becomes the tree of a release tarball (cached
# in $AIROS_CACHE/tarballs and checked against SHA256), for the libraries that
# have no fork: they are built from their release, as HaikuPorts builds them.
# Their recipes set SOURCE_URL and SOURCE_SHA256, which the package names.
# fetch_file URL SHA256: print the path of the cached, checked download.
fetch_file() {
	local url=$1 sha=$2 file
	file=$AIROS_CACHE/tarballs/${sha:0:16}-$(basename "$url")
	mkdir -p "$AIROS_CACHE/tarballs"
	if [[ ! -f $file ]] || ! echo "$sha  $file" | sha256sum -c --quiet; then
		curl -fsSL -o "$file.part" "$url" || die "cannot download $url"
		echo "$sha  $file.part" | sha256sum -c --quiet || die "$url: checksum mismatch"
		mv "$file.part" "$file"
	fi
	echo "$file"
}
fetch_tarball() {
	local file
	file=$(fetch_file "$1" "$2")
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xf "$file" -C "$SRC" --strip-components=1
}
# cmake_build [args]: configure, build and install a CMake project.
cmake_build() {
	cmake -S . -B _build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
		-DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_INCLUDEDIR=develop/headers "$@" >/dev/null
	cmake --build _build -j"$JOBS" >/dev/null
	DESTDIR=$STAGE cmake --install _build >/dev/null
}

# normalize: move what install(1) put in the usual places to the Haiku layout.
normalize_stage() {
	local root=$STAGE$PREFIX lib target
	mkdir -p "$root/develop/lib" "$root/develop/headers"
	if [[ -d $root/include ]]; then cp -a "$root/include/." "$root/develop/headers/"; rm -rf "$root/include"; fi
	if [[ -d $root/lib/pkgconfig ]]; then
		mkdir -p "$root/develop/lib/pkgconfig"
		mv "$root/lib/pkgconfig"/* "$root/develop/lib/pkgconfig/"
		rmdir "$root/lib/pkgconfig"
	fi
	if [[ -d $root/lib/cmake ]]; then mv "$root/lib/cmake" "$root/develop/lib/"; fi
	[[ ! -d $root/lib ]] \
		|| find "$root/lib" -maxdepth 1 \( -name '*.a' -o -name '*.la' \) -exec mv {} "$root/develop/lib/" \;
	rm -f "$root"/develop/lib/*.la
	# libX.so development links point into lib/
	for lib in "$root"/lib/*.so; do
		[[ -e $lib ]] || continue
		if [[ -L $lib ]]; then
			# libX.so -> libX.so.N: the link belongs in develop/lib
			target=$(readlink -f "$lib")
			rm -f "$lib"
			ln -sf "../../lib/$(basename "$target")" "$root/develop/lib/$(basename "$lib")"
		else
			# an unversioned library (Scintilla, Lexilla) stays in lib/
			ln -sf "../../lib/$(basename "$lib")" "$root/develop/lib/$(basename "$lib")"
		fi
	done
	# pkg-config files: everything below /boot/system
	sed -i "s|^includedir=.*|includedir=\${prefix}/develop/headers|" "$root"/develop/lib/pkgconfig/*.pc 2>/dev/null || true
	rm -rf "$root/share/man" "$root/data/man" "$root/share/doc" "$root/data/doc"
	[[ -d $root/share ]] && { mkdir -p "$root/data"; cp -a "$root/share/." "$root/data/"; rm -rf "$root/share"; }
	return 0
}

# package: airos_<name> with lib: provides for every shared library.
make_package() {
	local root=$STAGE$PREFIX pkg=airos_${NAME//-/_} file soname provides="" lib origin
	if [[ -n ${SOURCE_URL:-} ]]; then
		origin="$SOURCE_URL (sha256 $SOURCE_SHA256)"
	else
		origin="$(fork_info "$FORK" url) at $FORK_COMMIT (branch $(fork_info "$FORK" branch))"
	fi
	for lib in "$root"/lib/*.so*; do
		[[ -f $lib && ! -L $lib ]] || continue
		soname=$(${CROSS}readelf -d "$lib" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		[[ -n $soname ]] || continue
		soname=${soname%%.so*}
		# resolvable names take no '-' (Haiku writes lib:libpcre2_8)
		provides+="	lib:${soname//-/_} = ${VERSION//-/_}"$'\n'
	done
	cat > "$root/.PackageInfo" <<EOF
name			$pkg
version			${VERSION//-/_}-${PKG_REVISION:-1}
architecture	$ARCH
summary			"$SUMMARY"
description		"$SUMMARY. Built by air/OS CI from $origin."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"$COPYRIGHT"
}
licenses {
	"$LICENSE"
}
provides {
	$pkg = ${VERSION//-/_}
$provides}
requires {
	haiku >= r1~beta6
$(for r in ${REQUIRES:-}; do printf '\tairos_%s\n' "$r"; done)
}
EOF
	file=$AIROS_PACKAGES/$ARCH/$pkg-${VERSION//-/_}-${PKG_REVISION:-1}-$ARCH.hpkg
	with_lock packages-$ARCH bash -c 'rm -f "$1"/"$2"-[0-9]*-"$3".hpkg' _ "$AIROS_PACKAGES/$ARCH" "$pkg" "$ARCH"
	"$TOOLS/package/package" create -q -C "$root" "$file"
	rm -f "$root/.PackageInfo"
	echo "package: $file"
}

# --- system packages under HaikuPorts' names ----------------------------------

# release_times: one time for every file of the source tree. A checkout leaves
# a release's generated files (configure, Makefile.in, aclocal.m4) in no
# particular order against their sources, and make would then regenerate them
# with autotools the release was not made with. Run on a clean tree.
release_times() {
	find . -path ./.git -prune -o -exec touch -h -d @1 {} +
}

# system_package DIR: package the tree DIR, which has its .PackageInfo, into
# the pool, as HaikuPorts' haikuporter packages it: mimeset --all gives every
# file its type and enters applications into the package's data/mime_db
# (against the Haiku build's MIME DB). zlib compression: the arm64 package
# readers have no zstd. Older versions of the package leave the pool.
system_package() {
	local dir=$1 name version file link
	name=$(sed -n 's/^name[[:space:]]*//p' "$dir/.PackageInfo")
	version=$(sed -n 's/^version[[:space:]]*//p' "$dir/.PackageInfo")
	[[ -n $name && -n $version ]] || die "$dir/.PackageInfo has no name or version"
	# The host tools keep a symbolic link's attributes under its inode number
	# (Linux has no user attributes on links), so a link removed earlier
	# leaves its attributes to the next link with that inode.
	while IFS= read -r -d '' link; do
		rm -rf "$ATTRS/symlink-$(stat -c %i "$link")"
	done < <(find "$dir" -type l -print0)
	mkdir -p "$dir/data/mime_db"
	(cd "$dir" && "$TOOLS/mimeset" --all --mimedb data/mime_db --mimedb "$MIMEDB" .)
	if [[ -z $(ls -A "$dir/data/mime_db") ]]; then
		rmdir "$dir/data/mime_db"
		rmdir "$dir/data" 2>/dev/null || true
	else
		find "$dir/data/mime_db" -mindepth 1 -maxdepth 1 -exec touch -h -d 2001-08-18 {} +
	fi
	file=$AIROS_PACKAGES/$ARCH/$name-$version-$ARCH.hpkg
	with_lock packages-$ARCH bash -c 'rm -f "$1"/"$2"-[0-9]*-"$3".hpkg' _ \
		"$AIROS_PACKAGES/$ARCH" "$name" "$ARCH"
	# The package's modes as HaikuPorts' (sshd refuses a group-writable
	# privilege separation directory); the work tree stays group-writable.
	chmod -R go-w "$dir"
	"$TOOLS/package/package" create -q -z zlib -C "$dir" "$file"
	chmod -R g+w "$dir"
	echo "package: $file"
}

build_recipe() {
	NAME=$1
	local recipe=$AIROS_CI/deps/recipes/$NAME.sh
	[[ -f $recipe ]] || die "no recipe $recipe"
	unset VERSION FORK SUMMARY COPYRIGHT LICENSE REQUIRES PKG_REVISION NO_PACKAGE STAMP_EXTRA \
		SOURCE_URL SOURCE_SHA256
	# The previous recipe's functions go too: an up-to-date recipe returns
	# before the unset below, and its fetch_source would check out its own
	# fork for the next recipe (rock5_ffmpeg's put FFmpeg in freetype's tree).
	unset -f build fetch_source
	FORK=$NAME
	. "$recipe"
	local dir=$WORKDIR/$NAME stamp
	stamp="$(fork_info "$FORK" commit 2>/dev/null || echo none) $(sha256sum "$recipe" | cut -c1-16) ${STAMP_EXTRA:-}"
	if [[ ${FORCE:-0} != 1 && -f $dir/stamp && $(cat "$dir/stamp") == "$stamp" ]]; then
		echo "== $NAME (up to date)"
		return
	fi
	note "$NAME $VERSION ($ARCH)"
	SRC=$dir/src STAGE=$dir/stage
	if declare -F fetch_source >/dev/null; then
		fetch_source
	else
		fork_checkout "$FORK" "$SRC"
	fi
	rm -rf "$STAGE"
	mkdir -p "$STAGE"
	# Not "( ... ) || die": bash ignores set -e inside a subshell that is
	# the left side of ||, and a failing step would go unnoticed.
	set +e
	( set -e; cd "$SRC"; build ) > "$dir/build.log" 2>&1
	local status=$?
	set -e
	[[ $status == 0 ]] || { tail -40 "$dir/build.log"; die "$NAME failed (log: $dir/build.log)"; }
	normalize_stage
	# Package contents can be read-only (HaikuPorts): keep both trees writable
	# so the next build can replace them.
	chmod -R u+rwX,g+rwX "$STAGE" "$DEPS" 2>/dev/null || true
	cp -a --no-preserve=mode "$STAGE$PREFIX/." "$DEPS/"
	chmod -R u+rwX,g+rwX "$DEPS" 2>/dev/null || true
	[[ ${NO_PACKAGE:-0} == 1 ]] || make_package
	echo "$stamp" > "$dir/stamp"
	unset -f build fetch_source
}

for recipe in "${RECIPES[@]}"; do
	build_recipe "$recipe"
done
note "deps for $ARCH in $DEPS"
