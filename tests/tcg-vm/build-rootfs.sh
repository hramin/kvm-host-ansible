#!/bin/bash
# shellcheck disable=SC2016  # "$1" in the hooks is expanded by mmdebstrap, not by this shell
# Builds a "fresh Debian 13 server" disk: like a netinst install with the
# SSH server task and a first-connection user "debian" (sudo, key login).
set -euxo pipefail
out=/vm
rm -rf "$out/rootfs" && mkdir -p "$out/rootfs"
mmdebstrap --mode=root --variant=important \
  --include=linux-image-amd64,systemd-sysv,openssh-server,sudo,python3,grub-pc,ifupdown,dhcpcd-base,netbase,iproute2,udev,kmod,initramfs-tools,e2fsprogs \
  --customize-hook='echo lab-tcg > "$1/etc/hostname"' \
  --customize-hook='printf "127.0.0.1 localhost\n127.0.1.1 lab-tcg\n" > "$1/etc/hosts"' \
  --customize-hook='printf "auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n" > "$1/etc/network/interfaces"' \
  --customize-hook='printf "/dev/vda / ext4 errors=remount-ro 0 1\n" > "$1/etc/fstab"' \
  --customize-hook='chroot "$1" useradd -m -s /bin/bash -G sudo debian' \
  --customize-hook='printf "debian ALL=(ALL) NOPASSWD:ALL\n" > "$1/etc/sudoers.d/90-debian"; chmod 0440 "$1/etc/sudoers.d/90-debian"' \
  --customize-hook='install -d -m 0700 -o 1000 -g 1000 "$1/home/debian/.ssh"; install -m 0600 -o 1000 -g 1000 /vm/keys/bootstrap.pub "$1/home/debian/.ssh/authorized_keys"' \
  --customize-hook='mkdir -p "$1/boot/grub"' \
  --customize-hook='cp -L "$1/vmlinuz" /vm/vmlinuz; cp -L "$1/initrd.img" /vm/initrd.img' \
  trixie "$out/rootfs" \
  "deb http://deb.debian.org/debian trixie main" \
  "deb http://deb.debian.org/debian trixie-updates main" \
  "deb http://deb.debian.org/debian-security trixie-security main"
rm -f "$out/disk.img"
mkfs.ext4 -q -L root -d "$out/rootfs" "$out/disk.img" 16G
ls -la "$out"/disk.img "$out"/vmlinuz "$out"/initrd.img
