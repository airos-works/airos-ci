#!/bin/bash
# summit-sdk-serve.sh: on the main build server (airos-build), the command of
# the Summit build server's SSH key. That server (airos-summit) builds Summit
# against a mirror of the SDKs made here (summit/sync-sdk.sh there), and this
# lets it read them, and nothing else: an rsync read of $AIROS_ROOT
# (/data1/airos), under the SDK's lock, shared, as lib/sdk.sh holds it, so an
# SDK or image build never replaces the files in the middle of a copy.
#
# The key's line in ~/.ssh/authorized_keys of an account in the airos group:
#
#   command="/home/USER/.local/bin/summit-sdk-serve",restrict ssh-ed25519 AAAA... ghrunner@airos-summit
#
# The client names the SDK in rsync's remote command:
#
#   rsync -e ssh --rsync-path="airos-sdk x86_64" USER@airos-build:sdk/x86_64/ ...
set -euo pipefail
ROOT=${AIROS_ROOT:-/data1/airos}
LOCKS=${AIROS_LOCKS:-/data2/airos/locks}

refuse() { echo "summit-sdk-serve: $*" >&2; exit 1; }

read -r -a words <<< "${SSH_ORIGINAL_COMMAND:-}"
[[ ${words[0]:-} == airos-sdk ]] || refuse "only rsync reads with --rsync-path='airos-sdk SDK_NAME'"
sdk=${words[1]:-}
[[ $sdk =~ ^(x86_64|arm64)(-r1beta[0-9]+)?$ ]] || refuse "unknown SDK '$sdk'"
[[ ${words[2]:-} == --server && ${words[3]:-} == --sender ]] || refuse "only rsync reads"

# A release SDK has the compiler and host tools of the air/OS one.
arch=${sdk%%-*}
names=("haiku-$sdk")
[[ $sdk == "$arch" ]] || names+=("haiku-$arch")
for name in "${names[@]}"; do
	[[ -e $LOCKS/$name.lock ]] || continue
	exec {fd}<"$LOCKS/$name.lock"
	flock -s "$fd"
done

export SSH_ORIGINAL_COMMAND="rsync ${words[*]:2}"
exec rrsync -ro "$ROOT"
