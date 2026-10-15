# Extra test: full role on a QEMU VM without KVM (TCG)

Not the main test path. It exists because the machine these roles were written
on has no `/dev/kvm` (so no molecule `vm` scenario), and the egress proxy there
refused the cloud.debian.org mirror, so Debian's genericcloud image could not be
downloaded. This harness builds an equivalent "fresh Debian 13 server" from
`deb.debian.org` and boots it with QEMU TCG (software emulation). The full
`site.yml` then runs **over SSH against a real Debian kernel**, including what the
Docker scenario skips: live nftables, module loading, global sysctls, auditd,
`update-grub`, and the SSH lock-out guards. The only difference from your lab is
that there is no vmx/svm in the VM, so it runs with
`kvm_host_allow_software_emulation: true`.

```sh
cd tests/tcg-vm
export WORK=/some/scratch/dir                 # outside the repository
./build-disk.sh                                # tools image, keys, disk (deb.debian.org only)
./start-vm.sh                                  # QEMU in a container, SSH on 127.0.0.1:2222
ADMIN_PUBKEY="$(cat "$WORK/keys/admin.pub")" envsubst < inventory/group_vars/all.yml.in > inventory/group_vars/all.yml
cd ../.. && INVENTORY=tests/tcg-vm/inventory/hosts.yml RUN2_USER=kvmadmin scripts/test-idempotency.sh
```

Note: with QEMU user networking behind Docker's port publishing, the guest sees
the controller as the Docker bridge gateway (172.17.0.1), so the management CIDR
is `172.17.0.0/16`. The preflight lock-out guard found that on the first attempt
(`tests/output/tcg-vm-attempt1-lockout-guard.log`).

Results of the run on 2026-10-15: `tests/output/tcg-vm-*.log`.
