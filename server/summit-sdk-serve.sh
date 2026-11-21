#!/bin/bash
# summit-sdk-serve.sh: on the main build server (airos-build), the command of
# the Summit build server's SSH key. That server (airos-summit) builds Summit
# against a mirror of the SDKs made here (summit/sync-sdk.sh there), and this
# lets it read them, and nothing else: rsync reads of $AIROS_ROOT
# (/data1/airos), under the SDK's lock, shared, as lib/sdk.sh holds it, so an
# SDK or image build never replaces the files in the middle of a copy.
#
# The key's line in ~/.ssh/authorized_keys of an account in the airos group:
#
#   command="/home/USER/.local/bin/summit-sdk-serve",restrict ssh-ed25519 AAAA... ghrunner@airos-summit
#
# What the client may ask for:
#
#   airos-sdk-lock SDK_NAME [SECONDS]
#       take the SDK's lock, shared, and hold it until the client hangs up
#       (it closes its end when its copy is complete). Prints "locked", or
#       "busy" when the lock is not free within SECONDS (an SDK or image
#       build has it); without SECONDS it waits as long as it takes.
#   airos-sdk SDK_NAME --server --sender ...
#       rsync's remote command for a read (rsync -e ssh
#       --rsync-path="airos-sdk SDK_NAME" USER@airos-build:sdk/x86_64/ ...),
#       restricted to $AIROS_ROOT by rrsync.
set -euo pipefail
ROOT=${AIROS_ROOT:-/data1/airos}
LOCKS=${AIROS_LOCKS:-/data2/airos/locks}

refuse() { echo "summit-sdk-serve: $*" >&2; exit 1; }

read -r -a words <<< "${SSH_ORIGINAL_COMMAND:-}"
verb=${words[0]:-}
[[ $verb == airos-sdk || $verb == airos-sdk-lock ]] \
	|| refuse "only 'airos-sdk-lock SDK_NAME [SECONDS]' and rsync reads with --rsync-path='airos-sdk SDK_NAME'"
sdk=${words[1]:-}
[[ $sdk =~ ^(x86_64|arm64)(-r1beta[0-9]+)?$ ]] || refuse "unknown SDK '$sdk'"

# A release SDK has the compiler and host tools of the air/OS one.
arch=${sdk%%-*}
names=("haiku-$sdk")
[[ $sdk == "$arch" ]] || names+=("haiku-$arch")

# take_locks [SECONDS]
take_locks() {
	local name fd
	for name in "${names[@]}"; do
		[[ -e $LOCKS/$name.lock ]] || continue
		exec {fd}<"$LOCKS/$name.lock"
		if [[ -n ${1:-} ]]; then
			flock -s -w "$1" "$fd" || return 1
		else
			flock -s "$fd"
		fi
	done
}

if [[ $verb == airos-sdk-lock ]]; then
	seconds=${words[2]:-}
	[[ $seconds =~ ^[0-9]*$ && ${#words[@]} -le 3 ]] || refuse "usage: airos-sdk-lock SDK_NAME [SECONDS]"
	take_locks "$seconds" || { echo busy; exit 0; }
	echo locked
	cat > /dev/null
	exit 0
fi

[[ ${words[2]:-} == --server && ${words[3]:-} == --sender ]] || refuse "only rsync reads"
take_locks
export SSH_ORIGINAL_COMMAND="rsync ${words[*]:2}"
exec rrsync -ro "$ROOT"
