#!/usr/bin/env bash
# Boot $WORK/disk.img with QEMU TCG (no KVM needed) in a container; SSH on
# 127.0.0.1:2222. The CPU model hides vmx/svm, so the role takes its
# software-emulation path. Stop with: docker rm -f tcg-vm
set -euo pipefail
: "${WORK:?set WORK to the directory used by build-disk.sh}"
docker rm -f tcg-vm >/dev/null 2>&1 || true
docker run -d --name tcg-vm -p 127.0.0.1:2222:2222 -v "$WORK:/vm" tcg-vm-tools \
    qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu max,-svm,-vmx -smp 4 -m 6144 \
    -kernel /vm/vmlinuz -initrd /vm/initrd.img -append 'root=/dev/vda rw console=ttyS0 net.ifnames=0' \
    -drive file=/vm/disk.img,if=virtio,format=raw \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
    -nographic -serial mon:stdio >/dev/null
for _ in $(seq 1 60); do
    if ssh -q -i "$WORK/keys/bootstrap" -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile="$WORK/known_hosts" -o ConnectTimeout=5 -p 2222 debian@127.0.0.1 true; then
        echo "VM is up (ssh -p 2222 debian@127.0.0.1)"
        exit 0
    fi
    sleep 10
done
echo "VM did not come up; see: docker logs tcg-vm" >&2
exit 1
