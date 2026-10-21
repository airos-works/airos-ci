#!/usr/bin/env bash
# build-qt-airos.sh
#
# Qt for the x86_64 images: HaikuPorts' qt6_base with the Haiku platform plugin
# (add-ons/Qt6/platforms/libqhaiku.so) built from jmgasper/qt6-haikuplugins
# airos, which draws at the desktop's density: the device pixel ratio is
# BScreen::DeviceScale(), the backing store has the frame buffer's pixels and
# is drawn with B_DEVICE_PIXEL_BITMAP, text is grey and lightly hinted when
# scaled. HaikuPorts' plugin draws at the logical size, which app_server then
# enlarges: Qt programs (Telegram) were fuzzy at every scale above 100 percent.
#
# The plugin uses Qt's private API, so it is built against the very qt6_base it
# goes into: the newest of HaikuPorts, whose version the script takes from the
# package. Its moc comes from the qtbase source of that version, built for this
# machine once (cached). The package keeps its name and version and gets the
# revision plus 101, so a Qt program installed later from HaikuDepot (Telegram)
# uses it; HaikuPorts' next Qt version replaces it until an image brings the
# next one.
#
# Results in $AIROS_ROOT/qt/x86_64 (QT_AIROS_OUT for trial runs):
#   packages/   qt6_base-<version>-<revision + 101>-x86_64.hpkg and the
#               HaikuPorts packages it needs that the Haiku base does not
#               provide; images/build-image.sh installs all of them
#   sources.txt what went in
#
# Nothing is rebuilt while the fork pin, this script and HaikuPorts' packages
# stay the same. images/build-image.sh x86_64 runs it with every image build.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" \
		"$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

W=$AIROS_WORK/qt-airos
OUT=${QT_AIROS_OUT:-$AIROS_ROOT/qt/x86_64}
mkdir -p "$W" "$OUT"
cd "$W"
TLS=-mtls-dialect=gnu
REVISION_OFFSET=101

note "sources"
fork_checkout qt6-haikuplugins "$W/qt6-haikuplugins"; PLUGIN_COMMIT=$FORK_COMMIT
# qt6_base and what it needs beyond the Haiku base, as the images get them
AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" fetch x86_64 \
	qt6_base > "$W/runtime.txt"
qtpkg=$(grep -E '/qt6_base-[0-9][^/]*-x86_64\.hpkg$' "$W/runtime.txt" | head -n 1)
[[ -f $qtpkg ]] || die "HaikuPorts has no qt6_base for x86_64"
# qt6_base-6.10.3-3-x86_64.hpkg
qtname=$(basename "$qtpkg" -x86_64.hpkg)
QTVERSION=${qtname#qt6_base-}
QTVERSION=${QTVERSION%-*}
QTREVISION=${qtname##*-}
[[ $QTVERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $QTREVISION =~ ^[0-9]+$ ]] \
	|| die "cannot read the version of $qtname"
NEWREVISION=$((QTREVISION + REVISION_OFFSET))
echo "HaikuPorts qt6_base $QTVERSION-$QTREVISION -> $QTVERSION-$NEWREVISION"

key=$(cat "$AIROS_CI/deps/build-qt-airos.sh" <(xargs -n1 basename < "$W/runtime.txt" | sort) \
	<(echo "$PLUGIN_COMMIT") | sha256sum | cut -c1-16)
result=qt6_base-$QTVERSION-$NEWREVISION-x86_64.hpkg
if [[ ${FORCE:-0} != 1 && -f $OUT/key && $(cat "$OUT/key") == "$key" \
		&& -f $OUT/packages/$result ]]; then
	echo "Qt for the images unchanged ($key): $OUT"
	exit 0
fi

note "host moc of Qt $QTVERSION"
# the plugin's moc output must come from a moc of the same Qt version
moc_dir=$AIROS_CACHE/host/qt-moc-$QTVERSION
if [[ ! -x $moc_dir/moc ]]; then
	series=${QTVERSION%.*}
	url=https://download.qt.io/official_releases/qt/$series/$QTVERSION/submodules/qtbase-everywhere-src-$QTVERSION.tar.xz
	rm -rf "$W/qtbase"
	mkdir -p "$W/qtbase/src"
	curl -sfL --retry 3 -o "$W/qtbase/qtbase.tar.xz" "$url" || die "cannot download $url"
	sum=$(curl -sfL --retry 3 "$url.sha256" | awk '{print $1}')
	[[ -n $sum ]] || die "no SHA-256 published for $url"
	echo "$sum  $W/qtbase/qtbase.tar.xz" | sha256sum -c --quiet \
		|| die "qtbase $QTVERSION does not match its published SHA-256"
	tar -xJf "$W/qtbase/qtbase.tar.xz" -C "$W/qtbase/src" --strip-components=1
	features=""
	for feature in gui widgets network sql testlib xml dbus concurrent printsupport icu glib \
			zstd; do
		features+=" -DQT_FEATURE_$feature=OFF"
	done
	# shellcheck disable=SC2086
	cmake -S "$W/qtbase/src" -B "$W/qtbase/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
		-DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF $features \
		> "$W/qtbase/configure.log" 2>&1 \
		|| { tail -30 "$W/qtbase/configure.log"; die "qtbase configure failed"; }
	cmake --build "$W/qtbase/build" --target moc -j"$JOBS" > "$W/qtbase/build.log" 2>&1 \
		|| { tail -30 "$W/qtbase/build.log"; die "moc build failed"; }
	mkdir -p "$moc_dir"
	install -m 0755 "$W/qtbase/build/libexec/moc" "$moc_dir/moc"
	rm -rf "$W/qtbase"
fi
MOC=$moc_dir/moc

note "sysroot: the SDK's and HaikuPorts' qt6_base_devel"
QTROOT=$W/sysroot
system=$QTROOT/boot/system
# haiku_svg_icon_theme's directories are read-only once staged
[[ ! -d $QTROOT ]] || chmod -R u+w "$QTROOT"
rm -rf "$QTROOT"
mkdir -p "$QTROOT"
rsync -a --exclude=/boot/system/data/ssl/private "$SYSROOT/" "$QTROOT/"
AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" stage x86_64 \
	"$system" qt6_base_devel > /dev/null
# absolute links inside the sysroot point into it
while IFS= read -r -d '' link; do
	target=$(readlink "$link")
	[[ $target == /boot/system/* ]] \
		&& ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$QTROOT$target")" "$link"
done < <(find "$system" -type l -print0)
headers=$system/develop/headers/Qt6
[[ -d $headers/QtGui/$QTVERSION/QtGui/qpa ]] \
	|| die "qt6_base_devel has no private headers for Qt $QTVERSION"

note "the platform plugin"
src=$W/qt6-haikuplugins/src/platform
build=$W/build
rm -rf "$build"
mkdir -p "$build"
defines="-DQT_PLUGIN -DQT_NO_DEBUG -DQT_WIDGETS_LIB -DQT_GUI_LIB -DQT_CORE_LIB"
includes="-I$src -I$W/qt6-haikuplugins/3rdparty/simplecrypt -I$build -I$headers"
for module in QtCore QtGui QtWidgets; do
	includes+=" -I$headers/$module -I$headers/$module/$QTVERSION"
	includes+=" -I$headers/$module/$QTVERSION/$module"
done
includes+=" -I$system/data/Qt6/mkspecs/haiku-g++ -I$system/develop/headers/freetype2"
# moc: the classes with Q_OBJECT, and main.cpp with the plugin's metadata
# shellcheck disable=SC2086
for header in "$src"/*.h; do
	grep -q Q_OBJECT "$header" || continue
	"$MOC" $defines $includes "$header" -o "$build/moc_$(basename "$header" .h).cpp"
done
# shellcheck disable=SC2086
(cd "$src" && "$MOC" $defines $includes main.cpp -o "$build/main.moc")
cxxflags="--sysroot=$QTROOT $TLS -std=gnu++17 -O2 -fPIC -fvisibility=hidden -w"
objects=()
for file in "$src"/*.cpp "$W/qt6-haikuplugins/3rdparty/simplecrypt/simplecrypt.cpp" \
		"$build"/moc_*.cpp; do
	object=$build/$(basename "$file" .cpp).o
	# shellcheck disable=SC2086
	"${CROSS}g++" $cxxflags $defines $includes -c "$file" -o "$object" \
		|| die "cannot compile $(basename "$file")"
	objects+=("$object")
done
# shellcheck disable=SC2086
"${CROSS}g++" --sysroot="$QTROOT" -specs="$UNWIND_SPECS" -shared -o "$build/libqhaiku.so" \
	"${objects[@]}" -L"$system/develop/lib" -L"$system/lib" \
	-lQt6Widgets -lQt6Gui -lQt6Core -lbe -lroot -ltracker -lgame -lGL -lGLU -lfreetype \
	|| die "cannot link libqhaiku.so"
"${CROSS}strip" --strip-unneeded "$build/libqhaiku.so"
"${CROSS}readelf" -d "$build/libqhaiku.so" | grep -q 'libQt6Gui' \
	|| die "libqhaiku.so does not link Qt"

note "qt6_base $QTVERSION-$NEWREVISION"
pkg=$W/package
rm -rf "$pkg"
mkdir -p "$pkg"
"$TOOLS/package/package" extract -C "$pkg" "$qtpkg"
plugin=$pkg/add-ons/Qt6/platforms/libqhaiku.so
[[ -f $plugin ]] || die "$qtname has no add-ons/Qt6/platforms/libqhaiku.so"
install -m 0755 "$build/libqhaiku.so" "$plugin"
info=$pkg/.PackageInfo
grep -qE "^version[[:space:]]+$QTVERSION-$QTREVISION\$" "$info" \
	|| die "unexpected version line in $qtname"
sed -i -E "s/^version([[:space:]]+)$QTVERSION-$QTREVISION\$/version\\1$QTVERSION-$NEWREVISION/" "$info"
sed -i -E "s/^(description[[:space:]]+\".*)\"\$/\\1 air\\/OS: desktop density support and stable Deskbar tray icons (jmgasper\\/qt6-haikuplugins ${PLUGIN_COMMIT:0:12}).\"/" "$info"
sed -i -E 's/^packager([[:space:]]+).*/packager\1"air\/OS CI"/' "$info"
mkdir -p "$OUT/packages"
rm -f "$OUT"/packages/*.hpkg
"$TOOLS/package/package" create -q -C "$pkg" "$OUT/packages/$result"
"$TOOLS/package/package" list -i "$OUT/packages/$result" | grep -qE "version: $QTVERSION-$NEWREVISION" \
	|| die "the new package does not have version $QTVERSION-$NEWREVISION"
# and what qt6_base needs beyond the Haiku base
while IFS= read -r file; do
	[[ $file == "$qtpkg" ]] && continue
	cp "$file" "$OUT/packages/"
done < "$W/runtime.txt"
printf 'qt6_base %s-%s (HaikuPorts) -> %s-%s\nqt6-haikuplugins %s\n' "$QTVERSION" \
	"$QTREVISION" "$QTVERSION" "$NEWREVISION" "$PLUGIN_COMMIT" > "$OUT/sources.txt"
xargs -n1 basename < "$W/runtime.txt" >> "$OUT/sources.txt"
echo "$key" > "$OUT/key"
ls -1 "$OUT/packages"
