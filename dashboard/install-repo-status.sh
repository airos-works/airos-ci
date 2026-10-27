#!/usr/bin/env bash
# dashboard/install-repo-status.sh: set up the build server's CI status page,
# http://192.168.1.200/ci/. Run as the account whose `gh` is logged in to
# GitHub (not root, not the runner user: the jobs must not reach the token);
# again to update it.
#
#   - $AIROS_ARTIFACTS/ci/index.html: dashboard/ci.html
#   - ~/.local/share/airos-ci-status/repo-status.py, run by cron every minute;
#     it writes $AIROS_ARTIFACTS/ci/status.json (error.txt when a run fails)
#   - nginx: /ci/ is served from the artifacts directory
#     (images/nginx-artifacts.conf); the running container is reloaded
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
[[ $(id -u) != 0 ]] || die "run as the gh account, not root"
gh auth token >/dev/null || die "gh is not logged in"

out=$AIROS_ARTIFACTS/ci
lib=$HOME/.local/share/airos-ci-status
mkdir -p "$out" "$lib"
install -m 664 "$AIROS_CI/dashboard/ci.html" "$out/index.html"
install -m 755 "$AIROS_CI/dashboard/repo-status.py" "$lib/repo-status.py"

line="* * * * * GITHUB_OWNER=$GITHUB_OWNER CI_STATUS_DIR=$out /usr/bin/python3 $lib/repo-status.py >/dev/null 2>&1"
{ crontab -l 2>/dev/null | grep -v 'airos-ci-status/repo-status.py' || true; echo "$line"; } | crontab -

conf=$AIROS_DATA/www/default.conf
if ! cmp -s "$AIROS_CI/images/nginx-artifacts.conf" "$conf"; then
	cp "$AIROS_CI/images/nginx-artifacts.conf" "$conf"
	docker exec airos-artifacts nginx -s reload >/dev/null \
		|| echo "warning: nginx not reloaded; run images/serve-artifacts.sh" >&2
fi
GITHUB_OWNER=$GITHUB_OWNER CI_STATUS_DIR=$out python3 "$lib/repo-status.py"
curl -fsS -o /dev/null http://127.0.0.1/ci/status.json && echo "CI status: http://$(hostname -I | awk '{print $1}')/ci/"
