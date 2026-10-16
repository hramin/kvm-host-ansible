# kvm-host-ansible

Ansible playbook that takes a fresh Debian 12/13 server to a ready KVM/libvirt
virtualization host with local NVMe storage. A second run reports `changed=0`.
Two roles: `base_hardening` (access, firewall, time, sysctls, logging) and
`kvm_host` (the hypervisor). `site.yml` runs them in that order.

## What it does

| Task requirement | Where in the code |
|---|---|
| Users and SSH hardening | `base_hardening/tasks/users.yml` (admin users, keys, sudo), `ssh.yml` + `templates/sshd_config.j2` (`PermitRootLogin no`, `AllowGroups admins`, keys only) |
| Firewall | `tasks/firewall.yml`, `templates/nftables.conf.j2` (own `inet host_firewall` table, default drop, SSH from the management CIDRs only) |
| NTP | `tasks/ntp.yml`, `templates/chrony.conf.j2` (chrony; ntp/ntpsec/timesyncd purged) |
| Kernel parameters | `base_hardening/tasks/sysctl.yml` (hardening), `kvm_host/tasks/kernel.yml` (bridge-nf-call=0, swappiness, dirty ratios, aio; KVM modules, nested) |
| Logging | `journald.yml` (persistent, size-limited), `auditd.yml` (hypervisor audit rules), `kvm_host/tasks/logging.yml` (libvirt/QEMU logrotate) |
| Required packages | `base_hardening/tasks/packages.yml`, `kvm_host/tasks/packages.yml` (QEMU, libvirt, OVMF; short purge list) |
| libvirt/KVM | `kvm_host/tasks/`: `preflight.yml` (vmx/svm), `libvirt.yml` (daemon, libvirt group), `storage.yml` (NVMe directory pool), `network.yml` (default NAT network), `guests.yml` (libvirt-guests) |
| Idempotency | see [Idempotency](#idempotency); proof in `tests/output/run2.log` |
| Safe first contact | `base_hardening/tasks/preflight.yml` (lock-out guards), tag `bootstrap` |

## Design decisions

- **Lock-out protection.** Users, keys and sudo exist before sshd is restricted; config files are
  validated before they are written; preflight stops if the controller's address is outside the
  management CIDRs; the `bootstrap` tag sets up access first and the firewall later.
- **Firewall.** One nftables table owned by the role, never `flush ruleset`, so libvirt's NAT rules
  survive reloads. No forward chain, so bridged guest traffic is not filtered by the host.
- **Storage.** A libvirt directory pool on the NVMe filesystem (qcow2/raw files; snapshots and backing
  files work on any filesystem). An optional mount-point check keeps images off the root filesystem.
- **Networking.** libvirt's default NAT network is off by default (production guests would use a
  bridge) and on in the single-NIC lab.
- **Guests on host shutdown.** Clean ACPI shutdown (300 s); guests that were running start again on boot.
- **Debian defaults kept** where they already do the job: auditd log rotation, libvirt group access,
  virtlogd rotation of QEMU logs.

## Idempotency

| Area | What could make it non-idempotent | How this role avoids it |
|---|---|---|
| command tasks | commands always report "changed" | only read-only checks, with `changed_when: false` and `check_mode: false`; `augenrules --load` is a handler |
| config files | rewriting files every run | `template`/`lineinfile` compare content; `validate` (`sshd -t`, `visudo -cf`, `nft -c`) |
| services | restarting on every run | handlers only, fired by a changed file; reload where possible; `force_handlers` keeps a pending reload after a failure |
| firewall | `flush ruleset` wiping libvirt's rules, which libvirt re-adds | only `inet host_firewall` is replaced, in one transaction, when the file changed; a drop-in replaces `ExecStop=nft flush ruleset` |
| sysctls | `sysctl -p` of a whole file; multi-value keys | `ansible.posix.sysctl` per key (word by word, so `kernel.printk = 3 4 1 7` matches); `ip_forward` left to libvirt |
| libvirt objects | re-defining pools/networks | `virt_pool`/`virt_net` define only if absent; a changed pool path stops the play |
| libvirtd | Debian's `--timeout 120` lets the daemon exit when idle | `/etc/default/libvirtd` clears the timeout |
| libvirt-guests | a restart handler would shut down all guests | no handler |
| users/keys | appending keys every run | `authorized_key exclusive: true`; groups with `append` |
| packages | `latest`, upgrades, cache refresh | `state: present`, `cache_valid_time: 1800`, no upgrade task |

Check: run the playbook twice and read the second `PLAY RECAP`. To find a task that changed:
`grep -B3 '^changed:' tests/output/run2.log`, or run again with `--diff`.

## Scope cuts

The test tooling used while developing (molecule, a QEMU test VM, their logs) is on branch `dev-test-harness`.

- **fail2ban:** SSH is key-only and reachable only from the management CIDRs, so it would mostly ban admins.
- **auditd:** ~20 hypervisor rules instead of a 300-line multi-distro set; no `audit=1` GRUB argument and no immutable `-e 2`.
- **General CIS hardening** (module blocklists, cron/at permissions, login.defs ageing, TMOUT, `/tmp` tmpfs, `/proc` hidepid, SSH banner): beyond this task.
- **Package upgrades:** patching is a separate, scheduled process.
- **VM bridge (systemd-networkd):** with more time; it depends on each site's NIC layout.

## Customize

Site values: `inventories/lab/hosts.yml` (hosts) and `inventories/lab/group_vars/all.yml` (variables).
All defaults are documented in `roles/*/defaults/main.yml`.

| Variable | Default | Meaning |
|---|---|---|
| `base_hardening_debian_version` | `"13"` | release every host must run |
| `base_hardening_management_cidrs` | `[]` (required) | who may reach SSH; the controller must be inside |
| `base_hardening_admin_users` | `[]` (required) | `[{name, ssh_keys: [...]}]`: SSH, passwordless sudo, libvirt group |
| `base_hardening_sshd_port` | `22` | sshd port (opened for the management CIDRs) |
| `base_hardening_firewall_allowed_ports` | `[]` | extra inbound ports, e.g. `[{port: "5900-5999", proto: tcp}]` |
| `base_hardening_chrony_pools` / `_servers` | Debian pool / `[]` | NTP sources |
| `kvm_host_allow_software_emulation` | `false` | continue without vmx/svm (lab only) |
| `kvm_host_nested_virtualization` | `true` | guests may run KVM themselves |
| `kvm_host_storage_pool_path` | `/var/lib/libvirt/nvme` | directory pool (mount the NVMe here) |
| `kvm_host_storage_pool_require_mountpoint` | `false` | fail unless the path is a mount point |
| `kvm_host_libvirt_default_network_enabled` | `false` | libvirt NAT network |
| `kvm_host_guests_on_shutdown` / `_on_boot` | `shutdown` / `start` | libvirt-guests behaviour |

Tags (preflight always runs): `bootstrap` (users, keys, sudo, sshd), `users`, `ssh`, `packages`,
`firewall`, `ntp`, `sysctl`, `kernel`, `logging`, `auditd`, `libvirt`, `storage`, `network`, `guests`,
`base_hardening`, `kvm_host`. Dry run on a configured host: `ansible-playbook site.yml --check --diff`.

## Results

Lab: Debian 12 VM in VirtualBox on Windows 10, Ansible from WSL2. Problems met while building the
lab and how they were solved: [docs/LAB-ISSUES.md](docs/LAB-ISSUES.md).

- Run 2 (`tests/output/run2.log`): `lab-kvm01 : ok=<n> changed=0 unreachable=0 failed=0`
- Nested VT-x was not available inside the VM (WSL2 keeps Hyper-V on), so the run used
  `kvm_host_allow_software_emulation: true`. `virt-host-validate qemu` reports hardware virtualization
  FAIL and libvirt offers only `domain type='qemu'`; on real hardware the same role gives `kvm`.
- All other `virt-host-validate` checks pass (`/dev/vhost-net`, `/dev/net/tun`, cgroup controllers).

## Setup and run

Lab used for the results above. Replace the addresses, user and key with your own.

**1. Lab VM (VirtualBox).** Debian 12, nested VT-x enabled, user `hra` with sudo.
Adapter 1: NAT (internet). Adapter 2: host-only, static `192.168.56.10/24` on `enp0s8`:

```
# /etc/network/interfaces
auto enp0s8
iface enp0s8 inet static
    address 192.168.56.10/24
```

**2. Controller (Linux or WSL2).**

```sh
python3 -m venv ~/ansible-venv && . ~/ansible-venv/bin/activate
pip install ansible            # includes ansible.posix, community.general, community.libvirt
git clone https://github.com/hramin/kvm-host-ansible.git && cd kvm-host-ansible
ssh-copy-id hra@192.168.56.10
ssh-keyscan -H 192.168.56.10 >> ~/.ssh/known_hosts
```

(`ansible-galaxy collection install -r requirements.yml` does the same for `ansible-core` installs
when galaxy.ansible.com is reachable.)

**3. Inventory.** `inventories/lab/hosts.yml`: `ansible_host: 192.168.56.10`.
`inventories/lab/group_vars/all.yml`:

```yaml
ansible_user: hra
base_hardening_debian_version: "12"
base_hardening_management_cidrs: [192.168.56.0/24]
base_hardening_admin_users:
  - name: hra
    ssh_keys: ["ssh-ed25519 AAAA... comment"]
kvm_host_allow_software_emulation: true      # only because the lab VM has no vmx/svm
kvm_host_libvirt_default_network_enabled: true
```

Then `ansible -m ping kvm_hosts` must answer `pong`. Take a VM snapshot now.

**4. Run** (Run 0 sets up access, Run 1 does everything, Run 2 must change nothing):

```sh
mkdir -p tests/output
ansible-playbook site.yml --tags bootstrap --ask-become-pass | tee tests/output/run0.log
rm -f ~/.ansible/cp/*        # new SSH session, so the new admins group (passwordless sudo) applies
ansible-playbook site.yml | tee tests/output/run1.log
ansible-playbook site.yml | tee tests/output/run2.log
```

Or all three with a PASS/FAIL check: `BOOTSTRAP=1 ASK_BECOME_PASS=1 scripts/test-idempotency.sh`.

**5. Check the host.**

```sh
ssh hra@192.168.56.10
systemctl is-active libvirtd chrony nftables
sudo virt-host-validate qemu
virsh -c qemu:///system pool-list --all      # nvme: active, autostart
virsh -c qemu:///system net-list --all       # default: active, autostart
sudo nft list tables                         # inet host_firewall + libvirt's tables
```

`virsh` without `-c qemu:///system` (or `sudo`) connects to the empty per-user session.
`ssh root@192.168.56.10` must be refused.
