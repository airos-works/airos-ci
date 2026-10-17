#!/usr/bin/env bash
# deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR] - a HaikuPorts package
# with its entries in the Deskbar menu's Applications folder moved into the
# menu's FOLDER (Utilities), where air/OS's menu has them; prints the new file.
#
#   deps/deskbar-repack.sh x86_64 vision Utilities "$WORK/packages"
#
# Everything else in the package stays as HaikuPorts built it. Its revision
# goes up by 100 plus LAYOUT (vision 0.10.6-2 -> 0.10.6-103), so it is never
# taken for, nor replaced by, the repository's. OUTPUT_DIR defaults to the
# package pool; older repacks of PACKAGE there are removed. The image then
# needs the repository's own package kept out (the fork's
# tools/airos/ci/UserBuildConfig, SuppressHaikuImagePackages).
set -euo pipefail
umask 002

. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
export AIROS_ARCH=${1:?usage: deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR]}
PACKAGE=${2:?usage: deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR]}
FOLDER=${3:?usage: deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR]}
. "$AIROS_CI/lib/sdk.sh"      # ARCH, TOOLS, ATTRS (the host tools' attributes)
OUT=${4:-$AIROS_PACKAGES/$ARCH}
# Raised whenever the repack's menu layout changes, so an install updates:
# 1 since FOLDER is a folder of the menu itself (0 had it in Applications).
LAYOUT=1

source=$(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
	"$AIROS_CI/deps/haikuports.py" fetch --no-deps "$ARCH" "$PACKAGE")
[[ -f $source ]] || die "HaikuPorts has no $PACKAGE for $ARCH"

work=$AIROS_WORK/repack-$ARCH-$PACKAGE
stage=$work/stage
[[ -e $stage ]] && "$TOOLS/rm_attrs" -rf "$stage"
mkdir -p "$stage"

# The host tools keep attributes in $ATTRS by inode (a symlink's as
# symlink-<inode>): an inode used before may still have some there. What the
# extraction writes is newer than the marker; anything older is stale.
marker=$work/began
touch "$marker"
sleep 0.05
"$TOOLS/package/package" extract -C "$stage" "$source"
while IFS= read -r -d '' entry; do
	dir=$ATTRS/$(stat -c %i "$entry")
	[[ -L $entry ]] && dir=$ATTRS/symlink-$(stat -c %i "$entry")
	[[ -d $dir ]] || continue
	find "$dir" -mindepth 1 ! -newer "$marker" -exec rm -rf {} +
done < <(find "$stage" -print0)

menu=$stage/data/deskbar/menu
links=("$menu"/Applications/*)
[[ -L ${links[0]} ]] || die "$PACKAGE has no entry in the Applications menu"
mkdir -p -m 755 "$menu/$FOLDER"
for link in "${links[@]}"; do
	[[ -L $link ]] || continue
	# The same depth: the target stays as it is.
	ln -s "$(readlink "$link")" "$menu/$FOLDER/$(basename "$link")"
	rm "$link"
done
# An Applications folder left empty goes too (with its attributes).
[[ -n $(ls -A "$menu/Applications") ]] || "$TOOLS/rm_attrs" -rf "$menu/Applications"

version=$(awk '$1 == "version" { print $2; exit }' "$stage/.PackageInfo")
[[ $version =~ ^(.*)-([0-9]+)$ ]] || die "unexpected version $version"
version=${BASH_REMATCH[1]}-$((BASH_REMATCH[2] + 100 + LAYOUT))
sed -i "s/^version[[:space:]].*/version\t\t\t$version/" "$stage/.PackageInfo"

mkdir -p "$OUT"
rm -f "$OUT/$PACKAGE"-[0-9]*-"$ARCH".hpkg
file=$OUT/$PACKAGE-$version-$ARCH.hpkg
"$TOOLS/package/package" create -q -C "$stage" "$file"
"$TOOLS/rm_attrs" -rf "$stage"
echo "$file"
