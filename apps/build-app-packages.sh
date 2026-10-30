#!/usr/bin/env bash
# build-app-packages.sh - cross-build the owner's applications into Haiku
# packages (.hpkg) for air/OS, for x86_64 or arm64 (AIROS_ARCH).
#
# Usage:
#   AIROS_ARCH=x86_64|arm64 APPS=DIR apps/build-app-packages.sh [OUTPUT_DIR] [APP ...]
#
#   OUTPUT_DIR  where the packages go (default $AIROS_PACKAGES/ARCH)
#   APP         any of: airshot clipper burrow kiri lcdmonitor amp turbochook
#               natter airtime airtop airpins airimager snap wordcraft gridcraft deckcraft
#               pdfcraft photocraft lightcraft aurora summit_webkit summit
#               summit_webkitlegacy proton_bridge airos_mail proton_vpn code_oss
#               github_desktop pgadmin4
#               docker compose docker_desktop (the Docker stack; their own CI
#               jobs, docker also builds the engine, containerd and buildx
#               from the pinned forks)
#               (default: all but airpins, airos_mail, code_oss, github_desktop,
#               pgadmin4, the Docker stack and Summit's three)
#   APPS        a directory with the application repositories under the names
#               airShot clipper burrow kiri lcdmonitor tasamp turbochook natter
#               airTime AirTop airpins airimager snap wordcraft gridcraft deckcraft pdfcraft
#               photocraft lightcraft aurora mail proton-bridge proton-vpn-airos-app
#               vscode desktop docker compose docker-desktop
#               (CI jobs link their checkout there),
#               and craft-fonts (storytold/craft-fonts), which LightCraft embeds
#
# It uses the air/OS cross SDK of that architecture (sdk/build-sdk.sh: cross
# compiler, sysroot, host rc/xres/resattr/mimeset/package, MIME DB) and the
# third-party prefix DEPS (deps/: arm64 libraries built from the airos-works
# forks, x86_64 HaikuPorts packages). Optional environment:
#   JOBS                  parallel compile jobs
#   APPBUILD              work tree: snapshots, objects, staging
#   NATTER_WEB_SIGNIN     auto|1|0: link Natter against the Summit engine
#                         (summit_webkit staged into DEPS) for Slack web sign-in
#   CRAFT_FONTS           the craft-fonts checkout (default $APPS/craft-fonts)
#
# For every application this:
#   1. snapshots the working tree of the repository (tracked files plus
#      untracked, non-ignored ones) into $APPBUILD/<app>/src; nothing is ever
#      written into the repositories;
#   2. cross-compiles it. The sysroot goes on CXX itself, because the
#      Makefiles link with $(CXX) and no flags. rc and xres are the host builds;
#      mimeset in the Makefiles is skipped;
#   3. stages the package exactly as the app's own tools/package-haiku.sh does
#      (documentation, licences, data files, post-install scripts, the
#      data/deskbar/menu/Applications symlink), strips, puts the resources back
#      with xres (GNU strip drops them), copies them into attributes with
#      `resattr -O` and runs the host mimeset --all with a staged data/mime_db;
#   4. retargets .PackageInfo to ARCH. x86_64 keeps its requires (HaikuPorts
#      provides them); arm64 cuts them down to `haiku >= r1~beta6`, because
#      arm64 has no repository for lib:/cmd: providers and an unresolvable
#      package is deactivated at boot (the images ship the libraries);
#   5. creates <name>-<version>-ARCH.hpkg in OUTPUT_DIR (older versions of the
#      same package there are removed), checks it with `package list` and
#      prints the non-base shared libraries the binaries need.
#
# Derived from the fork's tools/airos/build-arm64-app-packages.sh.
set -euo pipefail
umask 002

. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
. "$AIROS_CI/lib/sdk.sh"      # ARCH, CROSS, SYSROOT, TOOLS, MIMEDB, DEPS ... for $AIROS_ARCH
. "$AIROS_CI/lib/fork.sh"     # fork_checkout: third-party sources at pinned commits

OUT=${1:-$AIROS_PACKAGES/$ARCH}
[[ $# -gt 0 ]] && shift
SELECTED=("$@")

# APPS: a directory holding the application repositories under the names
# below (airShot clipper burrow kiri lcdmonitor tasamp turbochook natter
# airTime airpins wordcraft ...); CI jobs make one with a link to their checkout.
APPS=${APPS:?APPS must name the directory of application repositories}
CRAFT_FONTS=${CRAFT_FONTS:-$APPS/craft-fonts}
APPBUILD=${APPBUILD:-$AIROS_WORK/appbuild-$SDK_NAME}
# Third-party libraries (curl, OpenSSL, TagLib, SQLite, PCRE2, Scintilla,
# Lexilla, FFmpeg, the Summit engine): one prefix per architecture, made by
# deps/stage-deps.sh from the air/OS package pool (arm64: built from the
# airos-works forks; x86_64: HaikuPorts packages plus the forks HaikuPorts lacks).
EXTRA_DEPS=${EXTRA_DEPS:-$DEPS}
TLS_DEPS=${TLS_DEPS:-$DEPS}
SUMMIT_ENGINE=${SUMMIT_ENGINE:-$DEPS/lib/summit-webkit}
SUMMIT_WEBKIT_HEADERS=${SUMMIT_WEBKIT_HEADERS:-$DEPS/develop/headers/summit-webkit}
NATTER_WEB_SIGNIN=${NATTER_WEB_SIGNIN:-auto}
# Where the summit_webkit package installs the engine (lib/ holds libWebKit).
ENGINE_DIR=/boot/system/lib/summit-webkit

HOSTBIN=$APPBUILD/.hostbin
FARM=$APPBUILD/.deps
case $ARCH in
	arm64) CMAKE_PROCESSOR=aarch64 ;;
	x86_64) CMAKE_PROCESSOR=x86_64 ;;
esac
# The cross compiler links only libgcc.a, which carries a private copy of the
# unwinder: the program's frames are registered with that copy while
# libstdc++'s __cxa_throw unwinds with libgcc_s.so.1, finds no frames and calls
# std::terminate, so every C++ exception aborted. The SDK's specs file links
# libgcc_s ahead of libgcc.
CXX_T="${CROSS}g++ --sysroot=$SYSROOT -specs=$UNWIND_SPECS -L$FARM/lib -Wl,-rpath-link,$FARM/lib"
CC_T="${CROSS}gcc --sysroot=$SYSROOT -specs=$UNWIND_SPECS -L$FARM/lib -Wl,-rpath-link,$FARM/lib"
STRIP=${CROSS}strip

die() { echo "error: $*" >&2; exit 1; }
note() { printf '\n== %s\n' "$*"; }

check_prerequisites() {
	local required
	for required in "${CROSS}g++" "$TOOLS/rc/rc" "$TOOLS/xres" "$TOOLS/resattr/resattr" \
			"$TOOLS/mimeset" "$TOOLS/rm_attrs" "$TOOLS/package/package" "$MIMEDB" \
			"$SYSROOT/boot/system/develop/lib/libbe.so" "$DEPS"; do
		[[ -e $required ]] || die "missing $required"
	done
	command -v rsync >/dev/null || die "rsync is needed"
}

# rc and xres by name are the host builds; mimeset in the Makefiles is skipped
# (it writes attributes on build outputs, and staging does it properly).
setup_host_tools() {
	mkdir -p "$HOSTBIN"
	printf '#!/bin/sh\nexec "%s" "$@"\n' "$TOOLS/rc/rc" > "$HOSTBIN/rc"
	printf '#!/bin/sh\nexec "%s" "$@"\n' "$TOOLS/xres" > "$HOSTBIN/xres"
	printf '#!/bin/sh\nexit 0\n' > "$HOSTBIN/mimeset"
	chmod 755 "$HOSTBIN/rc" "$HOSTBIN/xres" "$HOSTBIN/mimeset"
	export PATH="$HOSTBIN:$PATH"
}

# One directory with exactly the third-party libraries and headers the apps
# may link, so it is unambiguous which arm64 file each -l resolves to.
setup_dependency_farm() {
	rm -rf "$FARM"
	mkdir -p "$FARM/lib" "$FARM/include"
	local lib header found dir
	# dev symlink name : soname pattern (first match in lib/ or develop/lib/)
	for lib in curl:libcurl.so.4 ssl:libssl.so.3 crypto:libcrypto.so.3 tag:libtag.so.2 \
			sqlite3:libsqlite3.so.0 pcre2-8:libpcre2-8.so.0 scintilla:libscintilla.so \
			lexilla:liblexilla.so avformat:libavformat.so.60 avcodec:libavcodec.so.60 \
			avfilter:libavfilter.so.9 avutil:libavutil.so.58 swscale:libswscale.so.7 \
			swresample:libswresample.so.4 lzo2:liblzo2.so.2 lz4:liblz4.so.1; do
		found=""
		for dir in "$EXTRA_DEPS/lib" "$EXTRA_DEPS/develop/lib" "$TLS_DEPS/lib"; do
			[[ -e $dir/${lib#*:} ]] && { found=$dir/${lib#*:}; break; }
		done
		[[ -n $found ]] && ln -sf "$found" "$FARM/lib/lib${lib%%:*}.so"
	done
	for header in curl openssl taglib sqlite3.h sqlite3ext.h pcre2.h scintilla lexilla \
			libavformat libavcodec libavfilter libavutil libswscale libswresample; do
		for dir in "$EXTRA_DEPS/develop/headers" "$EXTRA_DEPS/include" "$TLS_DEPS/include"; do
			[[ -e $dir/$header ]] && { ln -sfn "$dir/$header" "$FARM/include/$header"; break; }
		done
	done
	echo "dependency farm: $(ls "$FARM/lib" | tr '\n' ' ')"
}
FARM_CPATH() { echo "$FARM/include:$FARM/include/scintilla:$FARM/include/lexilla"; }

# snapshot <repo dir name> <work name>: sets SRC, BUILDDIR, STAGE.
snapshot() {
	local repo=$APPS/$1 work=$APPBUILD/$2
	[[ -d $repo ]] || die "no repository $repo"
	SRC=$work/src BUILDDIR=$work/build-$ARCH STAGE=$work/stage
	rm -rf "$SRC"
	mkdir -p "$SRC" "$BUILDDIR"
	if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$repo" ls-files -z --cached --others --exclude-standard \
			| rsync -a --from0 --files-from=- --ignore-missing-args "$repo/" "$SRC/"
		# --no-optional-locks: never touch the index others may be using.
		echo "snapshot of $repo at $(git -C "$repo" rev-parse --short HEAD)$(
			[[ -n $(git --no-optional-locks -C "$repo" status --porcelain) ]] \
				&& echo ' plus uncommitted changes')"
	else
		rsync -a --exclude='/build-*' --exclude='/artifacts' "$repo/" "$SRC/"
		echo "snapshot of $repo (not a git repository)"
	fi
	# Objects live outside the snapshot so rebuilds stay incremental.
	rm -rf "$SRC/build-$ARCH"
	ln -s "$BUILDDIR" "$SRC/build-$ARCH"
}

stage_begin() {
	[[ -e $STAGE ]] && "$TOOLS/rm_attrs" -rf "$STAGE"
	mkdir -p "$STAGE"
	# finish_package() drops attributes older than this (see there).
	touch "$STAGE.began"
	sleep 0.05
}

stage_end() {
	"$TOOLS/rm_attrs" -rf "$STAGE"
}

# install_binary <built binary> <rsrc or -> <path in package>
install_binary() {
	local dest=$STAGE/$3
	mkdir -p "$(dirname "$dest")"
	cp "$1" "$dest"
	chmod 755 "$dest"
	"$STRIP" --strip-debug "$dest"
	# GNU strip drops the appended Haiku resources; put them back.
	[[ $2 == - ]] || "$TOOLS/xres" -o "$dest" "$2"
}

# install_quick_look <built add-on> <name>: the app's preview for Tracker's
# Quick Look panel (quick_look_server loads add-ons/quick_look/*), as the
# app's own tools/package-haiku.sh stages it. An air/OS SDK has Quick Look,
# so there the add-on must have been built (without it the panel shows only
# file information); a Haiku release SDK has none and the package goes without.
install_quick_look() {
	if [[ ! -f $SYSROOT/boot/system/develop/headers/os/add-ons/quick_look/QuickLook.h ]]; then
		echo "note: no Quick Look in this SDK, $2 ships without its preview" >&2
		return
	fi
	[[ -f $1 ]] || die "no Quick Look add-on $1 (the Makefile did not find QuickLook.h)"
	install_binary "$1" - "add-ons/quick_look/$2"
}

# install_file <mode> <source> <path in package>
install_file() {
	mkdir -p "$(dirname "$STAGE/$3")"
	cp -R "$2" "$STAGE/$3"
	chmod "$1" "$STAGE/$3"
}

docs() { # docs <package name> <source paths relative to SRC>...
	local name=$1 path
	shift
	mkdir -p "$STAGE/documentation/packages/$name"
	for path in "$@"; do
		# Optional documents a branch may not have yet are skipped, not fatal.
		[[ -e $SRC/$path ]] || { echo "note: no $path in this revision" >&2; continue; }
		mkdir -p "$STAGE/documentation/packages/$name/$(dirname "$path")"
		cp -R "$SRC/$path" "$STAGE/documentation/packages/$name/$(dirname "$path")/"
	done
}

deskbar_link() { # deskbar_link <app path> <menu name> [folder]
	local folder=${3:-Applications}
	mkdir -p "$STAGE/data/deskbar/menu/$folder"
	ln -s "../../../../$1" "$STAGE/data/deskbar/menu/$folder/$2"
}

# Stale attributes: any attribute file of a staged node older than $1. The
# host tools keep a symlink's attributes as symlink-<inode> (Linux allows no
# user xattrs on symlinks), a file's under the id in its xattr, its inode.
purge_stale_attributes() {
	local marker=$1 entry dir
	while IFS= read -r -d '' entry; do
		dir=$ATTRS/$(stat -c %i "$entry")
		[[ -L $entry ]] && dir=$ATTRS/symlink-$(stat -c %i "$entry")
		[[ -d $dir ]] || continue
		find "$dir" -mindepth 1 ! -newer "$marker" -exec rm -rf {} +
	done < <(find "$STAGE" -print0)
}

# attribute_resources <rsrc> <output>: only the BEOS:* resources (signature,
# flags, icon, version, supported types). resattr copies every resource, and an
# app's own data (Amp's MiniDisc PNGs) does not belong in its attributes.
attribute_resources() {
	local type id
	cp "$1" "$2.in"
	while IFS=$'\t' read -r type id; do
		"$TOOLS/xres" -o "$2.out" -d "$type:$id" "$2.in"
		mv "$2.out" "$2.in"
	done < <("$TOOLS/xres" -l "$1" | awk '
		/^'"'"'/ {
			type = substr($0, 2, 4); split(substr($0, 7), f, " ")
			name = substr($0, 7); sub(/^ *[^ ]+ +[^ ]+ +/, "", name)
			if (name !~ /^BEOS:/) print type "\t" f[1]
		}')
	mv "$2.in" "$2"
}

# add_attributes <rsrc> <app path in package>...: resattr + mimeset for the
# applications in the stage, as mimeset does on Haiku.
add_attributes() {
	local marker=$APPBUILD/.attr-marker
	touch "$marker"
	sleep 0.05
	purge_stale_attributes "$marker"
	resource_attributes "$@"
	purge_stale_attributes "$marker"
}

# resource_attributes <rsrc> <path in package>...: the same for a second
# binary with resources of its own, after add_attributes (whose purge would
# drop the attributes an earlier call gave the first).
resource_attributes() {
	local rsrc=$APPBUILD/.attributes.rsrc
	attribute_resources "$1" "$rsrc"
	shift
	local app
	for app in "$@"; do
		"$TOOLS/resattr/resattr" -O -o "$STAGE/$app" "$rsrc"
	done
	( cd "$STAGE" && "$TOOLS/mimeset" --all -f --mimedb data/mime_db --mimedb "$MIMEDB" "$@" )
}

# retarget_package_info <source> <destination> [<regex of requires to keep>]
retarget_package_info() {
	local dropped=$APPBUILD/.dropped
	: > "$dropped"
	if [[ $ARCH != arm64 ]]; then
		sed "s/^architecture[ \t].*/architecture $ARCH/" "$1" > "$2"
		DROPPED="(none: $ARCH keeps its requires)"
		return
	fi
	awk -v keep="${3:-}" -v dropped="$dropped" '
		/^architecture[ \t]/   { print "architecture arm64"; next }
		/^requires[ \t]*\{/    { print; print "\thaiku >= r1~beta6"; inreq = 1; next }
		inreq && /^[ \t]*\}/   { print; inreq = 0; next }
		inreq {
			line = $0
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			if (line == "") next
			if (keep != "" && line ~ keep) { print "\t" line; next }
			if (line !~ /^haiku([ \t<>=]|$)/) print line > dropped
			next
		}
		{ print }
	' "$1" > "$2"
	DROPPED=$(paste -sd ',' "$dropped" | sed 's/,/, /g')
	[[ -n $DROPPED ]] || DROPPED="(none)"
}

info_field() { awk -v k="$1" '$1 == k { print $2; exit }' "$2"; }

# Non-base shared libraries of a staged binary and the file each was linked
# against (base = anything in the sysroot's system/lib or develop/lib).
soname() {
	local name
	name=$(readelf -d "$1" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
	echo "${name:-$(basename "$1")}"
}

needed_libraries() {
	local binary=$1 needed path lib
	for needed in $(readelf -d "$binary" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
		[[ -e $SYSROOT/boot/system/lib/$needed || -e $SYSROOT/boot/system/develop/lib/$needed ]] \
			&& continue
		# The farm entry with that soname is what -l linked; else the engine.
		path=""
		for lib in "$FARM"/lib/*.so; do
			[[ $(soname "$lib") == "$needed" ]] && { path=$(readlink -f "$lib"); break; }
		done
		[[ -z $path && -e $SUMMIT_ENGINE/lib/$needed ]] \
			&& path="$(readlink -f "$SUMMIT_ENGINE/lib/$needed") (Summit engine)"
		[[ -z $path && -e ${SUMMIT_ENGINE_BUILD:-/nonexistent}/lib/$needed ]] \
			&& path="$(readlink -f "$SUMMIT_ENGINE_BUILD/lib/$needed") (Summit engine build)"
		printf '    %-20s %s\n' "$needed" "${path:-NOT FOUND}"
		# What libcurl itself pulls in.
		if [[ $needed == libcurl.so.4 && -n $path ]]; then
			for needed in $(readelf -d "$path" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
				[[ -e $SYSROOT/boot/system/lib/$needed ]] && continue
				printf '    %-20s %s (needed by libcurl)\n' "$needed" "$(readlink -f "$TLS_DEPS/lib/$needed")"
			done
		fi
	done
}

# finish_package <package name> <binaries in package for the library report>...
finish_package() {
	local name=$1 version file
	shift
	version=$(info_field version "$STAGE/.PackageInfo")
	file=$OUT/$name-$version-$ARCH.hpkg
	mkdir -p "$OUT"
	rm -f "$OUT/$name"-[0-9]*-"$ARCH".hpkg
	# The host tools keep attributes in $ATTRS by inode, and a file removed
	# elsewhere without rm_attrs leaves its entry for the next file that gets
	# the inode: summit_webkit's libraries came out with BEOS:TYPE on
	# 2026-10-14 and verify_package refused the package. What staging added
	# (resattr, mimeset) is newer than the stage.
	[[ ! -e $STAGE.began ]] || purge_stale_attributes "$STAGE.began"
	"$TOOLS/package/package" create -q -C "$STAGE" "$file"
	verify_package "$file"
	echo "package:  $file"
	echo "version:  $version"
	echo "dropped:  $DROPPED"
	echo "libraries outside the base system:"
	local binary report=""
	for binary in "$@"; do
		# Optional binaries (a Quick Look add-on) may not be staged.
		[[ -e $STAGE/$binary ]] || continue
		report+=$(needed_libraries "$STAGE/$binary")$'\n'
	done
	report=$(printf '%s' "$report" | sed '/^$/d' | awk '!seen[$1]++' | sort)
	echo "${report:-    (none)}"
	printf '%s\t%s\t%s\t%s\n' "$name" "$file" "$version" "$DROPPED" >> "$APPBUILD/.summary"
	stage_end
}

# The package must be arm64, and attributes may only sit on applications,
# add-ons and MIME DB entries (anything else would be stale host state).
# APP_PATHS: a pattern for applications and add-ons a package keeps
# elsewhere (Aurora's in data/aurora).
APP_PATHS='^(apps|add-ons)/'
verify_package() {
	local file=$1 tool=$TOOLS/package/package
	"$tool" list -i "$file" | grep -q "^[[:space:]]*architecture: $ARCH\$" \
		|| die "$file is not $ARCH"
	"$tool" list -a "$file" | awk -v file="$file" -v apps="$APP_PATHS" '
		/^[ \t]*</ {
			attr = $0; sub(/^[ \t]*</, "", attr); sub(/[ \t].*/, "", attr)
			ok = (path ~ apps && attr ~ /^BEOS:/) \
				|| (path ~ /^data\/mime_db\// && attr ~ /^META:/)
			if (!ok) { print "unexpected attribute " attr " on " path " in " file > "/dev/stderr"; bad = 1 }
			next
		}
		/^[ \t]*[^ \t]/ && started {
			match($0, /^ */); depth = RLENGTH / 2
			entry = substr($0, RLENGTH + 1); sub(/[ \t][ \t]+.*/, "", entry)
			stack[depth] = entry; path = stack[0]
			for (i = 1; i <= depth; i++) path = path "/" stack[i]
			next
		}
		/^[^ \t]/ { started = 1; match($0, /^ */); stack[0] = $1; path = $1 }
		END { exit bad }
	' || die "$file carries unexpected attributes"
}

wanted() {
	[[ ${#SELECTED[@]} -eq 0 ]] && return 0
	local app
	for app in "${SELECTED[@]}"; do [[ ${app,,} == "$1" ]] && return 0; done
	return 1
}

# --- airShot ----------------------------------------------------------------
build_airshot() {
	note airShot
	snapshot airShot airshot
	local private=$SYSROOT/boot/system/develop/headers/private
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		APP_CPPFLAGS="-I$private/interface -I$private/shared -I$private/app" \
		FILTER_CPPFLAGS="-I$private/storage" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true all
	stage_begin
	install_binary "$BUILDDIR/airShot" "$BUILDDIR/airShot.rsrc" apps/airShot
	install_binary "$BUILDDIR/airShot_filter" - add-ons/input_server/filters/airShot
	docs airshot README.md LICENSE docs
	# The Font Awesome tool icons (working tree since 0.1.0~beta-2).
	if [[ -d $SRC/resources/icons ]]; then
		cp -R "$SRC/resources/icons" "$STAGE/documentation/packages/airshot/"
		install_file 644 "$SRC/resources/icons/fontawesome/CC-BY-4.0.txt" "data/licenses/CC BY 4.0"
	fi
	deskbar_link apps/airShot airShot
	retarget_package_info "$SRC/resources/airShot.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/airShot.rsrc" apps/airShot
	finish_package airshot apps/airShot add-ons/input_server/filters/airShot
}

# --- Snap -------------------------------------------------------------------
# The photo booth demo (airos-works/snap): one application, in demos/ with a link
# in Deskbar's Demos menu like GLTeapot; its GLSL shaders are resources of the
# application. It links libGL: the x86_64 SDK has it (Mesa's BGLView), arm64
# takes libglvnd's (BGLView over EGL) from the GL stack deps/build-gl.sh builds.
build_snap() {
	note Snap
	snapshot snap snap
	local gl=""
	if [[ ! -e $SYSROOT/boot/system/develop/lib/libGL.so ]]; then
		local glvnd=$AIROS_WORK/gl/glvnd-install/boot/system
		[[ -e $glvnd/lib/libGL.so ]] || die "no libGL for $ARCH (deps/build-gl.sh builds it)"
		local headers=$glvnd/develop/headers/os/opengl
		gl="-I$headers -I$headers/opengl -L$glvnd/lib -Wl,-rpath-link,$glvnd/lib"
	fi
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T $gl" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true all
	stage_begin
	install_binary "$BUILDDIR/Snap" "$BUILDDIR/Snap.rsrc" demos/Snap
	docs snap README.md LICENSE docs
	deskbar_link demos/Snap Snap Demos
	retarget_package_info "$SRC/resources/Snap.PackageInfo" "$STAGE/.PackageInfo"
	# An application outside apps/ (verify_package).
	local APP_PATHS='^(apps|add-ons|demos)/'
	add_attributes "$BUILDDIR/Snap.rsrc" demos/Snap
	finish_package snap demos/Snap
}

# --- Clipper ----------------------------------------------------------------
# The clipboard manager: the application and its two input_server add-ons
# (global shortcuts, paste injection), staged as its tools/package-haiku.sh
# does.
build_clipper() {
	note Clipper
	snapshot clipper clipper
	local private=$SYSROOT/boot/system/develop/headers/private
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		APP_CPPFLAGS="-I$private/interface" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true all
	stage_begin
	install_binary "$BUILDDIR/Clipper" "$BUILDDIR/Clipper.rsrc" apps/Clipper
	install_binary "$BUILDDIR/Clipper_filter" - add-ons/input_server/filters/Clipper_shortcuts
	install_binary "$BUILDDIR/Clipper_device" - add-ons/input_server/devices/Clipper_paste
	docs clipper README.md LICENSE docs
	install_file 644 "$SRC/LICENSE" data/licenses/MIT
	deskbar_link apps/Clipper Clipper Office
	# its requires list is on one line; the retargeting reads one per line
	sed 's/^requires { *\(.*\) *}$/requires {\n\t\1\n}/' \
		"$SRC/resources/Clipper.PackageInfo" > "$BUILDDIR/Clipper.PackageInfo"
	retarget_package_info "$BUILDDIR/Clipper.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/Clipper.rsrc" apps/Clipper
	finish_package clipper apps/Clipper add-ons/input_server/filters/Clipper_shortcuts \
		add-ons/input_server/devices/Clipper_paste
}

# --- AirTop -----------------------------------------------------------------
# The system monitor (airos-works/airtop). It shows its graphs on an auxiliary
# display too (BAuxDisplay, libdevice), which the SDK's sysroot carries.
build_airtop() {
	note AirTop
	snapshot AirTop airtop
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true all
	stage_begin
	install_binary "$BUILDDIR/AirTop" "$BUILDDIR/AirTop.rsrc" apps/AirTop/AirTop
	docs airtop README.md LICENSE docs
	install_file 644 "$SRC/LICENSE" data/licenses/MIT
	deskbar_link apps/AirTop/AirTop AirTop
	retarget_package_info "$SRC/resources/AirTop.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/AirTop.rsrc" apps/AirTop/AirTop
	finish_package airtop apps/AirTop/AirTop
}

# --- airImager --------------------------------------------------------------
# The image writer (airos-works/airimager): writes the airos.works images to
# USB sticks and SD cards. In the Deskbar menu's Utilities folder, staged as
# its tools/package-haiku.sh does; XZ Embedded is compiled in, and the disk
# device API's private headers come from the SDK's sysroot.
build_airimager() {
	note airImager
	snapshot airimager airimager
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true all
	stage_begin
	install_binary "$BUILDDIR/airImager" "$BUILDDIR/airImager.rsrc" apps/airImager
	docs airimager README.md LICENSE docs
	install_file 644 "$SRC/third_party/xz-embedded/COPYING" \
		documentation/packages/airimager/xz-embedded-COPYING
	install_file 644 "$SRC/LICENSE" data/licenses/MIT
	deskbar_link apps/airImager airImager Utilities
	retarget_package_info "$SRC/resources/airImager.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/airImager.rsrc" apps/airImager
	finish_package airimager apps/airImager
}

# --- AirPins ----------------------------------------------------------------
# The Raspberry Pi's GPIO tool (a native version of pigg). It talks to the
# rpi_gpio driver of the rpi4 image and simulates the pins anywhere else, so
# it goes into the Raspberry Pi 4 packages (/mnt/HaikuWork/rpi4/packages-arm64).
build_airpins() {
	note AirPins
	snapshot airpins airpins
	local private=$SYSROOT/boot/system/develop/headers/private
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		APP_CPPFLAGS="-I$private/interface -I$private/shared" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true all
	stage_begin
	install_binary "$BUILDDIR/AirPins" "$BUILDDIR/AirPins.rsrc" apps/AirPins
	docs airpins README.md LICENSE third_party/pigg/LICENSE \
		resources/icons/README.md resources/icons/fontawesome/LICENSE.txt \
		resources/icons/fontawesome/CC-BY-4.0.txt
	deskbar_link apps/AirPins AirPins
	retarget_package_info "$SRC/resources/AirPins.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/AirPins.rsrc" apps/AirPins
	finish_package airpins apps/AirPins
}

# --- Burrow -----------------------------------------------------------------
# burrow-openvpn is OpenVPN 2.6.13 with Burrow's patches, from the
# airos-works/openvpn fork (branch burrow-2.6.13). arm64: OpenSSL linked
# statically, LZO/LZ4 left out (AWS Client VPN uses neither), so only Haiku is
# required. x86_64: linked against the HaikuPorts OpenSSL 3, LZO and LZ4 that
# Burrow's package requires, as the native build is.
build_burrow() {
	note Burrow
	snapshot burrow burrow
	local ovpn=$APPBUILD/burrow/openvpn-src
	fork_checkout openvpn "$ovpn"
	( cd "$ovpn" && autoreconf -fi >/dev/null 2>&1 )
	local ssl_libs features=()
	if [[ $ARCH == arm64 ]]; then
		ssl_libs="$DEPS/develop/lib/libssl.a $DEPS/develop/lib/libcrypto.a"
		features=(--disable-lzo --disable-lz4)
	else
		ssl_libs="-L$FARM/lib -lssl -lcrypto"
		# OpenVPN's configure takes explicit LZO/LZ4 flags as "enabled", so
		# they are only given when the libraries are wanted.
		features=(--enable-lzo --enable-lz4
			LZO_CFLAGS="-I$DEPS/develop/headers" LZO_LIBS="-L$FARM/lib -llzo2"
			LZ4_CFLAGS="-I$DEPS/develop/headers" LZ4_LIBS="-L$FARM/lib -llz4")
	fi
	# The host's ifconfig and route must not leak into the paths OpenVPN runs.
	( cd "$ovpn" && ./configure -q --host="$TRIPLET" --build=x86_64-pc-linux-gnu \
		CC="$CC_T" CPPFLAGS="-I$FARM/include -I$DEPS/develop/headers" \
		OPENSSL_CFLAGS="-I$FARM/include" OPENSSL_LIBS="$ssl_libs" \
		LDFLAGS="-lnetwork -L$DEPS/develop/lib -Wl,-rpath-link,$DEPS/lib" \
		IFCONFIG=/boot/system/bin/ifconfig ROUTE=/boot/system/bin/route \
		NETSTAT=/boot/system/bin/netstat IPROUTE=/bin/false \
		"${features[@]}" --disable-plugins --disable-pkcs11 --disable-debug --disable-unit-tests >/dev/null )
	make -C "$ovpn" -s -j"$JOBS" >/dev/null
	cp "$ovpn/src/openvpn/openvpn" "$BUILDDIR/burrow-openvpn"

	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH TARGET_OS=Haiku CXX="$CXX_T" objects
	( cd "$SRC" && $CXX_T -o "$BUILDDIR/Burrow" "$BUILDDIR"/src/core/*.o "$BUILDDIR"/src/ui/*.o \
		"$BUILDDIR/src/main.o" -lbe -ltracker -lnetwork -Wl,--export-dynamic )
	( cd "$SRC" && "$TOOLS/rc/rc" -I resources -o "$BUILDDIR/Burrow.rsrc" resources/Burrow.rdef )

	stage_begin
	install_binary "$BUILDDIR/Burrow" "$BUILDDIR/Burrow.rsrc" apps/Burrow
	install_binary "$BUILDDIR/burrow-openvpn" - bin/burrow-openvpn
	docs burrow README.md LICENSE docs
	# OpenVPN is GPL 2: say where burrow-openvpn's source is, next to the binary.
	mkdir -p "$STAGE/documentation/packages/burrow/openvpn"
	cp -R "$SRC/openvpn/patches" "$SRC/openvpn/SOURCE.md" "$STAGE/documentation/packages/burrow/openvpn/"
	printf 'burrow-openvpn was built from %s at %s (branch %s): OpenVPN %s with the patches in this directory.\n' \
		"$(fork_info openvpn url)" "$FORK_COMMIT" "$(fork_info openvpn branch)" "$(fork_info openvpn base)" \
		> "$STAGE/documentation/packages/burrow/openvpn/SOURCE-air-OS-CI.txt"
	deskbar_link apps/Burrow Burrow
	retarget_package_info "$SRC/resources/Burrow.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/Burrow.rsrc" apps/Burrow
	finish_package burrow apps/Burrow bin/burrow-openvpn
}

# --- airTime -------------------------------------------------------------------
# The movie player, linked against FFmpeg 6: on arm64 the rock5_ffmpeg build
# (airos-works/ffmpeg + MPP), which provides no lib: entries, so the package
# requires rock5_ffmpeg; on x86_64 HaikuPorts' ffmpeg6.
build_airtime() {
	note airTime
	snapshot airTime airtime
	local headers=$SYSROOT/boot/system/develop/headers
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		HAIKU_HEADERS="$headers" FFMPEG_CFLAGS="-I$FARM/include -I$DEPS/develop/headers" \
		FFMPEG_LDFLAGS="-L$FARM/lib -Wl,-rpath-link,$DEPS/lib" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true
	stage_begin
	install_binary "$BUILDDIR/airTime" "$BUILDDIR/airTime.rsrc" apps/airTime
	install_quick_look "$BUILDDIR/airTime_quicklook" airTime
	install_file 755 "$SRC/resources/scripts/airtime-register-default.sh" \
		boot/post-install/airtime-register-default.sh
	docs airtime README.md LICENSE
	deskbar_link apps/airTime airTime
	if [[ $ARCH == arm64 ]]; then
		awk '/^requires[ \t]*\{/ { print; print "\trock5_ffmpeg >= 6.1.6"; next } { print }' \
			"$SRC/resources/airTime.PackageInfo" > "$BUILDDIR/airTime.PackageInfo"
		retarget_package_info "$BUILDDIR/airTime.PackageInfo" "$STAGE/.PackageInfo" '^rock5_ffmpeg'
	else
		retarget_package_info "$SRC/resources/airTime.PackageInfo" "$STAGE/.PackageInfo"
	fi
	add_attributes "$BUILDDIR/airTime.rsrc" apps/airTime
	finish_package airtime apps/airTime add-ons/quick_look/airTime
}

# --- Kiri -------------------------------------------------------------------
build_kiri() {
	note Kiri
	snapshot kiri kiri
	CPATH=$(FARM_CPATH) make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH \
		CXX="$CXX_T" CC="$CC_T" all
	stage_begin
	install_binary "$BUILDDIR/Kiri" "$BUILDDIR/Kiri.rsrc" apps/Kiri
	docs kiri README.md LICENSE docs vendor/libvterm/LICENSE vendor/libvterm/UPSTREAM.md \
		vendor/nlohmann/LICENSE.MIT vendor/nlohmann/UPSTREAM.md \
		vendor/md4c/LICENSE.md vendor/md4c/UPSTREAM.md tools/install-language-tools.sh
	install_file 755 "$SRC/resources/kiri-post-install.sh" boot/post-install/kiri.sh
	deskbar_link apps/Kiri Kiri
	retarget_package_info "$SRC/resources/Kiri.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/Kiri.rsrc" apps/Kiri
	finish_package kiri apps/Kiri
}

# --- LCDMonitor -------------------------------------------------------------
# No .PackageInfo, README or LICENSE in the tree; the package info below is
# made from resources/LCDMonitor.rdef (signature, version 0.1.0 development).
build_lcdmonitor() {
	note LCDMonitor
	snapshot lcdmonitor lcdmonitor
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		HOST_TOOLS="$TOOLS/" RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" all
	stage_begin
	install_binary "$BUILDDIR/LCDMonitor" "$BUILDDIR/LCDMonitor.rsrc" apps/LCDMonitor
	mkdir -p "$STAGE/documentation/packages/lcdmonitor"
	head -n 20 "$SRC/vendor/stb/stb_image_write.h" > "$STAGE/documentation/packages/lcdmonitor/stb_image_write-header.txt"
	deskbar_link apps/LCDMonitor LCDMonitor
	cat > "$APPBUILD/lcdmonitor/LCDMonitor.PackageInfo" <<'INFO'
name lcdmonitor
version 0.1.0~dev-1
architecture x86_64
summary "System monitor for the Thermalright Trofeo Vision 9.16 USB LCD"
description "LCDMonitor draws a system monitor (clock, uptime, CPU, memory and network graphs) on the Thermalright Trofeo Vision 9.16 USB LCD (USB 0416:5408) once a second. It runs in the background, talks to the panel through the USB Kit (no kernel driver) and reconnects when the panel comes back. Frames are sent rotated 180 degrees; rotate=0 in ~/config/settings/LCDMonitor turns that off. To start it at login, link /boot/system/apps/LCDMonitor into ~/config/settings/boot/launch."
packager "air/OS contributors"
vendor "air/OS"
copyrights { "2026 air/OS contributors" "2010-2015 Sean Barrett (stb_image_write, public domain)" }
licenses { "MIT" }
provides {
	lcdmonitor = 0.1.0~dev
	app:LCDMonitor = 0.1.0~dev
}
requires {
	haiku >= r1~beta6
}
INFO
	retarget_package_info "$APPBUILD/lcdmonitor/LCDMonitor.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/LCDMonitor.rsrc" apps/LCDMonitor
	finish_package lcdmonitor apps/LCDMonitor
}

# --- Amp (apps/tasamp) --------------------------------------------------------
build_amp() {
	note Amp
	snapshot tasamp amp
	# HAIKU_HEADERS: the Makefile builds the Quick Look add-on only when it
	# finds QuickLook.h there (its default is the build machine's /boot).
	CPATH=$(FARM_CPATH) make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		HAIKU_HEADERS="$SYSROOT/boot/system/develop/headers" all
	stage_begin
	install_binary "$BUILDDIR/Amp" "$BUILDDIR/Amp.rsrc" apps/Amp
	install_quick_look "$BUILDDIR/Amp_quicklook" Amp
	docs amp README.md LICENSE docs vendor/nlohmann/LICENSE.MIT vendor/nlohmann/UPSTREAM.md \
		vendor/fontawesome/LICENSE.txt vendor/fontawesome/UPSTREAM.md
	# each licence named in .PackageInfo needs its text inside the package
	install_file 644 "$SRC/vendor/fontawesome/SIL-OFL-1.1.txt" "data/licenses/SIL OFL 1.1"
	install_file 644 "$SRC/vendor/fontawesome/CC-BY-4.0.txt" "data/licenses/CC BY 4.0"
	# icons::Init() reads the Font Awesome face from B_SYSTEM_DATA_DIRECTORY/Amp.
	install_file 644 "$SRC/vendor/fontawesome/FontAwesome6Free-Solid-900.otf" \
		data/Amp/FontAwesome6Free-Solid-900.otf
	install_file 755 "$SRC/resources/amp-post-install.sh" boot/post-install/amp.sh
	deskbar_link apps/Amp Amp
	retarget_package_info "$SRC/resources/Amp.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/Amp.rsrc" apps/Amp
	finish_package amp apps/Amp add-ons/quick_look/Amp
}

# --- Turbo Chook ----------------------------------------------------------------
build_turbochook() {
	note TurboChook
	snapshot turbochook turbochook
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" CC="$CC_T" all
	stage_begin
	install_binary "$BUILDDIR/TurboChook" "$BUILDDIR/TurboChook.rsrc" apps/TurboChook
	docs turbochook README.md LICENSE docs vendor/nlohmann/LICENSE.MIT vendor/nlohmann/UPSTREAM.md
	install_file 755 "$SRC/resources/turbochook-post-install.sh" boot/post-install/turbochook.sh
	deskbar_link apps/TurboChook TurboChook
	retarget_package_info "$SRC/resources/TurboChook.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/TurboChook.rsrc" apps/TurboChook
	finish_package turbochook apps/TurboChook
}

# --- Natter ---------------------------------------------------------------------
# The Summit engine as the summit_webkit package installs it (staged into DEPS
# by the Summit pipeline): libWebKit in lib/, the public API headers.
engine_ready() {
	[[ -e $SUMMIT_ENGINE/lib/libWebKit.so && -d $SUMMIT_WEBKIT_HEADERS ]]
}

build_natter() {
	note Natter
	local web=0
	case $NATTER_WEB_SIGNIN in
		1) engine_ready || die "no Summit engine in $SUMMIT_ENGINE (summit_webkit not staged)"; web=1 ;;
		auto) if engine_ready; then web=1; else
			echo "note: no Summit engine staged; Natter is built without web sign-in" >&2
		fi ;;
		0) ;;
		*) die "NATTER_WEB_SIGNIN must be auto, 1 or 0" ;;
	esac
	snapshot natter natter
	local work=$APPBUILD/natter engine=$APPBUILD/natter/engine
	cat > "$work/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR $CMAKE_PROCESSOR)
set(CMAKE_SYSROOT $SYSROOT)
set(CMAKE_C_COMPILER ${CROSS}gcc)
set(CMAKE_CXX_COMPILER ${CROSS}g++)
set(CMAKE_EXE_LINKER_FLAGS_INIT -specs=$UNWIND_SPECS)
set(CMAKE_SHARED_LINKER_FLAGS_INIT -specs=$UNWIND_SPECS)
set(CMAKE_FIND_ROOT_PATH $SYSROOT/boot/system $SYSROOT/boot/system/develop)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
	local rpath_link="-Wl,-rpath-link,$TLS_DEPS/lib -Wl,-rpath-link,$SYSROOT/boot/system/lib"
	local args=(-DNATTER_WEBKIT=)
	# The package runs the build-tree binary, so set its RPATH by hand: CMake
	# would otherwise add the host directories of the libraries it linked.
	local rpath=""
	if [[ $web == 1 ]]; then
		# The engine's public headers, laid out as an installed engine has them
		# (the same set Summit's own arm64 build-app.sh uses).
		rm -rf "$engine"
		mkdir -p "$engine/include/WebKit"
		local header
		for header in UIProcess/API/haiku/WebKitView.h UIProcess/API/haiku/WebKitContext.h \
				UIProcess/API/haiku/WebKitEmbedding.h UIProcess/API/haiku/WebKitExtensionPermission.h \
				UIProcess/API/haiku/WebKitInfo.h Shared/API/c/WKBase.h \
				Shared/API/c/WKDeclarationSpecifiers.h Shared/API/c/haiku/WKBaseHaiku.h; do
			cp "$(find "$SUMMIT_WEBKIT_HEADERS" -name "$(basename "$header")" | head -n 1)" \
				"$engine/include/WebKit/"
		done
		ln -s "$SUMMIT_ENGINE/lib" "$engine/lib"
		args=(-DNATTER_WEBKIT="$engine")
		rpath_link+=" -Wl,-rpath-link,$SUMMIT_ENGINE/lib"
		# lib/ is the summit_webkit package layout; the flat directory is a fallback.
		rpath="-Wl,-rpath,$ENGINE_DIR/lib:$ENGINE_DIR:/boot/home/config/non-packaged/lib/summit-webkit/lib"
	fi
	# Configure afresh: CMake keeps cached values from the other variant.
	rm -rf "$BUILDDIR"
	mkdir -p "$BUILDDIR"
	# No host curl or OpenSSL: no package configs, no host pkg-config files.
	mkdir -p "$work/no-pkgconfig"
	PKG_CONFIG_LIBDIR=$work/no-pkgconfig PKG_CONFIG_PATH= \
	cmake -S "$SRC" -B "$BUILDDIR" -DCMAKE_TOOLCHAIN_FILE="$work/toolchain.cmake" \
		-DCURL_NO_CURL_CMAKE=ON \
		-DCMAKE_BUILD_TYPE=Release -DNATTER_BUILD_TESTS=OFF -DNATTER_BUILD_CLI=OFF \
		-DCMAKE_SKIP_BUILD_RPATH=ON -DCMAKE_EXE_LINKER_FLAGS="$rpath_link $rpath" \
		-DCURL_INCLUDE_DIR="$FARM/include" -DCURL_LIBRARY="$FARM/lib/libcurl.so" \
		-DOPENSSL_INCLUDE_DIR="$FARM/include" -DOPENSSL_SSL_LIBRARY="$FARM/lib/libssl.so" \
		-DOPENSSL_CRYPTO_LIBRARY="$FARM/lib/libcrypto.so" "${args[@]}" >/dev/null
	cmake --build "$BUILDDIR" --target Natter -j"$JOBS" >/dev/null

	stage_begin
	install_binary "$BUILDDIR/Natter" "$BUILDDIR/Natter.rsrc" apps/Natter/Natter
	deskbar_link apps/Natter/Natter Natter
	docs natter README.md LICENSE
	# The package info is the heredoc of the app's own tools/package-haiku.sh.
	local version webkit_require=""
	version=$(sed -n 's/^project(natter VERSION \([0-9.]*\).*/\1/p' "$SRC/CMakeLists.txt")
	[[ $web == 1 ]] && webkit_require="	summit_webkit >= 1.10.0"
	sed -n '/^cat > "\$STAGE\/.PackageInfo" <<INFO$/,/^INFO$/p' "$SRC/tools/package-haiku.sh" \
		| sed '1d;$d' > "$work/PackageInfo.template"
	[[ -s $work/PackageInfo.template ]] || die "no package info in natter's tools/package-haiku.sh"
	VERSION=$version ARCH=x86_64 WEBKIT=$webkit_require \
		bash -c 'eval "cat <<INFO
$(cat "$1")
INFO"' _ "$work/PackageInfo.template" > "$work/Natter.PackageInfo"
	retarget_package_info "$work/Natter.PackageInfo" "$STAGE/.PackageInfo" '^summit_webkit'
	add_attributes "$BUILDDIR/Natter.rsrc" apps/Natter/Natter
	echo "web sign-in: $([[ $web == 1 ]] && echo "yes (engine from $ENGINE_DIR/lib)" || echo no)"
	echo "RPATH: $(readelf -d "$STAGE/apps/Natter/Natter" | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p')"
	finish_package natter apps/Natter/Natter
}


# --- Summit and its engine ------------------------------------------------------
# Built by the Summit pipeline (summit/build-summit.sh) from a Summit checkout
# in APPS/summit and the engine summit/build-engine.sh built from it, so the
# browser and the engine always match:
#   summit_webkit  the engine in /boot/system/lib/summit-webkit (WebProcess and
#                  NetworkProcess, lib/ with libWebKit, JavaScriptCore and the
#                  libraries of summit/build-deps.sh), the public headers in
#                  develop/headers/summit-webkit
#   summit         the browser, the system's default web browser
#   summit_webkitlegacy
#                  HaikuWebKit's BWebView API (WebPositive's) on the engine, in
#                  place of HaikuPorts' haikuwebkit (below)
# With AIROS_TARGET=r1beta6 (lib/sdk.sh: SDK_NAME x86_64-r1beta6) both are for
# a stock Haiku R1/beta6 installation instead: built against that release,
# the browser without what only air/OS's app_server takes (SUMMIT_AIROS=0),
# requiring what HaikuPorts has to add to the release, and without making
# Summit the default browser at installation.
SUMMIT_ENGINE_BUILD=${SUMMIT_ENGINE_BUILD:-$AIROS_BUILD/webkit-$SDK_NAME}
SUMMIT_LIBS=${SUMMIT_LIBS:-$AIROS_ROOT/summit/$SDK_NAME/deps}
SUMMIT_WEBKIT_SRC=${SUMMIT_WEBKIT_SRC:-$AIROS_SRC/webkit-$SDK_NAME/Source/WebKit}
# What the image's GL stack provides (deps/build-gl.sh), as Haiku's own
# libraries are: not bundled. x86_64 has no system EGL: the package carries
# a private Mesa (deps/build-gl-x86_64.sh) in mesa/, which the engine points
# its processes at.
GL_SYSTEM=$AIROS_ROOT/gl/$SDK_NAME/boot/system
SUMMIT_MESA=$AIROS_ROOT/gl/$SDK_NAME-mesa
# x86_64: the image's libraries the engine links rather than carries
# (summit/lib.sh SYSLIBS), and the packages they come from, whose provides
# become the engine's requirements.
if [[ $ARCH != x86_64 ]]; then
	SUMMIT_SYSLIBS=
	SUMMIT_SYSLIBS_PACKAGES=
elif [[ $SDK_NAME == "$ARCH" ]]; then
	SUMMIT_SYSLIBS=$AIROS_ROOT/summit/$SDK_NAME/system/boot/system
	SUMMIT_SYSLIBS_PACKAGES=$SUMMIT_SYSLIBS/packages
else
	SUMMIT_SYSLIBS=$SYSROOT/boot/system
	SUMMIT_SYSLIBS_PACKAGES=$HAIKU_PACKAGES
fi
# What the packages say about where they run.
if [[ $SDK_NAME == "$ARCH" ]]; then
	SUMMIT_FOR="air/OS"
	SUMMIT_HAIKU_REQUIRES="haiku >= r1~beta6"
else
	SUMMIT_FOR="Haiku R1/beta6"
	# the release it was built against, or anything later
	SUMMIT_HAIKU_REQUIRES="haiku >= $HAIKU_REVISION"
fi
# Raise to replace a package built from the same Summit commit.
SUMMIT_REVISION=${SUMMIT_REVISION:-1}
PATCHELF=${PATCHELF:-patchelf}

# Versions from the Summit commit's time (UTC): 0.1.0~git20261005.1811 for the
# browser, 1.10.1~git20261005.1811 for the engine (newer than the hand-made
# 1.10.0 packages).
summit_versions() {
	local stamp
	stamp=$(TZ=UTC git -C "$APPS/summit" log -1 --format=%cd --date=format-local:%Y%m%d.%H%M)
	SUMMIT_VERSION=0.1.0~git$stamp-$SUMMIT_REVISION
	SUMMIT_WEBKIT_VERSION=1.10.1~git$stamp-$SUMMIT_REVISION
}

# set_rpath <ELF file> <new rpath>: Haiku's runtime loader resolves a library's
# dependencies with that library's own RPATH only, so every library of the
# engine needs one.
set_rpath() {
	"$PATCHELF" --force-rpath --set-rpath "$2" "$1"
}

# The engine's public API: every header of its Haiku API and the C base
# headers they include.
engine_api_headers() {
	ls "$SUMMIT_WEBKIT_SRC"/UIProcess/API/haiku/*.h
	echo "$SUMMIT_WEBKIT_SRC/Shared/API/c/WKBase.h" \
		"$SUMMIT_WEBKIT_SRC/Shared/API/c/WKDeclarationSpecifiers.h" \
		"$SUMMIT_WEBKIT_SRC/Shared/API/c/haiku/WKBaseHaiku.h"
}

summit_engine_built() {
	[[ -e $SUMMIT_ENGINE_BUILD/lib/libWebKit.so.1 && -x $SUMMIT_ENGINE_BUILD/bin/WebProcess \
		&& -x $SUMMIT_ENGINE_BUILD/bin/NetworkProcess ]]
}

build_summit_webkit() {
	note "summit_webkit (Summit's engine)"
	summit_engine_built || die "no Summit engine in $SUMMIT_ENGINE_BUILD (summit/build-engine.sh)"
	command -v "$PATCHELF" >/dev/null || die "patchelf is needed"
	summit_versions
	local work=$APPBUILD/summit_webkit
	mkdir -p "$work"
	STAGE=$work/stage
	stage_begin
	local engine=lib/summit-webkit
	mkdir -p "$STAGE/$engine/lib"
	local name
	# The processes find the engine's libraries, and on x86_64 the private EGL.
	local process_rpath='$ORIGIN/lib'
	[[ ! -d $SUMMIT_MESA/lib ]] || process_rpath='$ORIGIN/lib:$ORIGIN/mesa/lib'
	for name in WebProcess NetworkProcess; do
		cp "$SUMMIT_ENGINE_BUILD/bin/$name" "$STAGE/$engine/$name"
		chmod 755 "$STAGE/$engine/$name"
		"$STRIP" --strip-debug "$STAGE/$engine/$name"
		set_rpath "$STAGE/$engine/$name" "$process_rpath"
	done
	# The resources go on last: strip and patchelf drop them. Without them
	# the web process registers as an ordinary application (B_BACKGROUND_APP
	# is in its app flags) and the Deskbar lists it as "WebProcess".
	[[ ! -f $SUMMIT_ENGINE_BUILD/bin/WebProcess.rsrc ]] \
		|| "$TOOLS/xres" -o "$STAGE/$engine/WebProcess" "$SUMMIT_ENGINE_BUILD/bin/WebProcess.rsrc"
	# Every library the processes need that Haiku and the GL stack do not
	# have, transitively, under its soname: libWebKit, JavaScriptCore, ICU 78
	# and the third-party libraries of the engine.
	local pending=("$engine/WebProcess" "$engine/NetworkProcess") item needed source
	local -A seen=()
	# The engine's libraries find each other, and on x86_64 the private EGL.
	local lib_rpath='$ORIGIN'
	[[ ! -d $SUMMIT_MESA/lib ]] || lib_rpath='$ORIGIN:$ORIGIN/../mesa/lib'
	while [[ ${#pending[@]} -gt 0 ]]; do
		item=${pending[-1]}
		unset 'pending[-1]'
		for needed in $(readelf -d "$STAGE/$item" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
			[[ -n ${seen[$needed]:-} ]] && continue
			seen[$needed]=1
			# What the engine was built with comes along, even when the system
			# has a library of that name: the x86_64 SDK has HaikuPorts'
			# haikuwebkit (an old libJavaScriptCore.so.18). A library the SDK
			# has byte for byte (zlib) stays the system's, and so do the
			# image's libraries the x86_64 engine links (SUMMIT_SYSLIBS).
			source=""
			[[ -e $SUMMIT_ENGINE_BUILD/lib/$needed ]] && source=$SUMMIT_ENGINE_BUILD/lib/$needed
			[[ -z $source && -e $SUMMIT_LIBS/lib/$needed ]] && source=$SUMMIT_LIBS/lib/$needed
			if [[ -n $source && -e $SYSROOT/boot/system/lib/$needed ]] \
					&& cmp -s "$(readlink -f "$source")" "$(readlink -f "$SYSROOT/boot/system/lib/$needed")"; then
				continue
			fi
			if [[ -z $source ]]; then
				[[ -e $SYSROOT/boot/system/lib/$needed || -e $SYSROOT/boot/system/develop/lib/$needed \
					|| -e $GL_SYSTEM/lib/$needed || ( -n $SUMMIT_SYSLIBS && -e $SUMMIT_SYSLIBS/lib/$needed ) ]] \
					&& continue
				case $needed in
					libtracker.so|libtranslation.so|libmedia.so|libtextencoding.so) continue ;;
				esac
				die "summit_webkit: no $needed"
			fi
			cp "$(readlink -f "$source")" "$STAGE/$engine/lib/$needed"
			chmod 644 "$STAGE/$engine/lib/$needed"
			"$STRIP" --strip-unneeded "$STAGE/$engine/lib/$needed"
			set_rpath "$STAGE/$engine/lib/$needed" "$lib_rpath"
			pending+=("$engine/lib/$needed")
		done
	done
	# The private Mesa (x86_64), with the vendor file the engine passes to
	# libglvnd; it needs HaikuPorts' LLVM (llvmpipe) and Vulkan loader (zink).
	local mesa_requires=""
	if [[ -d $SUMMIT_MESA/lib ]]; then
		mkdir -p "$STAGE/$engine/mesa/lib" "$STAGE/$engine/mesa/egl_vendor.d"
		cp -a "$SUMMIT_MESA/lib/." "$STAGE/$engine/mesa/lib/"
		local lib
		for lib in "$STAGE/$engine"/mesa/lib/*.so*; do
			[[ -L $lib ]] || set_rpath "$lib" '$ORIGIN'
		done
		printf '{\n    "file_format_version" : "1.0.0",\n    "ICD" : {\n        "library_path" : "/boot/system/%s/mesa/lib/libEGL_mesa.so.0"\n    }\n}\n' \
			"$engine" > "$STAGE/$engine/mesa/egl_vendor.d/50_mesa.json"
		cp "$SUMMIT_MESA/gl-sources.txt" "$SUMMIT_MESA/haikuports.json" "$work/" 2>/dev/null || true
		mesa_requires=$'\tlib:libllvm >= 21\n\tlib:libvulkan >= 1'
	fi
	# x86_64: the libraries the engine links from the image (or the release),
	# at the image's versions.
	local system_requires=""
	if [[ -n $SUMMIT_SYSLIBS ]]; then
		system_requires=$(python3 "$AIROS_CI/apps/release-requires.py" "$TOOLS/package/package" \
			"$SUMMIT_SYSLIBS_PACKAGES" --skip "$STAGE/$engine/lib" --skip "$STAGE/$engine/mesa/lib" \
			"$STAGE/$engine/WebProcess" "$STAGE/$engine/NetworkProcess" \
			$(find "$STAGE/$engine/lib" "$STAGE/$engine/mesa/lib" -name '*.so*' -type f 2>/dev/null) \
			| sed 's/^/\t/')
	fi
	# Fontconfig's configuration, where the engine's Fontconfig looks for it.
	if [[ -d $SUMMIT_LIBS/etc/fonts ]]; then
		mkdir -p "$STAGE/$engine/etc"
		cp -RL "$SUMMIT_LIBS/etc/fonts" "$STAGE/$engine/etc/"
	fi
	# libWebKit.so for programs that link the engine (Natter, Summit, Aurora)
	ln -s libWebKit.so.1 "$STAGE/$engine/lib/libWebKit.so"
	local header
	mkdir -p "$STAGE/develop/headers/summit-webkit/WebKit"
	for header in $(engine_api_headers); do
		cp "$header" "$STAGE/develop/headers/summit-webkit/WebKit/"
	done
	mkdir -p "$STAGE/documentation/packages/summit_webkit"
	cp "$SUMMIT_ENGINE_BUILD/engine.json" "$STAGE/documentation/packages/summit_webkit/build.json"
	cp "$SUMMIT_LIBS/forks.json" "$STAGE/documentation/packages/summit_webkit/libraries.json"
	local base
	base=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["webkit"]["base"][:12])' \
		"$SUMMIT_ENGINE_BUILD/engine.json")
	cat > "$STAGE/.PackageInfo" <<INFO
name			summit_webkit
version			$SUMMIT_WEBKIT_VERSION
architecture	$ARCH
summary			"The WebKit engine of the Summit browser"
description		"The Summit browser's WebKit (libWebKit with its web and network processes, JavaScriptCore, ICU 78 and the libraries they need), installed in /boot/system/lib/summit-webkit, with GL compositing, WebGL and WebRTC. Programs link lib/libWebKit.so.1 from there and include develop/headers/summit-webkit. The $SUMMIT_FOR build, made by air/OS CI from WebKit $base (airos-works/WebKit) with the Haiku port of Summit $(git -C "$APPS/summit" rev-parse --short HEAD)."
packager		"air/OS CI"
vendor			"Summit project"
copyrights {
	"Apple Inc. and the WebKit contributors"
	"Summit contributors"
}
licenses {
	"GNU LGPL v2"
	"GNU LGPL v2.1"
	"BSD (2-clause)"
	"BSD (3-clause)"
	"MIT"
}
provides {
	summit_webkit = ${SUMMIT_WEBKIT_VERSION%-*}
}
requires {
	$SUMMIT_HAIKU_REQUIRES
$mesa_requires
$system_requires
}
INFO
	DROPPED="(none)"
	finish_package summit_webkit "$engine/WebProcess" "$engine/NetworkProcess"
}

# object_is_current <object>: the object is newer than its source and every
# header that went into it, from the list gcc wrote beside it (-MMD). An
# object without that list is rebuilt. Comparing with the source alone kept
# objects of a struct's old layout beside new ones when a header changed
# (summit 97a499c's Profile, 1487b19's BrowserWindow): the browser read
# padding for a new field and allocated windows too small.
object_is_current() {
	local object=$1 dependency
	[[ -e $object && -e $object.d ]] || return 1
	while read -r dependency; do
		[[ -e $dependency && ! $dependency -nt $object ]] || return 1
	done < <(sed -e 's/^[^:]*://' -e 's/\\$//' "$object.d" | tr -s ' ' '\n' | sed '/^$/d')
	return 0
}

build_summit() {
	note Summit
	summit_engine_built || die "no Summit engine in $SUMMIT_ENGINE_BUILD (summit/build-engine.sh)"
	summit_versions
	snapshot summit summit
	local work=$APPBUILD/summit
	# The engine's public headers, as an installed engine has them.
	rm -rf "$work/engine"
	mkdir -p "$work/engine/include/WebKit" "$BUILDDIR/obj"
	local header
	for header in $(engine_api_headers); do
		# Their times are the engine source's: objects that include them are
		# rebuilt only when they change (object_is_current).
		cp -p "$header" "$work/engine/include/WebKit/"
	done
	# The browser's sources: the list its own native build uses.
	local sources
	sources=$(python3 - "$SRC/tools/build-modern-browser.py" <<'PY'
import ast, re, sys
text = open(sys.argv[1]).read()
match = re.search(r"\n(\s+)sources = (\['src/main\.cpp'.*?\])\n", text, re.S)
print(' '.join(ast.literal_eval(match.group(2))))
PY
)
	[[ -n $sources ]] || die "no source list in Summit's tools/build-modern-browser.py"
	local private=$SYSROOT/boot/system/develop/headers/private
	local flags=(-std=c++23 -O2 -Wall -Wextra -Wno-multichar -DBUILDING_HAIKU__=1
		-I"$work/engine/include" -DSUMMIT_MODERN_WEBKIT=1 -I"$SRC/src" -I"$SRC/vendor"
		-I"$private/netservices" -I"$private" -I"$FARM/include"
		-I"$FARM/include/scintilla" -I"$FARM/include/lexilla")
	# src/core/BuildTarget.h
	[[ $SDK_NAME == "$ARCH" ]] || flags+=(-DSUMMIT_AIROS=0 "-DSUMMIT_TARGET_NAME=\"$SUMMIT_FOR\"")
	local source objects=() object
	for source in $sources; do
		object=$BUILDDIR/obj/$(echo "${source%.cpp}" | tr / _).o
		objects+=("$object")
		object_is_current "$object" && continue
		${CROSS}g++ --sysroot="$SYSROOT" "${flags[@]}" -MMD -MF "$object.d" -c "$SRC/$source" -o "$object" &
		while [[ $(jobs -rp | wc -l) -ge $JOBS ]]; do wait -n; done
	done
	wait
	for object in "${objects[@]}"; do [[ -e $object ]] || die "Summit: $object did not compile"; done
	# As Summit's own build links it: the libraries most symbols are found in
	# right after libWebKit, and a GNU hash table (the loader settles most
	# misses by its bloom filter).
	${CROSS}g++ --sysroot="$SYSROOT" -specs="$UNWIND_SPECS" "${objects[@]}" \
		-L"$SUMMIT_ENGINE_BUILD/lib" -L"$FARM/lib" \
		-Wl,-rpath-link,"$SUMMIT_ENGINE_BUILD/lib" -Wl,-rpath-link,"$SUMMIT_LIBS/lib" \
		-Wl,-rpath-link,"$TLS_DEPS/lib" -Wl,-rpath-link,"$GL_SYSTEM/lib" \
		-Wl,-rpath-link,"$SYSROOT/boot/system/lib" -Wl,-rpath,"$ENGINE_DIR/lib" \
		-lWebKit -lJavaScriptCore -lbe -lstdc++ -lroot -lnetwork -lcrypto -lbnetapi \
		-ltranslation -ltracker -lgame -lscintilla -llexilla -lcurl -lcolumnlistview \
		-Wl,--hash-style=both -o "$BUILDDIR/Summit"
	"$TOOLS/rc/rc" -I "$SRC/resources" -o "$BUILDDIR/Summit.rsrc" "$SRC/resources/Summit.rdef"

	stage_begin
	install_binary "$BUILDDIR/Summit" "$BUILDDIR/Summit.rsrc" apps/Summit
	install_file 644 "$SRC/resources/start.html" data/Summit/start.html
	deskbar_link apps/Summit Summit
	docs summit README.md LICENSE docs vendor/nlohmann/LICENSE.MIT vendor/nlohmann/UPSTREAM.md
	# air/OS: the system's web browser: links, web pages and XHTML open in
	# Summit. On Haiku that stays the user's choice (Summit's preferences).
	local browser_requires=""
	if [[ $SDK_NAME == "$ARCH" ]]; then
		mkdir -p "$STAGE/boot/post-install"
		cat > "$STAGE/boot/post-install/summit-default-browser.sh" <<'SH'
#!/bin/sh
# air/OS: Summit is the default web browser.
for type in application/x-vnd.Be.URL.http application/x-vnd.Be.URL.https \
		text/html application/xhtml+xml; do
	setmime -set "$type" -preferredAppSig application/x-vnd.Kunanyi-Summit
done
SH
		chmod 755 "$STAGE/boot/post-install/summit-default-browser.sh"
	else
		# What it links from the release and from HaikuPorts (Scintilla and
		# Lexilla, for the developer tools' text views), not the engine's.
		browser_requires=$(python3 "$AIROS_CI/apps/release-requires.py" "$TOOLS/package/package" \
			"$HAIKU_PACKAGES" --skip "$SUMMIT_ENGINE_BUILD/lib" --skip "$SUMMIT_LIBS/lib" \
			"$BUILDDIR/Summit" | sed 's/^/\t/')
	fi
	cat > "$STAGE/.PackageInfo" <<INFO
name			summit
version			$SUMMIT_VERSION
architecture	$ARCH
summary			"A native WebKit browser"
description		"Summit is a WebKit browser for Haiku and air/OS, with tabs, extensions, developer tools and site permissions, and the default web browser of air/OS. The $SUMMIT_FOR build, made by air/OS CI from Summit $(git -C "$APPS/summit" rev-parse --short HEAD) against the summit_webkit engine of the same build."
packager		"air/OS CI"
vendor			"Summit project"
copyrights {
	"2026 KunanyiOS contributors"
	"2013-2025 Niels Lohmann"
}
licenses {
	"MIT"
}
provides {
	summit = ${SUMMIT_VERSION%-*}
	app:Summit = ${SUMMIT_VERSION%-*}
}
requires {
	$SUMMIT_HAIKU_REQUIRES
	summit_webkit >= ${SUMMIT_WEBKIT_VERSION%-*}
$browser_requires
}
INFO
	DROPPED="(none)"
	add_attributes "$BUILDDIR/Summit.rsrc" apps/Summit
	finish_package summit apps/Summit
}

# summit_webkitlegacy: libWebKitLegacy, the BWebView API of HaikuWebKit
# (WebPositive's) on Summit's engine, from the Summit checkout's legacy/ (its
# Makefile, as Summit's tools/package-summit-webkitlegacy.sh builds it on a
# workstation) with Summit's developer tools from src/ as its web inspector.
# It takes the place of HaikuPorts' haikuwebkit and haikuwebkit_devel: it
# provides both (WebPositive requires haikuwebkit >= 1.10.0), holds their
# library and header paths, and replaces and conflicts with them, so a
# program built for HaikuWebKit runs on the engine of the same build. Built
# with summit_webkit, after the engine (summit/build-summit.sh).
SUMMIT_WEBKITLEGACY_API=1.10.0
build_summit_webkitlegacy() {
	note "summit_webkitlegacy (the BWebView API on Summit's engine)"
	summit_engine_built || die "no Summit engine in $SUMMIT_ENGINE_BUILD (summit/build-engine.sh)"
	summit_versions
	snapshot summit summit_webkitlegacy
	[[ -f $SRC/legacy/Makefile ]] || die "no legacy/Makefile in this Summit revision"
	local work=$APPBUILD/summit_webkitlegacy
	# The engine's public headers, as an installed engine has them (times
	# kept: the developer tools' objects follow them through their -MMD lists).
	rm -rf "$work/engine"
	mkdir -p "$work/engine/include/WebKit"
	local header
	for header in $(engine_api_headers); do
		cp -p "$header" "$work/engine/include/WebKit/"
	done
	# legacy/'s own objects list only its headers as dependencies; they are
	# few, so they are always compiled again (an engine header may have
	# changed).
	rm -f "$BUILDDIR"/*.o
	local develop=$SYSROOT/boot/system/develop
	local static
	for static in libnetservices.a libshared.a libcolumnlistview.a; do
		[[ -f $develop/lib/$static ]] || die "summit_webkitlegacy: no $static in the SDK ($develop/lib)"
	done
	[[ -e $FARM/include/scintilla && -e $FARM/include/lexilla && -e $FARM/lib/libscintilla.so \
		&& -e $FARM/lib/liblexilla.so ]] || die "summit_webkitlegacy: no Scintilla or Lexilla in DEPS"
	# CXX carries the sysroot and the farm (-lscintilla, -llexilla); the
	# linker follows libWebKit's own libraries through -rpath-link. The
	# library's run-time path is the installed engine's (legacy/Makefile).
	local link="-Wl,-rpath-link,$SUMMIT_ENGINE_BUILD/lib -Wl,-rpath-link,$SUMMIT_LIBS/lib"
	link+=" -Wl,-rpath-link,$TLS_DEPS/lib -Wl,-rpath-link,$GL_SYSTEM/lib"
	[[ -z $SUMMIT_SYSLIBS ]] || link+=" -Wl,-rpath-link,$SUMMIT_SYSLIBS/lib"
	link+=" -Wl,-rpath-link,$SYSROOT/boot/system/lib"
	make -C "$SRC/legacy" -s -j"$JOBS" OUT="$BUILDDIR" CXX="$CXX_T" CXXFLAGS=-O2 \
		LDFLAGS="$link" VERSION="$SUMMIT_WEBKITLEGACY_API" \
		ENGINE_HEADERS="$work/engine/include" ENGINE_LIB="$SUMMIT_ENGINE_BUILD/lib" \
		ENGINE_RUNPATH="$ENGINE_DIR/lib" PRIVATE_HEADERS="$develop/headers/private" \
		SCINTILLA_HEADERS="$FARM/include/scintilla $FARM/include/lexilla" \
		STATIC_LIBS="$develop/lib" SUMMIT_SRC="$SRC/src" SUMMIT_VENDOR="$SRC/vendor"
	local library=libWebKitLegacy.so.$SUMMIT_WEBKITLEGACY_API
	[[ -f $BUILDDIR/$library ]] || die "summit_webkitlegacy: make left no $library"

	stage_begin
	install_binary "$BUILDDIR/$library" - "lib/$library"
	ln -s "$library" "$STAGE/lib/libWebKitLegacy.so.1"
	mkdir -p "$STAGE/develop/lib" "$STAGE/develop/headers"
	ln -s ../../lib/libWebKitLegacy.so.1 "$STAGE/develop/lib/libWebKitLegacy.so"
	cp "$SRC"/legacy/headers/*.h "$STAGE/develop/headers/"
	chmod 644 "$STAGE"/develop/headers/*.h
	docs summit_webkitlegacy legacy/README.md docs/legacy-webview.md LICENSE
	# x86_64: Scintilla and Lexilla (the inspector's text views) from
	# HaikuPorts; arm64 images carry airos_scintilla and airos_lexilla, which
	# provide no lib: names (as retarget_package_info, no lib: requires on
	# arm64).
	local text_requires=""
	[[ $ARCH == arm64 ]] || text_requires=$'\tlib:libscintilla\n\tlib:liblexilla'
	cat > "$STAGE/.PackageInfo" <<INFO
name			summit_webkitlegacy
version			$SUMMIT_WEBKIT_VERSION
architecture	$ARCH
summary			"The BWebView API of WebPositive on the Summit browser's engine"
description		"libWebKitLegacy with the classes of HaikuWebKit's API (BWebView, BWebPage, BWebWindow, BWebDownload, BWebSettings, BWebFrame) running on the Summit browser's WebKit engine (summit_webkit), with Summit's developer tools as its web inspector. Programs built for HaikuWebKit, such as WebPositive, run on it unchanged. Replaces haikuwebkit and haikuwebkit_devel. The $SUMMIT_FOR build, made by air/OS CI from Summit $(git -C "$APPS/summit" rev-parse --short HEAD) against the summit_webkit engine of the same build."
packager		"air/OS CI"
vendor			"Summit project"
copyrights {
	"2026 Summit contributors"
	"2007-2010 Andrea Anzani, Ryan Leavengood, Maxime Simon, Stephan Aßmus (BWebWindow, headers)"
	"2012 Alexandre Deckner (WebKitInfo.h)"
	"2013-2025 Niels Lohmann"
}
licenses {
	"MIT"
	"BSD (2-clause)"
}
provides {
	summit_webkitlegacy = ${SUMMIT_WEBKIT_VERSION%-*}
	haikuwebkit = ${SUMMIT_WEBKIT_VERSION%-*}
	haikuwebkit_devel = ${SUMMIT_WEBKIT_VERSION%-*}
	lib:libWebKitLegacy = $SUMMIT_WEBKITLEGACY_API compat >= 1
	devel:libWebKitLegacy = $SUMMIT_WEBKITLEGACY_API compat >= 1
}
requires {
	$SUMMIT_HAIKU_REQUIRES
	summit_webkit >= ${SUMMIT_WEBKIT_VERSION%-*}
$text_requires
}
conflicts {
	haikuwebkit
	haikuwebkit_devel
}
replaces {
	haikuwebkit
	haikuwebkit_devel
}
INFO
	DROPPED="(none)"
	finish_package summit_webkitlegacy "lib/$library"
}

# --- Aurora -------------------------------------------------------------------
# Electron apps on Summit's engine: aurora-host (each app's windows, a
# BApplication that links libWebKit from summit_webkit), its Deskbar add-on
# for Tray icons, and the JavaScript runtime that HaikuPorts' Node.js runs
# (cmd:node). x86_64 only: arm64 has no Node.js. Staged as the app's own
# tools/package-haiku.sh does, whose `aurora` command and package info are
# taken from it.
aurora_heredoc() { # aurora_heredoc <path in stage> <terminator>
	awk -v start="cat > \"\$STAGE/$1\" <<" -v end="$2" '
		index($0, start) == 1 { inside = 1; next }
		inside && $0 == end { exit }
		inside { print }' "$SRC/tools/package-haiku.sh"
}

build_aurora() {
	note Aurora
	engine_ready || die "no Summit engine in $SUMMIT_ENGINE (summit_webkit not staged)"
	snapshot aurora aurora
	local work=$APPBUILD/aurora
	# The libraries libWebKit needs, for the linker only: the Makefile's RPATH
	# (the summit_webkit package's lib/, or an engine beside a launcher) stays.
	local rpath_link="-Wl,-rpath-link,$SUMMIT_ENGINE/lib -Wl,-rpath-link,$SUMMIT_ENGINE/mesa/lib"
	rpath_link+=" -Wl,-rpath-link,$DEPS/lib -Wl,-rpath-link,$SYSROOT/boot/system/lib"
	[[ -z $SUMMIT_SYSLIBS ]] || rpath_link+=" -Wl,-rpath-link,$SUMMIT_SYSLIBS/lib"
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T $rpath_link" \
		WEBKIT_BUNDLE="$SUMMIT_ENGINE" WEBKIT_INCLUDE="$SUMMIT_WEBKIT_HEADERS" all

	stage_begin
	local data=data/aurora
	mkdir -p "$STAGE/$data/runtime" "$STAGE/bin"
	cp -R "$SRC/runtime/lib" "$SRC/runtime/package.json" "$SRC/runtime/tools" "$STAGE/$data/runtime/"
	install_binary "$BUILDDIR/aurora-host" "$BUILDDIR/aurora-host.rsrc" "$data/aurora-host"
	# Deskbar finds the add-on by its signature.
	install_binary "$BUILDDIR/aurora-tray" "$BUILDDIR/aurora-tray.rsrc" "$data/aurora-tray"
	aurora_heredoc bin/aurora SCRIPT > "$STAGE/bin/aurora"
	[[ -s $STAGE/bin/aurora ]] || die "no aurora command in aurora's tools/package-haiku.sh"
	chmod 755 "$STAGE/bin/aurora"
	ln -s aurora "$STAGE/bin/electron"
	docs aurora README.md LICENSE host/vendor/nlohmann/LICENSE.MIT host/vendor/nlohmann/UPSTREAM.md
	local version revision
	version=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$SRC/runtime/package.json" | head -1)
	revision=$(sed -n 's/^REVISION=\([0-9][0-9]*\)$/\1/p' "$SRC/tools/package-haiku.sh")
	aurora_heredoc .PackageInfo INFO > "$work/PackageInfo.template"
	[[ -s $work/PackageInfo.template ]] || die "no package info in aurora's tools/package-haiku.sh"
	VERSION=$version REVISION=${revision:-1} ARCH=$ARCH \
		bash -c 'eval "cat <<INFO
$(cat "$1")
INFO"' _ "$work/PackageInfo.template" > "$work/aurora.PackageInfo"
	# arm64 keeps Node.js (airos-ci's nodejs22, deps/recipes/nodejs22.sh) and the
	# engine: an image with Aurora carries both
	retarget_package_info "$work/aurora.PackageInfo" "$STAGE/.PackageInfo" '^(cmd:node|summit_webkit)'
	# The host and the add-on are applications outside apps/ and add-ons/.
	local APP_PATHS="^(apps|add-ons)/|^$data/aurora-(host|tray)\$"
	add_attributes "$BUILDDIR/aurora-host.rsrc" "$data/aurora-host"
	resource_attributes "$BUILDDIR/aurora-tray.rsrc" "$data/aurora-tray"
	echo "RPATH: $(readelf -d "$STAGE/$data/aurora-host" | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p')"
	finish_package aurora "$data/aurora-host" "$data/aurora-tray"
}

# --- Code - OSS ---------------------------------------------------------------
# Visual Studio Code's open source build on Aurora (airos-works/vscode, branch
# haiku; build/haiku/README.md). The workbench is the same JavaScript on every
# architecture: gulp builds it once per commit of the repository, with the
# Node.js of its .nvmrc, into a stage kept in $CODE_OSS_WORK (npm ci only when
# a package-lock.json changes). build/haiku/cross.sh then cross-builds the
# native modules against Node.js 22's headers and makes the package, whose
# launcher is the pool's aurora-host for ARCH with Code - OSS's resources: so
# build Aurora first, and Code - OSS again after an Aurora host change.
CODE_OSS_WORK=${CODE_OSS_WORK:-$AIROS_WORK/code_oss}
CODE_OSS_BUILD_NODE=24.18.0
CODE_OSS_BUILD_NODE_SHA256=55aa7153f9d88f28d765fcdad5ae6945b5c0f98a36881703817e4c450fa76742
CODE_OSS_HEADERS=22.23.3
CODE_OSS_HEADERS_SHA256=eff1a7e67736bdf25db421ddaa613ed605f751a7b9fe07fb473ea880d1348987

# fetch_node <file under nodejs.org/dist/vVERSION> <version> <sha256>: into the cache
fetch_node() {
	local tarball=$AIROS_CACHE/$1
	if [[ ! -f $tarball ]]; then
		curl -fsSL --retry 3 -o "$tarball.part" "https://nodejs.org/dist/v$2/$1"
		mv "$tarball.part" "$tarball"
	fi
	echo "$3  $tarball" | sha256sum -c --quiet - || die "$tarball: wrong SHA-256"
	echo "$tarball"
}

# linux_node <version> <sha256>: a Node.js for this machine, unpacked in the
# cache once; prints its directory
linux_node() {
	local node=$AIROS_CACHE/node-v$1-linux-x64 tarball
	if [[ ! -x $node/bin/node ]]; then
		tarball=$(fetch_node "node-v$1-linux-x64.tar.xz" "$1" "$2")
		rm -rf "$node.part"
		mkdir -p "$node.part"
		tar xJf "$tarball" -C "$node.part" --strip-components=1
		mv "$node.part" "$node"
	fi
	echo "$node"
}

# aurora_launcher <directory>: the pool's aurora-host for ARCH, which Aurora
# apps copy as their launcher, extracted into <directory>/data/aurora; needs
# Aurora 0.3 or later. Remove <directory> with rm_attrs.
aurora_launcher() {
	local aurora version
	aurora=$(compgen -G "$AIROS_PACKAGES/$ARCH/aurora-[0-9]*-$ARCH.hpkg" | head -1) \
		|| die "no aurora package for $ARCH in the pool: build Aurora first"
	version=$(basename "$aurora" | sed 's/^aurora-\([0-9.]*\).*/\1/')
	[[ $(printf '0.3\n%s\n' "$version" | sort -V | head -1) == 0.3 ]] \
		|| die "$aurora is older than Aurora 0.3"
	[[ -e $1 ]] && "$TOOLS/rm_attrs" -rf "$1"
	mkdir -p "$1"
	"$TOOLS/package/package" extract -C "$1" "$aurora" data/aurora/aurora-host
	echo "launcher: aurora-host of $(basename "$aurora")"
}

# The stage for the repository's commit: build/haiku/build.sh, once.
code_oss_stage() {
	local repo=$1 src=$CODE_OSS_WORK/vscode stage=$CODE_OSS_WORK/stage
	local nvmrc commit locks
	nvmrc=$(cat "$repo/.nvmrc")
	[[ $nvmrc == "$CODE_OSS_BUILD_NODE" ]] \
		|| die "Code - OSS builds with Node.js $nvmrc: pin it in CODE_OSS_BUILD_NODE"
	local node
	node=$(linux_node "$nvmrc" "$CODE_OSS_BUILD_NODE_SHA256")
	commit=$(git -C "$repo" rev-parse HEAD)
	[[ -z $(git --no-optional-locks -C "$repo" status --porcelain) ]] || commit+=-dirty
	if [[ $commit != *-dirty && -f $stage/VERSION && $(cat "$CODE_OSS_WORK/stage.commit" 2>/dev/null) == "$commit" ]]; then
		echo "stage of $commit is current"
		return
	fi
	# The working tree without what git ignores; ignored files already here
	# (node_modules, gulp's out-* trees) stay for the next build.
	mkdir -p "$src"
	rsync -a --delete --exclude=/.git --filter=':- .gitignore' "$repo/" "$src/"
	locks=$(cd "$src" && find . -name node_modules -prune -o -name package-lock.json -print \
		| sort | xargs sha256sum | sha256sum | cut -c1-64)
	(
		export PATH=$node/bin:$PATH
		cd "$src"
		if [[ ! -d node_modules || $(cat "$CODE_OSS_WORK/npm.locks" 2>/dev/null) != "$locks" ]]; then
			note "Code - OSS: npm ci (Node.js $(node --version))"
			# Without install scripts: they build the modules' Linux binaries
			# (native-keymap wants X11's headers), and the package's are
			# cross-built by build/haiku/cross.sh. The repository's postinstall
			# then installs its sub-projects (build, extensions, remote) the
			# same way; it sets git options, so the copy gets an empty repository.
			export ELECTRON_SKIP_BINARY_DOWNLOAD=1 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
			npm ci --no-audit --no-fund --ignore-scripts
			[[ -d .git ]] || git init -q
			npm_config_ignore_scripts=true npm_command=ci node build/npm/postinstall.ts
			echo "$locks" > "$CODE_OSS_WORK/npm.locks"
		fi
		note "Code - OSS: workbench (gulp vscode-haiku-x64-min)"
		build/haiku/build.sh "$stage"
	)
	echo "$commit" > "$CODE_OSS_WORK/stage.commit"
}

build_code_oss() {
	note "Code - OSS"
	local repo=$APPS/vscode
	[[ -d $repo ]] || die "no repository $repo"
	mkdir -p "$CODE_OSS_WORK"
	exec {code_oss_lock}>"$AIROS_LOCKS/code_oss.lock"
	flock "$code_oss_lock"
	code_oss_stage "$repo"
	# node-gyp's include/node and common.gypi (the ABI is the same in every 22.x)
	local headers=$CODE_OSS_WORK/node-v$CODE_OSS_HEADERS
	if [[ ! -f $headers/include/node/node.h ]]; then
		local tarball
		tarball=$(fetch_node "node-v$CODE_OSS_HEADERS-headers.tar.gz" "$CODE_OSS_HEADERS" "$CODE_OSS_HEADERS_SHA256")
		rm -rf "$headers"
		mkdir -p "$headers"
		tar xzf "$tarball" -C "$headers" --strip-components=1
	fi
	# The launcher: the pool's aurora-host.
	local version host=$CODE_OSS_WORK/aurora-$ARCH
	aurora_launcher "$host"
	local log=$CODE_OSS_WORK/cross-$ARCH.log
	# node-gyp: the build Node.js's npm
	PATH=$AIROS_CACHE/node-v$CODE_OSS_BUILD_NODE-linux-x64/bin:$PATH \
		AIROS_SDK=$AIROS_SDK/$SDK_NAME/env.sh NODE_SOURCE=$headers HAIKU_HOST_TOOLS=$TOOLS \
		HAIKU_MIME_DB=$MIMEDB AURORA_HOST_BINARY=$host/data/aurora/aurora-host \
		TMPDIR=$CODE_OSS_WORK \
		"$CODE_OSS_WORK/vscode/build/haiku/cross.sh" "$ARCH" "$CODE_OSS_WORK/stage" "$CODE_OSS_WORK/out-$ARCH" \
		> "$log" 2>&1 || { tail -40 "$log"; die "Code - OSS for $ARCH failed"; }
	"$TOOLS/rm_attrs" -rf "$host"
	local file
	file=$(tail -1 "$log")
	[[ -f $file ]] || die "cross.sh made no package"
	verify_package "$file"
	rm -f "$OUT"/code_oss-[0-9]*-"$ARCH".hpkg
	mv "$file" "$OUT/"
	file=$OUT/$(basename "$file")
	version=$(basename "$file" | sed "s/^code_oss-\(.*\)-$ARCH.hpkg\$/\1/")
	echo "package:  $file"
	printf '%s\t%s\t%s\t%s\n' code_oss "$file" "$version" "(none)" >> "$APPBUILD/.summary"
	flock -u "$code_oss_lock"
}

# --- GitHub Desktop ----------------------------------------------------------
# GitHub Desktop on Aurora (airos-works/desktop, branch haiku, on upstream's
# release tags; docs/technical/haiku.md). Its webpack build bundles every
# module, so the app is the same JavaScript on every architecture: it is
# built once per commit of the repository, with the Node.js of its .nvmrc and
# the yarn the repository vendors, into a stage kept in $GITHUB_DESKTOP_WORK
# (yarn install only when a yarn.lock changes). script/haiku/cross.sh then
# cross-builds the native helpers (Git's credential and askpass trampolines,
# the hooks proxy, printenvz) and makes the package around the pool's
# aurora-host for ARCH: build Aurora first. Git is the system's (cmd:git:
# HaikuPorts' on x86_64, deps/recipes/git.sh on arm64).
GITHUB_DESKTOP_WORK=${GITHUB_DESKTOP_WORK:-$AIROS_WORK/github_desktop}
GITHUB_DESKTOP_BUILD_NODE=24.15.0
GITHUB_DESKTOP_BUILD_NODE_SHA256=472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6

# The stage for the repository's commit: script/haiku/build.sh, once.
github_desktop_stage() {
	local repo=$1 src=$GITHUB_DESKTOP_WORK/desktop stage=$GITHUB_DESKTOP_WORK/stage
	local nvmrc node commit locks yarn
	nvmrc=$(cat "$repo/.nvmrc")
	nvmrc=${nvmrc#v}
	[[ $nvmrc == "$GITHUB_DESKTOP_BUILD_NODE" ]] \
		|| die "GitHub Desktop builds with Node.js $nvmrc: pin it in GITHUB_DESKTOP_BUILD_NODE"
	node=$(linux_node "$nvmrc" "$GITHUB_DESKTOP_BUILD_NODE_SHA256")
	commit=$(git -C "$repo" rev-parse HEAD)
	[[ -z $(git --no-optional-locks -C "$repo" status --porcelain) ]] || commit+=-dirty
	if [[ $commit != *-dirty && -f $stage/VERSION && $(cat "$GITHUB_DESKTOP_WORK/stage.commit" 2>/dev/null) == "$commit" ]]; then
		echo "stage of $commit is current"
		return
	fi
	# The working tree, submodules (gemoji, gitignore and the licences)
	# included, without what git ignores; ignored files already here
	# (node_modules) stay for the next build.
	[[ -f $repo/gemoji/db/emoji.json ]] || die "$repo has no submodules: git submodule update --init"
	mkdir -p "$src"
	rsync -a --delete --exclude=/.git --filter=':- .gitignore' "$repo/" "$src/"
	locks=$(cat "$src/yarn.lock" "$src/app/yarn.lock" | sha256sum | cut -c1-64)
	yarn=$(compgen -G "$src/vendor/yarn-*.js" | sort -V | tail -1) || die "no vendored yarn in $repo"
	# yarn by name, for the build scripts: the vendored one
	mkdir -p "$GITHUB_DESKTOP_WORK/bin"
	printf '#!/bin/sh\nexec node "%s" "$@"\n' "$yarn" > "$GITHUB_DESKTOP_WORK/bin/yarn"
	chmod 755 "$GITHUB_DESKTOP_WORK/bin/yarn"
	(
		export PATH=$GITHUB_DESKTOP_WORK/bin:$node/bin:$PATH
		export YARN_CACHE_FOLDER=$GITHUB_DESKTOP_WORK/yarn-cache
		cd "$src"
		if [[ ! -d app/node_modules || $(cat "$GITHUB_DESKTOP_WORK/yarn.locks" 2>/dev/null) != "$locks" ]]; then
			note "GitHub Desktop: yarn install (Node.js $(node --version))"
			# Without install scripts: they build the Linux binaries of the
			# native modules (keytar, fs-admin, ...), which a Haiku build
			# replaces (app/webpack.common.ts), and download Electron, Git and
			# Playwright. The post-install's other steps need none here. Of
			# the vendored modules' scripts, only the TypeScript is wanted.
			yarn install --frozen-lockfile --ignore-scripts --network-timeout 600000
			yarn --cwd app install --frozen-lockfile --ignore-scripts --network-timeout 600000
			local module
			for module in "$src"/vendor/*/tsconfig.json; do
				module=$(basename "$(dirname "$module")")
				[[ -d app/node_modules/$module ]] || continue
				(cd "app/node_modules/$module" && "$src/node_modules/.bin/tsc")
			done
			echo "$locks" > "$GITHUB_DESKTOP_WORK/yarn.locks"
		fi
		note "GitHub Desktop: webpack (DESKTOP_TARGET_PLATFORM=haiku)"
		# The commit the app names (About) comes from .git, which the copy
		# has not; app/git-info.ts takes it from CircleCI's variable first.
		CIRCLE_SHA1=${commit%-dirty} script/haiku/build.sh "$stage"
	)
	echo "$commit" > "$GITHUB_DESKTOP_WORK/stage.commit"
}

build_github_desktop() {
	note "GitHub Desktop"
	local repo=$APPS/desktop
	[[ -d $repo ]] || die "no repository $repo"
	mkdir -p "$GITHUB_DESKTOP_WORK"
	exec {github_desktop_lock}>"$AIROS_LOCKS/github_desktop.lock"
	flock "$github_desktop_lock"
	github_desktop_stage "$repo"
	local host=$GITHUB_DESKTOP_WORK/aurora-$ARCH log=$GITHUB_DESKTOP_WORK/cross-$ARCH.log
	aurora_launcher "$host"
	AIROS_SDK=$AIROS_SDK/$SDK_NAME/env.sh HAIKU_HOST_TOOLS=$TOOLS HAIKU_MIME_DB=$MIMEDB \
		AURORA_HOST_BINARY=$host/data/aurora/aurora-host TMPDIR=$GITHUB_DESKTOP_WORK \
		"$GITHUB_DESKTOP_WORK/desktop/script/haiku/cross.sh" "$ARCH" "$GITHUB_DESKTOP_WORK/stage" \
		"$GITHUB_DESKTOP_WORK/out-$ARCH" > "$log" 2>&1 || { tail -40 "$log"; die "GitHub Desktop for $ARCH failed"; }
	"$TOOLS/rm_attrs" -rf "$host"
	local file version
	file=$(tail -1 "$log")
	[[ -f $file ]] || die "cross.sh made no package"
	verify_package "$file"
	rm -f "$OUT"/github_desktop-[0-9]*-"$ARCH".hpkg
	mv "$file" "$OUT/"
	file=$OUT/$(basename "$file")
	version=$(basename "$file" | sed "s/^github_desktop-\(.*\)-$ARCH.hpkg\$/\1/")
	echo "package:  $file"
	printf '%s\t%s\t%s\t%s\n' github_desktop "$file" "$version" "(none)" >> "$APPBUILD/.summary"
	flock -u "$github_desktop_lock"
}

# --- pgAdmin 4 ----------------------------------------------------------------
# pgAdmin 4's desktop app on Aurora (aurora's ports/pgadmin4): its server in a
# Python 3.12 environment of its own, and the release's Electron main process,
# with the pool's aurora-host as the launcher. The port's cross.sh does the
# work on Linux: crossenv builds the native modules (cryptography and bcrypt
# in Rust with sdk/build-rust.sh's nightly, cffi, psycopg-c against libpq, ...)
# against the target's Python, which is HaikuPorts' python3.12 on x86_64
# (staged here with libffi, libpq and OpenSSL 3, all of which the package
# requires) and DEPS on arm64 (deps/recipes/python312.sh, libffi.sh and
# postgresql18.sh: packages of those names in the pool, which the arm64
# images install). The downloads, Node.js modules and native wheels are kept
# in $PGADMIN_WORK; the wheels are made again when the port or the target's
# Python changes. Build Aurora first.
PGADMIN_WORK=${PGADMIN_WORK:-$AIROS_WORK/pgadmin4}
# The Linux CPython that runs the cross build: the target's version, as
# deps/recipes/python312.sh builds with.
PGADMIN_BUILD_PYTHON_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.12.15+20261021-x86_64-unknown-linux-gnu-install_only.tar.gz
PGADMIN_BUILD_PYTHON_SHA256=5ff9f0602ce964a529ed1e8555d3abab6341926d724402ba9a15e9e877191124
# stage.sh installs the runtime's JavaScript modules with npm.
PGADMIN_NODE=24.18.0
PGADMIN_NODE_SHA256=55aa7153f9d88f28d765fcdad5ae6945b5c0f98a36881703817e4c450fa76742

build_pgadmin4() {
	note "pgAdmin 4"
	snapshot aurora pgadmin4
	local port=$SRC/ports/pgadmin4
	[[ -x $port/cross.sh ]] || die "no ports/pgadmin4/cross.sh in aurora"
	mkdir -p "$PGADMIN_WORK"
	exec {pgadmin_lock}>"$AIROS_LOCKS/pgadmin4.lock"
	flock "$pgadmin_lock"
	local python=$PGADMIN_WORK/build-python tarball
	if [[ ! -x $python/bin/python3.12 ]]; then
		tarball=$AIROS_CACHE/tarballs/${PGADMIN_BUILD_PYTHON_SHA256:0:16}-$(basename "$PGADMIN_BUILD_PYTHON_URL")
		mkdir -p "$AIROS_CACHE/tarballs"
		if [[ ! -f $tarball ]] || ! echo "$PGADMIN_BUILD_PYTHON_SHA256  $tarball" | sha256sum -c --quiet; then
			curl -fsSL --retry 3 -o "$tarball.part" "$PGADMIN_BUILD_PYTHON_URL"
			echo "$PGADMIN_BUILD_PYTHON_SHA256  $tarball.part" | sha256sum -c --quiet \
				|| die "$PGADMIN_BUILD_PYTHON_URL: wrong SHA-256"
			mv "$tarball.part" "$tarball"
		fi
		rm -rf "$python"
		mkdir -p "$python"
		tar xzf "$tarball" -C "$python" --strip-components=1
	fi
	local node
	node=$(linux_node "$PGADMIN_NODE" "$PGADMIN_NODE_SHA256")
	"$AIROS_CI/sdk/build-rust.sh" "$ARCH"
	local target
	if [[ $ARCH == arm64 ]]; then
		target=$DEPS
		[[ -f $target/develop/headers/python3.12/Python.h && -e $target/develop/lib/libpq.so ]] \
			|| die "no Python 3.12 or libpq in $DEPS: deps/build-deps.sh arm64 libffi python312 postgresql18"
	else
		target=$PGADMIN_WORK/target-$ARCH/boot/system
		[[ -e $PGADMIN_WORK/target-$ARCH ]] && "$TOOLS/rm_attrs" -rf "$PGADMIN_WORK/target-$ARCH"
		"$AIROS_CI/deps/haikuports.py" stage "$ARCH" "$target" \
			python3.12 libffi_devel postgresql18_devel openssl3_devel > /dev/null
	fi
	local host=$PGADMIN_WORK/aurora-$ARCH
	aurora_launcher "$host"
	# The native wheels of this port for this target Python.
	local key
	key=$({
		cat "$port"/cross.sh "$port"/requirements-haiku.lock "$port"/python-patches/*
		cat "$target"/develop/headers/python3.12/patchlevel.h
	} | sha256sum | cut -c1-12)
	local stage=$PGADMIN_WORK/stage log=$PGADMIN_WORK/cross-$ARCH.log out=$PGADMIN_WORK/out-$ARCH
	rm -rf "$stage" "$out"
	PATH=$node/bin:$PATH PGADMIN_DOWNLOADS=$PGADMIN_WORK/downloads \
		AIROS_SDK=$AIROS_SDK/$SDK_NAME/env.sh HAIKU_HOST_TOOLS=$TOOLS HAIKU_MIME_DB=$MIMEDB \
		AURORA_HOST_BINARY=$host/data/aurora/aurora-host TARGET_ROOT=$target \
		BUILD_PYTHON=$python/bin/python3.12 RUST_ENV=$AIROS_TOOLCHAIN/rust/env-$ARCH.sh \
		PGADMIN_WHEELHOUSE=$PGADMIN_WORK/wheels-$ARCH-$key PGADMIN_CARGO_HOME=$PGADMIN_WORK/cargo \
		TMPDIR=$PGADMIN_WORK \
		"$port/cross.sh" "$ARCH" "$stage" "$out" > "$log" 2>&1 || { tail -40 "$log"; die "pgAdmin 4 for $ARCH failed"; }
	"$TOOLS/rm_attrs" -rf "$host"
	local file version
	file=$(tail -1 "$log")
	[[ -f $file ]] || die "cross.sh made no package"
	verify_package "$file"
	rm -f "$OUT"/pgadmin4-[0-9]*-"$ARCH".hpkg
	mv "$file" "$OUT/"
	file=$OUT/$(basename "$file")
	version=$(basename "$file" | sed "s/^pgadmin4-\(.*\)-$ARCH.hpkg\$/\1/")
	echo "package:  $file"
	printf '%s\t%s\t%s\t%s\n' pgadmin4 "$file" "$version" "(none)" >> "$APPBUILD/.summary"
	flock -u "$pgadmin_lock"
}

# --- Proton Mail Bridge ------------------------------------------------------
# Qt desktop + Go engine. All source changes and toolchain pins live in the app
# fork. x86_64 links HaikuPorts' Qt, gRPC and protobuf packages. arm64, which
# HaikuPorts has none of, builds the same versions with the fork's
# tools/haiku/build-gui-deps.sh (once, kept in the host tree): Qt goes into the
# package privately (apps/ProtonMailBridge/lib, plugins and qml, where Qt's
# relocatable prefix finds them), gRPC and protobuf are linked statically.
build_proton_bridge() {
    note "Proton Mail Bridge"
    snapshot proton-bridge proton_bridge
    local work=$APPBUILD/proton_bridge
    local host=${PROTON_BRIDGE_HOST_BUILD:-$AIROS_TOOLCHAIN/proton-bridge}
    local deps goarch
    case $ARCH in
        x86_64) deps=${PROTON_BRIDGE_DEPS:-$work/deps} goarch=amd64 ;;
        arm64) deps=${PROTON_BRIDGE_DEPS:-$host/gui-deps-$SDK_NAME} goarch=arm64 ;;
    esac
    local goroot=${PROTON_BRIDGE_GOROOT:-$host/go-haiku}
    local cache=${PROTON_BRIDGE_CACHE:-$AIROS_CACHE/proton-bridge}
    local jobs=${PROTON_BRIDGE_JOBS:-8}
    local revision version stamp
    revision=$(git -C "$APPS/proton-bridge" describe --always --dirty --match "")
    stamp=$(git -C "$APPS/proton-bridge" show -s --format=%ct HEAD)
    version=$("$SRC/utils/bridge_app_version.sh")
    version=${version%%+*}~airos$stamp-1
    mkdir -p "$host" "$deps"
    (
        # Core generators and dependency prefix are shared by app builds.
        flock 8
        export BRIDGE_HOST_BUILD=$host BRIDGE_DOWNLOAD_CACHE=$cache JOBS=$jobs
        if [[ -z ${PROTON_BRIDGE_GOROOT:-} ]]; then
            "$SRC/tools/haiku/build-go-toolchain.sh"
        fi
        "$SRC/tools/haiku/build-host-tools.sh"
        if [[ $ARCH == x86_64 ]]; then
            # Package extraction restores read-only directory modes. Stage into a
            # fresh sibling so a second build cannot fail while overwriting files,
            # and only when the packages changed (haikuports.py current); rm_attrs
            # removes the old prefix's entries from the build's attribute store.
            local staged bridge_deps=(qt6_base_devel qt6_declarative_devel qt6_svg_devel
                grpc_devel protobuf_devel)
            if ! AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
                    "$AIROS_CI/deps/haikuports.py" current x86_64 "$deps" "${bridge_deps[@]}"; then
                staged=$(mktemp -d "${deps}.stage.XXXXXX")
                AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
                    "$AIROS_CI/deps/haikuports.py" stage x86_64 "$staged" "${bridge_deps[@]}"
                if [[ -d $deps ]]; then
                    [[ -f $deps/.haikuports.json || -z $(ls -A "$deps") ]] || die "refusing to replace an unrecognized Bridge dependency prefix: $deps"
                    chmod -R u+w "$deps"
                    "$TOOLS/rm_attrs" -rf "$deps"
                fi
                mv "$staged" "$deps"
            fi
        else
            # Qt's platform plugin from the pinned fork, as the x86_64 images' Qt
            fork_checkout qt6-haikuplugins "$host/qt6-haikuplugins-$SDK_NAME"
            HAIKU_SDK_ENV=$AIROS_SDK/$SDK_NAME/env.sh HAIKU_GUI_DEPS=$deps HAIKU_EXTRA_DEPS=$DEPS \
                HAIKU_QT_PLUGINS_SRC=$host/qt6-haikuplugins-$SDK_NAME "$SRC/tools/haiku/build-gui-deps.sh"
        fi
        export BRIDGE_REVISION=$revision BRIDGE_BUILD_DIR=$BUILDDIR
        (
            export GOROOT=$goroot GOPATH=$cache/gopath
            export GOCACHE=$cache/go-build GOARCH=$goarch
            export HAIKU_CROSS=${CROSS%-} HAIKU_SYSROOT=$SYSROOT
            . "$SRC/tools/haiku/env.sh"
            "$SRC/tools/haiku/build-engine.sh"
        )
        local extra=()
        [[ $ARCH == x86_64 ]] || extra=(HAIKU_GUI_EXTRA="$DEPS")
        env "${extra[@]}" HAIKU_SDK_ENV=$AIROS_SDK/$SDK_NAME/env.sh HAIKU_GUI_DEPS=$deps \
            BRIDGE_GUI_BUILD=$work/gui "$SRC/tools/haiku/build-gui.sh"
    ) 8>"$host/build.lock"
    "$TOOLS/rc/rc" -I "$SRC/dist/haiku" -o "$BUILDDIR/Bridge.rsrc" "$SRC/dist/haiku/Bridge.rdef"
    "$TOOLS/rc/rc" -I "$SRC/dist/haiku" -o "$BUILDDIR/BridgeGUI.rsrc" "$SRC/dist/haiku/BridgeGUI.rdef"
    "$TOOLS/rc/rc" -I "$SRC/dist/haiku" -o "$BUILDDIR/BridgeEngine.rsrc" "$SRC/dist/haiku/BridgeEngine.rdef"
    stage_begin
    local app=apps/ProtonMailBridge
    install_binary "$BUILDDIR/launcher" "$BUILDDIR/Bridge.rsrc" "$app/launcher"
    local gui=$BUILDDIR/Proton\ Mail\ Bridge
    if [[ $ARCH != x86_64 ]]; then
        # its private Qt, explicitly (the library path has %A/lib too); before
        # the resources go on
        cp "$gui" "$work/Proton Mail Bridge"
        gui=$work/Proton\ Mail\ Bridge
        set_rpath "$gui" "/boot/system/$app/lib"
    fi
    install_binary "$gui" "$BUILDDIR/BridgeGUI.rsrc" "$app/Proton Mail Bridge"
    install_binary "$BUILDDIR/bridge" "$BUILDDIR/BridgeEngine.rsrc" "$app/bridge"
    install_binary "$BUILDDIR/bridge-autostart" - "$app/bridge-autostart"
    install_file 644 "$SRC/LICENSE" "$app/LICENSE"
    mkdir -p "$STAGE/bin"
    ln -s ../apps/ProtonMailBridge/launcher "$STAGE/bin/proton-bridge"
    deskbar_link "$app/launcher" "Proton Mail Bridge"
    docs proton_bridge README.md LICENSE docs/haiku/README.md
    if [[ $ARCH == x86_64 ]]; then
        install_file 644 "$deps/.haikuports.json" documentation/packages/proton_bridge/build-dependencies.json
    else
        bridge_private_qt "$deps" "$app"
        install_file 644 "$deps/sources.txt" documentation/packages/proton_bridge/build-dependencies.txt
    fi
    cat > "$work/PackageInfo" <<INFO
name            proton_bridge
version         $version
architecture    $ARCH
summary         "Proton Mail IMAP and SMTP bridge"
description     "Community air/OS port of Proton Mail Bridge, with the native system key store. Built from $revision. Requires a Proton plan supporting Bridge."
packager        "air/OS CI"
vendor          "Proton AG and air/OS contributors"
copyrights { "2026 Proton AG" "2026 air/OS contributors" }
licenses { "GNU GPL v3" }
provides {
    proton_bridge = ${version%-*}
    app:ProtonMailBridge = ${version%-*}
    cmd:proton_bridge = ${version%-*}
}
requires {
    haiku >= r1~beta6
    qt6_base >= 6.10.3
    qt6_declarative >= 6.10.3
    qt6_svg >= 6.10.3
    grpc >= 1.53.0
    protobuf >= 3.20.1
}
INFO
    # arm64 carries Qt and links gRPC and protobuf; its tray icons need
    # qsystray (build_qsystray: on x86_64 qt6_base requires HaikuPorts')
    retarget_package_info "$work/PackageInfo" "$STAGE/.PackageInfo"
    [[ $ARCH == x86_64 ]] || sed -i '/^requires[[:space:]]*{/a\\tcmd:qsystray' "$STAGE/.PackageInfo"
    [[ $ARCH == x86_64 ]] && DROPPED="(none)"
    add_attributes "$BUILDDIR/Bridge.rsrc" "$app/launcher"
    resource_attributes "$BUILDDIR/BridgeGUI.rsrc" "$app/Proton Mail Bridge"
    resource_attributes "$BUILDDIR/BridgeEngine.rsrc" "$app/bridge"
    # Include this app's separate dependency prefix in the library report.
    local FARM=$work/report-deps
    mkdir -p "$FARM"
    if [[ $ARCH == x86_64 ]]; then
        ln -sfn "$deps/develop/lib" "$FARM/lib"
    else
        # what the package carries, and the image's GL stack
        local lib
        rm -rf "$FARM/lib"
        mkdir -p "$FARM/lib"
        for lib in "$STAGE/$app"/lib/*.so.* "$DEPS/lib/libGL.so.1"; do
            ln -sfn "$lib" "$FARM/lib/$(basename "${lib%%.so*}").so"
        done
    fi
    finish_package proton_bridge "$app/launcher" "$app/bridge" "$app/Proton Mail Bridge"
    [[ $ARCH == x86_64 ]] || build_qsystray
}

# The Haiku Qt platform plugin shows tray icons through /bin/qsystray, which
# HaikuPorts packages on its own (qsystray, which its qt6_base requires) for
# x86_64 only: on arm64 the same release, as the same package, beside Bridge's.
QSYSTRAY_VERSION=5.15.2.14
QSYSTRAY_SHA256=6156338b7b523c4045b54e3a2e5af99d07def72842083a01758bbdf5799cba27
build_qsystray() {
    note "qsystray $QSYSTRAY_VERSION"
    local work=$APPBUILD/qsystray tool signature
    local tarball=$AIROS_CACHE/tarballs/qthaikuplugins-$QSYSTRAY_VERSION.tar.gz
    mkdir -p "$work" "$AIROS_CACHE/tarballs"
    if [[ ! -f $tarball ]]; then
        curl -fsSL --retry 3 -o "$tarball.part" \
            "https://github.com/threedeyes/qthaikuplugins/archive/$QSYSTRAY_VERSION.tar.gz"
        mv "$tarball.part" "$tarball"
    fi
    echo "$QSYSTRAY_SHA256  $tarball" | sha256sum -c --quiet - || die "$tarball: wrong SHA-256"
    rm -rf "$work/src"
    mkdir -p "$work/src"
    tar -xzf "$tarball" -C "$work/src" --strip-components=1
    # as tools/qsystray and tools/qnotify's Makefiles build them
    for tool in qsystray qnotify; do
        case $tool in
            qsystray) signature=application/x-vnd.QtSystrayManager ;;
            qnotify) signature=application/x-vnd.qnotify-gate ;;
        esac
        $CXX_T -O2 -DAPP_SIGNATURE="\"$signature\"" "$work/src/tools/$tool/$tool.cpp" \
            -ltracker -lbe -o "$work/$tool"
        "$TOOLS/rc/rc" -o "$work/$tool.rsrc" "$work/src/tools/$tool/$tool.rdef"
    done
    stage_begin
    for tool in qsystray qnotify; do
        install_binary "$work/$tool" "$work/$tool.rsrc" "bin/$tool"
    done
    install_file 644 "$work/src/LICENSE" documentation/packages/qsystray/LICENSE
    cat > "$STAGE/.PackageInfo" <<INFO
name            qsystray
version         $QSYSTRAY_VERSION-1
architecture    $ARCH
summary         "Deskbar shelf helper for Qt applications"
description     "Qt system tray tools for interaction with Deskbar shelf (threedeyes/qthaikuplugins $QSYSTRAY_VERSION, as HaikuPorts packages it), built by air/OS CI."
packager        "air/OS CI"
vendor          "Haiku Project"
copyrights { "2012-2021 Gerasim Troeglazov" }
licenses { "GNU LGPL v2.1" "GNU LGPL v3" }
provides {
    qsystray = $QSYSTRAY_VERSION
    cmd:qsystray = $QSYSTRAY_VERSION
    cmd:qnotify = $QSYSTRAY_VERSION
}
requires {
    haiku >= r1~beta6
}
INFO
    DROPPED="(none)"
    # the tools are applications in bin/
    local APP_PATHS='^(apps|add-ons)/|^bin/q(systray|notify)$'
    add_attributes "$work/qsystray.rsrc" bin/qsystray
    resource_attributes "$work/qnotify.rsrc" bin/qnotify
    finish_package qsystray bin/qsystray bin/qnotify
}

# bridge_private_qt PREFIX APP: the Qt of PREFIX (build-gui-deps.sh) that the
# interface uses, in APP's lib/ (Haiku's library path has the application's
# lib/), plugins/ and qml/ (Qt's relocatable prefix is lib/.., and qt.conf
# says the same): the platform plugin, image formats, icon engines and TLS
# backends, the QML modules the interface imports (qmlimportscanner) and the
# libraries all of them need.
bridge_private_qt() {
    local prefix=$1 app=$2 dir module needed lib item
    local root=$STAGE/$app hostqt
    hostqt=$(compgen -G "${PROTON_BRIDGE_HOST_BUILD:-$AIROS_TOOLCHAIN/proton-bridge}/qt-6.*" | head -n 1)
    [[ -x $hostqt/libexec/qmlimportscanner ]] || die "no host qmlimportscanner in $hostqt (build-gui-deps.sh)"
    mkdir -p "$root/lib" "$root/plugins" "$root/qml"
    for dir in platforms imageformats iconengines tls; do
        [[ -d $prefix/plugins/$dir ]] && cp -R "$prefix/plugins/$dir" "$root/plugins/"
    done
    [[ -f $root/plugins/platforms/libqhaiku.so ]] || die "no Haiku platform plugin in $prefix"
    "$hostqt/libexec/qmlimportscanner" -rootPath "$SRC/internal/frontend/bridge-gui/bridge-gui/qml" \
        -importPath "$prefix/qml" > "$APPBUILD/proton_bridge/qml-imports.json"
    while IFS= read -r module; do
        [[ -n $module ]] || continue
        mkdir -p "$root/qml/$module"
        rsync -a --exclude='*.qmltypes' --exclude='plugins.qmltypes' "$prefix/qml/$module/" "$root/qml/$module/"
    done < <(python3 - "$prefix/qml" "$APPBUILD/proton_bridge/qml-imports.json" <<'PY'
import json, os, sys
base = os.path.realpath(sys.argv[1])
paths = set()
for entry in json.load(open(sys.argv[2])):
    path = os.path.realpath(entry.get("path", ""))
    if entry.get("type") == "module" and path.startswith(base + "/"):
        paths.add(os.path.relpath(path, base))
# a module's directory holds its child modules: copy each tree once
for path in sorted(paths):
    if not any(path.startswith(other + "/") for other in paths):
        print(path)
PY
)
    [[ -d $root/qml/QtQuick/Controls ]] || die "qmlimportscanner found no QtQuick.Controls"
    printf '[Paths]\nPrefix=.\n' > "$root/qt.conf"
    # the libraries, from the interface and everything Qt loads into it
    local pending=("$app/Proton Mail Bridge")
    while IFS= read -r -d '' item; do
        pending+=("${item#"$STAGE/"}")
    done < <(find "$root/plugins" "$root/qml" -name '*.so' -print0)
    declare -A seen=()
    while [[ ${#pending[@]} -gt 0 ]]; do
        item=${pending[0]}
        pending=("${pending[@]:1}")
        for needed in $(readelf -d "$STAGE/$item" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
            [[ -n ${seen[$needed]:-} ]] && continue
            seen[$needed]=1
            lib=$prefix/lib/$needed
            [[ -e $lib ]] || continue
            cp "$(readlink -f "$lib")" "$root/lib/$needed"
            pending+=("$app/lib/$needed")
        done
    done
    find "$root/lib" "$root/plugins" "$root/qml" -name '*.so*' -type f -exec chmod 644 {} + \
        -exec "$STRIP" --strip-unneeded {} +
}

# --- Mail -------------------------------------------------------------------
# air/OS's Mail (airos-works/mail) replaces Haiku's: the image leaves Haiku's Mail
# out, this package installs apps/Mail with Haiku's Mail icon, its Deskbar
# entry and a post-install script that opens email messages and mailto links
# in it. It reads messages with the Summit engine (summit_webkit).

# mail_arm64_deps ROOT: arm64 has no HaikuPorts libraries. Mail links ICU 74
# from the Haiku base (the SDK's, as on x86_64), and the libraries the Summit
# engine carries (libxml2, HarfBuzz, curl, OpenSSL and SQLite in
# /boot/system/lib/summit-webkit/lib, which is Mail's RPATH), so the process
# has one copy of each, with their headers from the engine's deps prefix; GNU
# libiconv from DEPS (airos_libiconv); and HarfBuzz's subsetter, which the
# engine does not build, as a static library from the engine's HarfBuzz
# commit. ROOT/boot/system holds only these.
mail_arm64_deps() {
	local root=$1/boot/system name file header hb=$APPBUILD/.harfbuzz-subset commit
	rm -rf "$1"
	mkdir -p "$root/develop/headers" "$root/develop/lib" "$hb"
	for header in libxml2 curl openssl sqlite3.h sqlite3ext.h; do
		[[ -e $SUMMIT_LIBS/include/$header ]] || die "no $header in $SUMMIT_LIBS/include (summit/build-deps.sh arm64)"
		ln -s "$SUMMIT_LIBS/include/$header" "$root/develop/headers/"
	done
	for name in xml2 harfbuzz curl ssl crypto sqlite3; do
		file=$(compgen -G "$SUMMIT_ENGINE/lib/lib$name.so*" | sort | head -n 1 || true)
		[[ -n $file ]] || die "no lib$name in $SUMMIT_ENGINE/lib (summit_webkit not staged)"
		ln -s "$file" "$root/develop/lib/lib$name.so"
	done
	for header in iconv.h libcharset.h localcharset.h; do
		[[ -e $DEPS/develop/headers/$header ]] || die "no $header in $DEPS (deps/build-deps.sh arm64 libiconv)"
		ln -s "$DEPS/develop/headers/$header" "$root/develop/headers/"
	done
	ln -s "$DEPS/lib/libiconv.so.2" "$root/develop/lib/libiconv.so"
	commit=$(fork_info harfbuzz commit)
	if [[ $(cat "$hb/commit" 2>/dev/null) != "$commit" ]]; then
		fork_checkout harfbuzz "$hb/src"
		rm -rf "$hb/build" "$hb/install"
		printf '%s\n' "set(CMAKE_SYSTEM_NAME Haiku)" "set(CMAKE_SYSTEM_PROCESSOR $CMAKE_PROCESSOR)" \
			"set(CMAKE_SYSROOT $SYSROOT)" "set(CMAKE_C_COMPILER ${CROSS}gcc)" \
			"set(CMAKE_CXX_COMPILER ${CROSS}g++)" "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)" \
			"set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)" "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)" \
			> "$hb/toolchain.cmake"
		cmake -S "$hb/src" -B "$hb/build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$hb/toolchain.cmake" \
			-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
			-DCMAKE_INSTALL_PREFIX="$hb/install" -DHB_BUILD_SUBSET=ON -DHB_BUILD_UTILS=OFF \
			-DHB_HAVE_FREETYPE=OFF -DHB_HAVE_ICU=OFF -DHB_HAVE_GLIB=OFF -DHB_HAVE_GOBJECT=OFF >/dev/null
		cmake --build "$hb/build" -j"$JOBS" >/dev/null
		cmake --install "$hb/build" >/dev/null
		echo "$commit" > "$hb/commit"
	fi
	# The engine's HarfBuzz headers are this commit's; the subsetter's come with them.
	cp -R "$hb/install/include/harfbuzz" "$root/develop/headers/"
	cp "$hb/install/lib/libharfbuzz-subset.a" "$root/develop/lib/"
}

build_airos_mail() {
	note Mail
	snapshot mail airos_mail
	local work=$APPBUILD/airos_mail stamp version staged
	stamp=$(TZ=UTC git -C "$APPS/mail" show -s --format=%cd --date=format-local:%Y%m%d.%H%M HEAD)
	version=0.1.0~git$stamp-1
	if [[ $ARCH == x86_64 ]]; then
		# The HaikuPorts development packages it links, as a root of their own,
		# staged again only when they changed (haikuports.py current); rm_attrs
		# removes the old root's entries from the build's attribute store.
		local mail_deps=(sqlite_devel libiconv_devel curl_devel openssl3_devel
			libxml2_devel icu74_devel harfbuzz_devel)
		if ! AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" \
				current x86_64 "$work/deps/boot/system" "${mail_deps[@]}"; then
			staged=$(mktemp -d "$work/deps.XXXXXX")
			AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" stage x86_64 \
				"$staged/boot/system" "${mail_deps[@]}"
			if [[ -e $work/deps ]]; then
				chmod -R u+w "$work/deps"
				"$TOOLS/rm_attrs" -rf "$work/deps"
			fi
			mv "$staged" "$work/deps"
		fi
	else
		mail_arm64_deps "$work/deps"
	fi
	local libs=$work/deps/boot/system
	MAIL_CXX=${CROSS}g++ MAIL_SYSROOT=$SYSROOT MAIL_TOOLS=$TOOLS MAIL_BUILD=$BUILDDIR \
		MAIL_BUILD_TYPE=Release MAIL_EXTRA_ROOTS=$work/deps \
		MAIL_CXX_FLAGS="-Wl,-rpath-link,$libs/lib -Wl,-rpath-link,$libs/develop/lib -Wl,-rpath-link,$SUMMIT_ENGINE/lib" \
		MAIL_WEBKIT_LIBRARY=$SUMMIT_ENGINE/lib/libWebKit.so.1 MAIL_WEBKIT_INCLUDE_DIR=$SUMMIT_WEBKIT_HEADERS \
		MAIL_CMAKE_ARGS=-DBUILD_TESTING=OFF JOBS=$JOBS bash "$SRC/tools/cross-build.sh"
	stage_begin
	cmake --install "$BUILDDIR" --prefix "$STAGE" >/dev/null
	local binary
	for binary in apps/Mail lib/mail/MailPreview; do
		# GNU strip drops the appended resources: the app's and its fonts and icons.
		"$STRIP" --strip-debug "$STAGE/$binary"
		"$TOOLS/xres" -o "$STAGE/$binary" "$BUILDDIR/$(basename "$binary").fonts.rsrc" \
			"$BUILDDIR/$(basename "$binary").rsrc"
	done
	sed -e "s/@VERSION@/$version/g" -e "s/@SHORT_VERSION@/${version%-*}/g" -e "s/@ARCH@/$ARCH/g" \
		"$SRC/resources/Mail.PackageInfo.in" > "$work/Mail.PackageInfo"
	# arm64 keeps the engine, which its images have
	retarget_package_info "$work/Mail.PackageInfo" "$STAGE/.PackageInfo" '^summit_webkit'
	deskbar_link apps/Mail Mail
	install_file 644 "$SRC/third_party/noto-emoji/OFL.txt" "data/licenses/Mail Noto Emoji OFL 1.1"
	install_file 755 "$SRC/resources/mail-post-install.sh" boot/post-install/mail-default-email.sh
	[[ ! -f $libs/.haikuports.json ]] \
		|| install_file 644 "$libs/.haikuports.json" documentation/packages/airos_mail/build-dependencies.json
	add_attributes "$BUILDDIR/Mail.rsrc" apps/Mail
	resource_attributes "$BUILDDIR/MailPreview.rsrc" lib/mail/MailPreview
	# The preview helper is an application outside apps/.
	local APP_PATHS='^(apps|add-ons|lib/mail)/'
	local FARM=$work/report-deps
	mkdir -p "$FARM"
	ln -sfn "$libs/develop/lib" "$FARM/lib"
	finish_package airos_mail apps/Mail lib/mail/MailPreview
}

# --- Proton VPN -------------------------------------------------------------
# airos-works/proton-vpn-airos-app: the native app, its userspace WireGuard helper,
# the command-line client and proton-openvpn, staged as its
# tools/package-haiku.sh does. proton-openvpn is OpenVPN 2.6.13 from the
# upstream tarball with the patches in the repository's openvpn/ (as its
# openvpn/build.sh, cross-compiled); without LZO and LZ4, which Proton does
# not use. arm64 links OpenSSL statically into it, as Burrow's.
build_proton_vpn() {
	note "Proton VPN"
	snapshot proton-vpn-airos-app proton_vpn
	local private=$SYSROOT/boot/system/develop/headers/private
	local version=2.6.13 sum=730ad13ab0d8efda24b7e8e0df660e4c358ad89105aca47f2bf26da44d8ab020
	local tarball=$AIROS_CACHE/openvpn-$version.tar.gz ovpn=$APPBUILD/proton_vpn/openvpn-src
	if [[ ! -f $tarball ]]; then
		curl -fsSL -o "$tarball.part" "https://github.com/OpenVPN/openvpn/archive/refs/tags/v$version.tar.gz"
		mv "$tarball.part" "$tarball"
	fi
	echo "$sum  $tarball" | sha256sum -c - >/dev/null || die "$tarball: wrong SHA-256"
	rm -rf "$ovpn"
	mkdir -p "$ovpn"
	tar xzf "$tarball" -C "$ovpn" --strip-components=1
	local patch
	for patch in "$SRC"/openvpn/patches/0*.patch*; do
		patch -d "$ovpn" -p1 -s < "$patch"
	done
	( cd "$ovpn" && autoreconf -fi >/dev/null 2>&1 )
	local ssl_libs="-L$FARM/lib -lssl -lcrypto"
	# configure probes for LZO even with --disable-lzo, and fails on the
	# x86_64 farm's liblzo2 without its headers: say there is none.
	[[ $ARCH == arm64 ]] && ssl_libs="$DEPS/develop/lib/libssl.a $DEPS/develop/lib/libcrypto.a"
	( cd "$ovpn" && ./configure -q --host="$TRIPLET" --build=x86_64-pc-linux-gnu \
		CC="$CC_T" CPPFLAGS="-I$FARM/include" \
		OPENSSL_CFLAGS="-I$FARM/include" OPENSSL_LIBS="$ssl_libs" LDFLAGS="-lnetwork" \
		IFCONFIG=/boot/system/bin/ifconfig ROUTE=/boot/system/bin/route \
		NETSTAT=/boot/system/bin/netstat IPROUTE=/bin/false \
		--disable-lzo --disable-lz4 --disable-plugins --disable-pkcs11 --disable-debug \
		--disable-unit-tests ac_cv_lib_lzo2_lzo1x_1_15_compress=no \
		ac_cv_lib_lzo_lzo1x_1_15_compress=no >/dev/null )
	make -C "$ovpn" -s -j"$JOBS" >/dev/null
	cp "$ovpn/src/openvpn/openvpn" "$BUILDDIR/proton-openvpn"

	# The app's link and resource steps run the Haiku tools by name; link here.
	CPATH=$(FARM_CPATH) make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH TARGET_OS=Haiku \
		CXX="$CXX_T" CC="$CC_T" UI_CPPFLAGS="-I$private/interface" objects tools
	( cd "$SRC" && $CXX_T -o "$BUILDDIR/ProtonVPN" "$BUILDDIR"/src/core/*.o \
		"$BUILDDIR"/third_party/crypt_blowfish/*.o "$BUILDDIR"/src/ui/*.o "$BUILDDIR/src/main.o" \
		-lbe -ltracker -ltranslation -lcurl -lssl -lcrypto -lnetwork -Wl,--export-dynamic )
	( cd "$SRC" && "$TOOLS/rc/rc" -I resources -o "$BUILDDIR/ProtonVPN.rsrc" \
		resources/ProtonVPN.rdef resources/Assets.rdef )

	stage_begin
	local app="apps/Proton VPN"
	install_binary "$BUILDDIR/ProtonVPN" "$BUILDDIR/ProtonVPN.rsrc" "$app/Proton VPN"
	install_binary "$BUILDDIR/proton-wireguard" - "$app/helpers/proton-wireguard"
	install_binary "$BUILDDIR/proton-openvpn" - "$app/helpers/proton-openvpn"
	install_binary "$BUILDDIR/proton-vpn-cli" - bin/proton-vpn-cli
	docs proton_vpn README.md LICENSE docs
	# OpenVPN is GPL 2: ship how proton-openvpn was made next to the binary.
	mkdir -p "$STAGE/documentation/packages/proton_vpn/openvpn"
	cp -R "$SRC/openvpn/patches" "$SRC/openvpn/build.sh" "$SRC/openvpn/SOURCE.md" \
		"$STAGE/documentation/packages/proton_vpn/openvpn/"
	deskbar_link "$app/Proton VPN" "Proton VPN"
	retarget_package_info "$SRC/resources/ProtonVPN.PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/ProtonVPN.rsrc" "$app/Proton VPN"
	finish_package proton_vpn "$app/Proton VPN" "$app/helpers/proton-wireguard" \
		"$app/helpers/proton-openvpn" bin/proton-vpn-cli
}

# --- Office and Media applications ------------------------------------------
# The Craft applications share a native Be API host and Rust build. Build std
# with each app so its release profile's LTO has the matching bitcode.
# build_craft <repository> <binary> <Deskbar folder>
build_craft() {
	local app=$1 binary=$2 folder=$3
	note "$binary"
	snapshot "$app" "$app"
	"$AIROS_CI/sdk/build-rust.sh" "$ARCH"
	. "$AIROS_TOOLCHAIN/rust/env-$ARCH.sh"
	local res=$SRC/apps/$app-haiku/resources triple=${RUST_TARGET//-/_}
	local crates=(-p "$app-haiku") binaries=("apps/$binary")
	[[ $app != pdfcraft ]] || crates+=(-p pdfcraft-cli)
	# Cargo takes a linker without arguments: wrappers carry the sysroot.
	printf '#!/bin/sh\nexec %s "$@"\n' "$CC_T" > "$HOSTBIN/craft-cc"
	printf '#!/bin/sh\nexec %s "$@"\n' "$CXX_T" > "$HOSTBIN/craft-c++"
	chmod 755 "$HOSTBIN/craft-cc" "$HOSTBIN/craft-c++"
	(
		cd "$SRC"
		export CARGO_TARGET_DIR=$BUILDDIR/target
		export "CARGO_TARGET_${triple^^}_LINKER=$HOSTBIN/craft-cc"
		export "CC_$triple=$HOSTBIN/craft-cc" "CXX_$triple=$HOSTBIN/craft-c++"
		export "AR_$triple=${CROSS}ar" "RANLIB_$triple=${CROSS}ranlib"
		if [[ $app == pdfcraft && $ARCH == arm64 ]]; then
			# AWS-LC has no Haiku ARM64 runtime capability probe. Its static
			# path uses only the compiler's ARMv8-A baseline (including NEON),
			# without assuming optional AES/SHA instructions on every board.
			export AWS_LC_SYS_CFLAGS_aarch64_unknown_haiku='-DOPENSSL_STATIC_ARMCAP -march=armv8-a'
		fi
		if [[ $app == lightcraft || $app == photocraft ]]; then
			# LightCraft's and PhotoCraft's releases embed the craft-fonts
			# collection (pinned beside them in media.lock.json), as their
			# tools/haiku/build.sh do.
			export CRAFT_FONTS_DIR=$CRAFT_FONTS CRAFT_FONTS_REQUIRED=1
		fi
		# The snapshot has no .git; identify the source used by --version.
		export "${app^^}_BUILD_SHA=$(git -C "$APPS/$app" rev-parse HEAD)"
		cargo build --release --locked --target "$RUST_TARGET" -Zbuild-std=std,panic_abort \
			-j "$JOBS" "${crates[@]}"
	)
	(cd "$res" && "$TOOLS/rc/rc" -o "$BUILDDIR/$binary.rsrc" "$binary.rdef")
	stage_begin
	install_binary "$BUILDDIR/target/$RUST_TARGET/release/$binary" "$BUILDDIR/$binary.rsrc" "apps/$binary"
	docs "$app" README.md LICENSE-MIT LICENSE-APACHE NOTICE docs/haiku.md ATTRIBUTION.md ATTRIBUTION.toml
	install_file 755 "$res/$app-post-install.sh" "boot/post-install/$app.sh"
	deskbar_link "apps/$binary" "$binary" "$folder"
	retarget_package_info "$res/$binary.PackageInfo" "$STAGE/.PackageInfo"
	local license
	case $app in
	pdfcraft)
		install_binary "$BUILDDIR/target/$RUST_TARGET/release/pdfcraft-cli" - bin/pdfcraft-cli
		binaries+=(bin/pdfcraft-cli)
		# Keep the embedded fonts, icons and colour profile licences, as in
		# the application's own tools/haiku/package.sh.
		while IFS= read -r license; do
			install_file 644 "$SRC/$license" "documentation/packages/$app/licenses/$license"
		done < <(awk -F '\"' '/^licence_file = / { print $2 }' "$SRC/ATTRIBUTION.toml" | sort -u)
		# hayro-cmap is vendored since PdfCraft 0.15: its licence is in the list above.
		;;
	photocraft|lightcraft)
		# The licences of the assets, fonts and vendored crates the editor
		# embeds, as in the application's own tools/haiku/package.sh.
		local dirs=(assets crates vendor "apps/$app-haiku" tools/haiku)
		[[ $app != lightcraft ]] || dirs+=(apps/lightcraft-haiku-host)
		while IFS= read -r license; do
			install_file 644 "$SRC/$license" "documentation/packages/$app/licenses/$license"
		done < <(cd "$SRC" && find "${dirs[@]}" -type f -regextype posix-extended \
			-regex '(.*/)?(LICENSE|OFL|COPYING)[^/]*' | sort)
		if [[ $app == lightcraft ]]; then
			install_file 644 "$SRC/docs/haiku-validation.json" "documentation/packages/$app/haiku-validation.json"
			install_file 644 "$SRC/assets/ATTRIBUTION.md" "documentation/packages/$app/ASSET-ATTRIBUTION.md"
			install_file 644 "$SRC/apps/lightcraft-haiku/ATTRIBUTION.md" \
				"documentation/packages/$app/NATIVE-ATTRIBUTION.md"
		fi
		while IFS= read -r license; do
			install_file 644 "$CRAFT_FONTS/$license" "documentation/packages/$app/licenses/craft-fonts/$license"
		done < <(cd "$CRAFT_FONTS" && find . -name .git -prune -o -type f -regextype posix-extended \
			-regex '(.*/)?(LICENSE|OFL|COPYING)[^/]*' -printf '%P\n' | sort)
		;;
	esac
	case $app in
	*)
		# egui's default fonts come from whichever egui the lock file names
		# (crates.io before 0.37, the storytold/egui git fork since).
		local version source fonts
		read -r version source < <(awk -F '"' '/^name = "epaint_default_fonts"$/ { found = 1; next }
			found && /^version = / { v = $2 } found && /^source = / { print v, $2; exit }' "$SRC/Cargo.lock")
		case $source in
		git+*) fonts=$(echo "$CARGO_HOME"/git/checkouts/egui-*/"${source: -40:7}"/crates/epaint_default_fonts) ;;
		*) fonts=$(echo "$CARGO_HOME"/registry/src/*/"epaint_default_fonts-$version") ;;
		esac
		for license in "$fonts"/fonts/*.txt; do
			install_file 644 "$license" "documentation/packages/$app/licenses/epaint_default_fonts/$(basename "$license")"
		done
		;;
	esac
	# The print backends render PDFs with hayro, which embeds Foxit fonts,
	# Adobe CMaps and colour profiles. PdfCraft vendors it (its licences are
	# in ATTRIBUTION.toml above); the others take it from crates.io.
	local crate
	for crate in hayro-cmap hayro-interpret hayro-jpeg2000; do
		read -r version source < <(awk -F '"' -v name="$crate" '$0 == "name = \"" name "\"" { found = 1; next }
			found && /^version = / { v = $2 } found && /^source = / { print v, $2; exit }
			found && /^$/ { exit }' "$SRC/Cargo.lock") || continue
		[[ $source == registry+* ]] || continue
		for license in "$CARGO_HOME"/registry/src/*/"$crate-$version"/assets/*LICENSE*; do
			install_file 644 "$license" "documentation/packages/$app/licenses/$crate/$(basename "$license")"
		done
	done
	add_attributes "$BUILDDIR/$binary.rsrc" "apps/$binary"
	finish_package "$app" "${binaries[@]}"
}

build_wordcraft() { build_craft wordcraft WordCraft Office; }
build_gridcraft() { build_craft gridcraft GridCraft Office; }
build_deckcraft() { build_craft deckcraft DeckCraft Office; }
build_pdfcraft() { build_craft pdfcraft PdfCraft Office; }
build_photocraft() {
	[[ -f $CRAFT_FONTS/fonts/manifest.txt ]] || die "no craft-fonts checkout at $CRAFT_FONTS (CRAFT_FONTS)"
	build_craft photocraft PhotoCraft Media
}
build_lightcraft() {
	[[ -f $CRAFT_FONTS/fonts/manifest.txt ]] || die "no craft-fonts checkout at $CRAFT_FONTS (CRAFT_FONTS)"
	build_craft lightcraft LightCraft Media
}

# --- Docker: the CLI, the Engine, containerd, the buildx plugin ---------------
# Four pure-Go repositories, dependencies vendored with the Haiku shims in
# vendor/, cross-compiled with CGO disabled by the air/OS Go toolchain
# (toolchain/go-haiku: the gen2brain/go fork with the air/OS syscall
# extensions). The CLI (airos-works/docker) is this job's checkout; the
# Engine (airos-works/moby, dockerd), containerd (the daemon and the Haiku
# OCI shim, installed as containerd-shim-runc-v2) and the buildx plugin come
# from the forks pinned in forks/forks.lock.json. Every .PackageInfo is the
# heredoc of the repository's own packaging script, like Natter's.
GO_HAIKU_TOOLCHAIN=${GO_HAIKU_TOOLCHAIN:-$AIROS_TOOLCHAIN/go-haiku}
DOCKER_GOPATH=$APPBUILD/docker/gopath
DOCKER_GOCACHE=$APPBUILD/docker/go-cache

docker_go_build() { # docker_go_build GOARCH OUT PACKAGE_DIR [go build flags...]
	local goarch=$1 out=$2 dir=$3
	shift 3
	mkdir -p "$DOCKER_GOPATH" "$DOCKER_GOCACHE" "$(dirname "$out")"
	(
		cd "$dir"
		export GOOS=haiku GOARCH=$goarch CGO_ENABLED=0
		export GOFLAGS=-mod=vendor GOPROXY=off
		export GOROOT=$GO_HAIKU_TOOLCHAIN GOPATH=$DOCKER_GOPATH GOCACHE=$DOCKER_GOCACHE
		"$GO_HAIKU_TOOLCHAIN/bin/go" build -trimpath -ldflags="-s -w" -o "$out" "$@"
	)
}

# <highest tag>~git.<commits ahead>.<short HEAD>: the version scheme the
# docker repositories' own packaging scripts compute.
docker_checkout_version() { # docker_checkout_version GIT_DIR TAG_GLOB
	local dir=$1 glob=$2 tag
	tag=$(git -C "$dir" tag -l "$glob" --sort=-v:refname | head -1)
	[[ -n $tag ]] || tag=v0.0.0
	echo "${tag#v}~git.$(git -C "$dir" rev-list --count "$tag"..HEAD 2>/dev/null || echo 0).$(git -C "$dir" rev-parse --short HEAD)"
}

# The .PackageInfo heredoc of a docker repository's own packaging script,
# evaluated with VERSION set.
docker_package_info() { # docker_package_info PACKAGING_SCRIPT VERSION OUT
	local script=$1 version=$2 out=$3 delim template=$APPBUILD/docker/PackageInfo.template
	mkdir -p "$APPBUILD/docker"
	delim=$(sed -n 's/^[ \t]*cat > "\$STAGE\/.PackageInfo" <<\([A-Z][A-Z]*\)$/\1/p' "$script")
	[[ -n $delim ]] || die "no .PackageInfo heredoc in $script"
	sed -n "/^[ \t]*cat > \"\\\$STAGE\/.PackageInfo\" <<$delim\$/,/^$delim\$/p" "$script" | sed '1d;$d' > "$template"
	[[ -s $template ]] || die "empty .PackageInfo heredoc in $script"
	VERSION=$version bash -c 'eval "cat <<PKGEOF
$(cat "$1")
PKGEOF"' _ "$template" > "$out"
}

build_docker() {
	note "Docker (CLI, engine, containerd, buildx)"
	local goarch=${ARCH/x86_64/amd64} work=$APPBUILD/docker
	[[ -x $GO_HAIKU_TOOLCHAIN/bin/go ]] \
		|| die "no air/OS Go toolchain at $GO_HAIKU_TOOLCHAIN"
	mkdir -p "$work"

	# The CLI from this job's checkout. docker/cli vendors its deps and ships
	# no go.mod (vendor.mod instead); materialize one, as its own build script.
	snapshot docker docker
	local cli_version
	cli_version=$(tr -d ' \n' < "$SRC/VERSION")
	[[ -f $SRC/go.mod ]] || cp "$SRC/vendor.mod" "$SRC/go.mod"
	docker_go_build "$goarch" "$BUILDDIR/docker" "$SRC" ./cmd/docker
	stage_begin
	install_binary "$BUILDDIR/docker" - bin/docker
	install_file 644 "$SRC/README.md" documentation/packages/docker_cli/README.md
	install_file 644 "$SRC/docs/airos.md" documentation/packages/docker_cli/airos.md
	docker_package_info "$SRC/tools/package-haiku-cross.sh" "$cli_version" "$work/cli.PackageInfo"
	# VERSION only changes with docker/cli releases: the revision counts the
	# commits since, so every build is newer than the last (pkgman cannot
	# replace a package by one of the same name).
	local cli_rev
	cli_rev=$(( $(git -C "$APPS/docker" rev-list --count \
		"$(git -C "$APPS/docker" log -1 --format=%H -- VERSION)..HEAD") + 1 ))
	sed -i "s/^version .*/version $cli_version-$cli_rev/" "$work/cli.PackageInfo"
	retarget_package_info "$work/cli.PackageInfo" "$STAGE/.PackageInfo"
	finish_package docker_cli bin/docker

	# The Engine: dockerd from the pinned moby fork, with a user session job
	# for launch_daemon that starts it at boot when start_at_boot is true in
	# ~/config/settings/docker_engine (a flattened BMessage; Docker Desktop's
	# "Start the Docker Engine at boot" check box writes it). The repository's
	# own script stages a launch script under boot/home in the package, where
	# nothing runs it. Revision 2: the first package with the job.
	local moby=$work/moby version
	fork_checkout moby "$moby"
	version=$(docker_checkout_version "$moby" 'v*')
	docker_go_build "$goarch" "$work/dockerd" "$moby" ./cmd/dockerd
	stage_begin
	install_binary "$work/dockerd" - bin/dockerd
	install_file 644 "$moby/docs/airos.md" documentation/packages/docker_engine/airos.md
	cat > "$work/dockerd.launch" <<'LAUNCH'
job x-vnd.airos-docker-engine {
	env /system/boot/SetupEnvironment
	launch /boot/system/bin/dockerd --userland-proxy=false
	if setting ~/config/settings/docker_engine start_at_boot
	on initial_volumes_mounted
	no_safemode
}
LAUNCH
	install_file 644 "$work/dockerd.launch" data/user_launch/docker_engine
	docker_package_info "$moby/tools/package-haiku-cross.sh" "$version" "$work/engine.PackageInfo"
	sed -i "s/^version .*/version $version-2/" "$work/engine.PackageInfo"
	retarget_package_info "$work/engine.PackageInfo" "$STAGE/.PackageInfo" '^(containerd|docker_cli)$'
	finish_package docker_engine bin/dockerd

	# containerd: the daemon and the Haiku OCI shim, installed under the name
	# the runtime asks containerd for.
	local containerd=$work/containerd
	fork_checkout containerd "$containerd"
	version=$(docker_checkout_version "$containerd" 'v2.*')
	docker_go_build "$goarch" "$work/containerd-bin" "$containerd" ./cmd/containerd
	docker_go_build "$goarch" "$work/containerd-shim-runc-v2" "$containerd" ./cmd/containerd-shim-haiku-v2
	docker_go_build "$goarch" "$work/containerd-linuxvm" "$containerd" ./cmd/containerd-linuxvm
	stage_begin
	install_binary "$work/containerd-bin" - bin/containerd
	install_binary "$work/containerd-shim-runc-v2" - bin/containerd-shim-runc-v2
	install_binary "$work/containerd-linuxvm" - bin/containerd-linuxvm
	install_file 644 "$containerd/docs/airos.md" documentation/packages/containerd/airos.md
	docker_package_info "$containerd/tools/package-haiku-cross.sh" "$version" "$work/containerd.PackageInfo"
	retarget_package_info "$work/containerd.PackageInfo" "$STAGE/.PackageInfo"
	finish_package containerd bin/containerd bin/containerd-shim-runc-v2 bin/containerd-linuxvm

	# The Linux VM that runs containers from Linux images (airos-works/linuxvm):
	# QEMU for air/OS (NVMM on x86_64; TCG emulation on arm64, which has no
	# hypervisor, with its own GLib and libslirp) and virtio-9p, the VM's
	# kernel, and an Alpine initramfs whose init is containerd's
	# containerd-linuxvm-agent, built with the repository's own scripts.
	{
		local linuxvm=$work/linuxvm lvm_build=$work/linuxvm-build-$ARCH
		fork_checkout linuxvm "$linuxvm"
		version=0.1.0~git.$(git -C "$linuxvm" rev-list --count HEAD).$(git -C "$linuxvm" rev-parse --short HEAD)
		lvm() { # lvm STEP [ARGS...]: one of the repository's build scripts
			env ARCH="$ARCH" LINUXVM_BUILD="$lvm_build" LINUXVM_CACHE="$AIROS_CACHE/linuxvm" \
				AIROS_SDK="$AIROS_SDK" AIROS_CI="$AIROS_CI" AIROS_CACHE="$AIROS_CACHE" JOBS="$JOBS" \
				AIROS_DEPS="$DEPS" \
				bash "$linuxvm/tools/$1.sh" "${@:2}" >/dev/null || die "linuxvm: $1 failed"
		}
		lvm build-qemu
		lvm build-kernel
		lvm build-agent "$containerd"
		lvm build-initramfs
		stage_begin
		local qemu=qemu-system-${ARCH/arm64/aarch64}
		install_binary "$lvm_build/$qemu" - "lib/linuxvm/$qemu"
		install_file 644 "$lvm_build/vmlinuz" data/linuxvm/vmlinuz
		install_file 644 "$lvm_build/initramfs.img" data/linuxvm/initramfs.img
		[[ ! -d $lvm_build/firmware ]] || install_file 755 "$lvm_build/firmware" data/linuxvm/firmware
		[[ ! -d $lvm_build/lib ]] || install_file 755 "$lvm_build/lib" lib/linuxvm/lib
		install_file 644 "$linuxvm/README.md" documentation/packages/linuxvm/README.md
		docker_package_info "$linuxvm/tools/package-haiku-cross.sh" "$version" "$work/linuxvm.PackageInfo"
		retarget_package_info "$work/linuxvm.PackageInfo" "$STAGE/.PackageInfo"
		finish_package linuxvm "lib/linuxvm/$qemu"
	}

	# The buildx plugin, in the CLI's plugin directory.
	local buildx=$work/buildx
	fork_checkout buildx "$buildx"
	version=$(docker_checkout_version "$buildx" 'v*')
	docker_go_build "$goarch" "$work/docker-buildx" "$buildx" ./cmd/buildx
	stage_begin
	install_binary "$work/docker-buildx" - lib/docker/cli-plugins/docker-buildx
	install_file 644 "$buildx/docs-airos.md" documentation/packages/docker_buildx/airos.md
	docker_package_info "$buildx/tools-package-haiku.sh" "$version" "$work/buildx.PackageInfo"
	retarget_package_info "$work/buildx.PackageInfo" "$STAGE/.PackageInfo" '^docker_cli$'
	finish_package docker_buildx lib/docker/cli-plugins/docker-buildx
}

# --- Docker Compose -----------------------------------------------------------
# The compose job's checkout (airos-works/compose). Installed both as
# docker-compose and as a Docker CLI plugin, so `docker compose` works.
build_compose() {
	note "Docker Compose"
	snapshot compose compose
	local goarch=${ARCH/x86_64/amd64} version
	version=$(docker_checkout_version "$APPS/compose" 'v2.*')
	docker_go_build "$goarch" "$BUILDDIR/docker-compose" "$SRC" ./cmd
	stage_begin
	install_binary "$BUILDDIR/docker-compose" - bin/docker-compose
	install_binary "$BUILDDIR/docker-compose" - lib/docker/cli-plugins/docker-compose
	install_file 644 "$SRC/docs/airos.md" documentation/packages/docker_compose/airos.md
	docker_package_info "$SRC/tools/package-haiku-cross.sh" "$version" "$APPBUILD/compose/PackageInfo"
	retarget_package_info "$APPBUILD/compose/PackageInfo" "$STAGE/.PackageInfo" '^docker_cli$'
	finish_package docker_compose bin/docker-compose lib/docker/cli-plugins/docker-compose
}

# --- Docker Desktop -----------------------------------------------------------
# The C++/Be API manager for the Engine (airos-works/docker-desktop), built
# with the cross SDK like the other GUI applications, installed in the
# Deskbar's Developer folder. The Makefile links with $(CXX), which carries
# the sysroot, like airShot's.
build_docker_desktop() {
	note "Docker Desktop"
	snapshot docker-desktop docker_desktop
	local revision version
	revision=$(git -C "$APPS/docker-desktop" rev-list --count HEAD)
	version="0.1.0~dev.${revision}.$(git -C "$APPS/docker-desktop" rev-parse --short HEAD)"
	make -C "$SRC" -s -j"$JOBS" BUILD=build-$ARCH CXX="$CXX_T" \
		RC="$TOOLS/rc/rc" XRES="$TOOLS/xres" MIMESET=true
	stage_begin
	install_binary "$BUILDDIR/DockerDesktop" "$BUILDDIR/docker-desktop.rsrc" apps/DockerDesktop
	docs dockerdesktop README.md LICENSE
	deskbar_link apps/DockerDesktop DockerDesktop Developer
	sed -e "s/^architecture[ \t].*/architecture x86_64/" \
		-e "s/^version .*/version $version-1/" \
		"$SRC/resources/docker-desktop.PackageInfo" > "$APPBUILD/docker_desktop/PackageInfo"
	retarget_package_info "$APPBUILD/docker_desktop/PackageInfo" "$STAGE/.PackageInfo"
	add_attributes "$BUILDDIR/docker-desktop.rsrc" apps/DockerDesktop
	finish_package dockerdesktop apps/DockerDesktop
}

main() {
	check_prerequisites
	mkdir -p "$APPBUILD" "$OUT" "$TMPDIR"
	: > "$APPBUILD/.summary"
	setup_host_tools
	setup_dependency_farm
	local app
	for app in airshot clipper burrow kiri lcdmonitor amp turbochook natter airtime airtop airpins \
			airimager snap wordcraft gridcraft deckcraft pdfcraft photocraft lightcraft aurora summit_webkit \
			summit summit_webkitlegacy proton_bridge airos_mail proton_vpn code_oss github_desktop \
			pgadmin4 docker compose docker_desktop; do
		# Only when asked for: Air Pins, Code - OSS, GitHub Desktop and pgAdmin 4 (their
		# own CI jobs, after Aurora), Summit (its engine is a pipeline of its own), Mail
		# (pinned for the images: apps/mail.lock.json; in the pool
		# its airos_ name would also be copied into images as a library) and the
		# Docker stack (their own CI jobs; build_docker also checks out forks)
		[[ $app =~ ^(airpins|summit_webkit|summit|summit_webkitlegacy|airos_mail|code_oss|github_desktop|pgadmin4|docker|compose|docker_desktop)$ && ${#SELECTED[@]} -eq 0 ]] \
			&& continue
		wanted "$app" && "build_$app"
	done
	note summary
	column -t -s $'\t' "$APPBUILD/.summary"
}

main
