#!/usr/bin/env bash
# Check the actual packages selected for an image, including their menu links.
set -euo pipefail
tool=${1:?usage: verify-office.sh PACKAGE_TOOL ARCH PACKAGE_DIR}
arch=${2:?architecture}
packages=${3:?package directory}
work=$(mktemp -d "${TMPDIR:-/tmp}/office-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
shopt -s nullglob
for entry in clipper:Clipper wordcraft:WordCraft gridcraft:GridCraft deckcraft:DeckCraft pdfcraft:PdfCraft; do
	IFS=: read -r name binary <<< "$entry"
	files=("$packages/$name"-[0-9]*-"$arch".hpkg)
	[[ ${#files[@]} == 1 ]] || { echo "expected one $name package for $arch" >&2; exit 1; }
	file=${files[0]}
	"$tool" list -i "$file" | grep -q "^[[:space:]]*architecture: $arch\$"
	"$tool" list -p "$file" > "$work/paths"
	grep -qx "apps/$binary" "$work/paths"
	grep -qx "data/deskbar/menu/Office/$binary" "$work/paths"
	if grep -qx "data/deskbar/menu/Applications/$binary" "$work/paths"; then
		echo "$name still has an Applications menu entry" >&2
		exit 1
	fi
	mkdir "$work/$name"
	"$tool" extract -C "$work/$name" "$file" "data/deskbar/menu/Office/$binary"
	[[ $(readlink "$work/$name/data/deskbar/menu/Office/$binary") == "../../../../apps/$binary" ]]
	echo "Office: $binary ($arch)"
done
