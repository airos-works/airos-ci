#!/usr/bin/env bash
# serve-artifacts.sh: serve $AIROS_ARTIFACTS (images, manifests) over HTTP on
# port 80 of the build server with an nginx container (host networking).
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
conf=$AIROS_DATA/www/default.conf
mkdir -p "$AIROS_DATA/www" "$AIROS_ARTIFACTS/images"
cp "$AIROS_CI/images/nginx-artifacts.conf" "$conf"
# The symbol store at /symbols/ when it is on a disk of its own
# (server/setup-data4.sh; its mount point in the artifacts tree is an empty
# directory that setup-data4.sh made).
volumes=(-v "$AIROS_ARTIFACTS:/usr/share/nginx/html:ro" -v "$conf:/etc/nginx/conf.d/default.conf:ro")
[[ $AIROS_SYMBOLS == "$AIROS_ARTIFACTS/symbols" || -z $AIROS_SYMBOLS ]] \
	|| volumes+=(-v "$AIROS_SYMBOLS:/usr/share/nginx/html/symbols:ro")
docker rm -f airos-artifacts >/dev/null 2>&1 || true
docker run -d --name airos-artifacts --restart unless-stopped --network host \
	"${volumes[@]}" nginx:alpine >/dev/null
echo "serving $AIROS_ARTIFACTS at http://$(hostname).local/"
