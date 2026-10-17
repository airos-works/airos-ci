#!/usr/bin/env bash
# deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR] - a HaikuPorts package
# with its entries in the Deskbar's Applications menu moved into that menu's
# FOLDER (Utilities), where air/OS's menu has them; prints the new file.
#
#   deps/deskbar-repack.sh x86_64 vision Utilities "$WORK/packages"
#
# Everything else in the package stays as HaikuPorts built it. Its revision
# goes up by 100 (vision 0.10.6-2 -> 0.10.6-102), so it is never taken for,
# nor replaced by, the repository's. OUTPUT_DIR defaults to the package pool;
# older repacks of PACKAGE there are removed. The image then needs the
# repository's own package kept out (the fork's tools/airos/ci/UserBuildConfig,
# SuppressHaikuImagePackages).
set -euo pipefail
umask 002

. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
export AIROS_ARCH=${1:?usage: deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR]}
PACKAGE=${2:?usage: deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR]}
FOLDER=${3:?usage: deskbar-repack.sh ARCH PACKAGE FOLDER [OUTPUT_DIR]}
. "$AIROS_CI/lib/sdk.sh"      # ARCH, TOOLS, ATTRS (the host tools' attributes)
OUT=${4:-$AIROS_PACKAGES/$ARCH}

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

menu=$stage/data/deskbar/menu/Applications
links=("$menu"/*)
[[ -L ${links[0]} ]] || die "$PACKAGE has no entry in the Applications menu"
mkdir -p -m 755 "$menu/$FOLDER"
for link in "${links[@]}"; do
	[[ -L $link ]] || continue
	# One directory deeper: the target gets another "../".
	ln -s "../$(readlink "$link")" "$menu/$FOLDER/$(basename "$link")"
	rm "$link"
done

version=$(awk '$1 == "version" { print $2; exit }' "$stage/.PackageInfo")
[[ $version =~ ^(.*)-([0-9]+)$ ]] || die "unexpected version $version"
version=${BASH_REMATCH[1]}-$((BASH_REMATCH[2] + 100))
sed -i "s/^version[[:space:]].*/version\t\t\t$version/" "$stage/.PackageInfo"

mkdir -p "$OUT"
rm -f "$OUT/$PACKAGE"-[0-9]*-"$ARCH".hpkg
file=$OUT/$PACKAGE-$version-$ARCH.hpkg
"$TOOLS/package/package" create -q -C "$stage" "$file"
"$TOOLS/rm_attrs" -rf "$stage"
echo "$file"
