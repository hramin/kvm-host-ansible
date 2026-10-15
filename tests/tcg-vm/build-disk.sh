#!/usr/bin/env bash
# Build the "fresh Debian 13 server" disk in $WORK with build-rootfs.sh (the
# exact script used for the logged run). Only deb.debian.org is contacted.
# Needs Docker (privileged, for mmdebstrap's chroot) and ssh-keygen.
set -euo pipefail
: "${WORK:?set WORK to a scratch directory outside the repository}"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$WORK/keys" "$WORK/build"
for name in bootstrap admin; do
    [[ -f "$WORK/keys/$name" ]] || ssh-keygen -q -t ed25519 -N '' -C "tcg-vm-$name" -f "$WORK/keys/$name"
done
cp "$here/build-rootfs.sh" "$WORK/build/build-rootfs.sh"
docker build -q -t tcg-vm-tools "$here" >/dev/null
docker run --rm --privileged -v "$WORK:/vm" tcg-vm-tools /vm/build/build-rootfs.sh
