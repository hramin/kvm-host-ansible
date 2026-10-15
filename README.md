# kvm-host-ansible

Takes a fresh Debian 12/13 server to a ready KVM/libvirt virtualization host
with local NVMe storage. A second run reports `changed=0`.

## What it does

| Task requirement | Where in the code |
|---|---|
| Users and SSH hardening | `roles/base_hardening/tasks/users.yml` (admin users, keys, sudo), `ssh.yml` + `templates/sshd_config.j2` (`PermitRootLogin no`, `AllowGroups admins`, keys only) |
| Firewall | `tasks/firewall.yml`, `templates/nftables.conf.j2` (own `inet host_firewall` table, default drop, SSH from the management CIDR only), `templates/nftables-service-override.conf.j2` |
| NTP | `tasks/ntp.yml`, `templates/chrony.conf.j2` (chrony; ntp/ntpsec/timesyncd purged) |
| Kernel parameters | `base_hardening/tasks/sysctl.yml` (hardening), `kvm_host/tasks/kernel.yml` + `defaults/main.yml` (`kvm_host_sysctl_settings`: bridge-nf-call=0, swappiness, dirty ratios, aio; KVM modules, nested) |
| Logging | `base_hardening/tasks/journald.yml` (persistent, size-limited), `auditd.yml` + `templates/hardening.rules.j2`, `kvm_host/tasks/logging.yml` (libvirt/QEMU logrotate) |
| Required packages | `base_hardening/tasks/packages.yml`, `kvm_host/tasks/packages.yml` (QEMU, libvirt, OVMF; short purge list) |
| libvirt/KVM | `kvm_host/tasks/`: `preflight.yml` (vmx/svm), `libvirt.yml` (daemon, libvirt group), `storage.yml` (NVMe directory pool), `network.yml` (default NAT network), `guests.yml` (libvirt-guests) |
| Idempotency | see [Idempotency](#idempotency); proof: `scripts/test-idempotency.sh` |
| Safe first contact | `base_hardening/tasks/preflight.yml` (lock-out guards), tag `bootstrap` |

## Requirements

- **Controller:** Ansible core ≥ 2.16 (tested with 2.21), `ansible-galaxy collection install -r requirements.yml`
  (ansible.posix, community.general, community.libvirt; installed into `./collections`).
- **Target:** fresh Debian 12 or 13 (amd64), `python3`, a user with sudo and an SSH key (the installer user),
  reachable from the management network. For real KVM the CPU must show `vmx`/`svm`;
  a VM needs nested virtualization (VirtualBox: "Enable Nested VT-x/AMD-V").

## Customize

Site values live in `inventories/lab/hosts.yml` (hosts) and `inventories/lab/group_vars/all.yml`
(variables). Role defaults are documented in `roles/*/defaults/main.yml`.

| Variable | Default | Meaning |
|---|---|---|
| `base_hardening_debian_version` | `"13"` | release every host must run (lab: `"12"`) |
| `base_hardening_management_cidrs` | `[]` (required) | who may reach SSH; the controller must be inside |
| `base_hardening_admin_users` | `[]` (required) | `[{name, ssh_keys: [...]}]`: SSH, NOPASSWD sudo, libvirt |
| `base_hardening_admin_group` | `admins` | sshd `AllowGroups` and sudoers group |
| `base_hardening_sshd_port` | `22` | sshd port (opened for the management CIDRs) |
| `base_hardening_firewall_allowed_ports` | `[]` | extra inbound ports, e.g. `[{port: "5900-5999", proto: tcp}]` |
| `base_hardening_chrony_pools` / `_servers` | Debian pool / `[]` | NTP sources |
| `base_hardening_journald_max_use` | `1G` | journal disk budget |
| `kvm_host_allow_software_emulation` | `false` | continue without vmx/svm (lab only) |
| `kvm_host_nested_virtualization` | `true` | guests may run KVM themselves |
| `kvm_host_storage_pool_path` | `/var/lib/libvirt/nvme` | directory pool (mount the NVMe here) |
| `kvm_host_storage_pool_require_mountpoint` | `false` | fail unless the path is a mount point |
| `kvm_host_libvirt_default_network_enabled` | `false` | libvirt NAT network (lab: `true`) |
| `kvm_host_guests_on_shutdown` / `_on_boot` | `shutdown` / `start` | libvirt-guests behaviour |

Common changes:

- **Another host:** add it under `kvm_hosts` in `hosts.yml`; per-host differences go to `host_vars/<name>.yml`.
- **NTP servers:** `base_hardening_chrony_pools: []` and `base_hardening_chrony_servers: [ntp1.example.org]`.
- **Management CIDR:** edit `base_hardening_management_cidrs`; preflight refuses to run if the controller
  would be locked out by the new list.
- **Admin users:** add `{name: ..., ssh_keys: ["ssh-ed25519 AAAA... comment"]}` items. Listed keys replace
  all others in that account; an admin removed from the list keeps the account but should be locked by hand.
- **Storage path:** set `kvm_host_storage_pool_path` before the first run (an existing pool's path is not
  changed silently; the play stops and says so).

The lab inventory still has one placeholder, the admin public key (`CHANGEME_SSH_ED25519_PUBLIC_KEY`);
preflight stops until it is replaced.

## Run

First time on the lab VM (`lab-kvm01`, 192.168.56.10), as the installer user `hramin`:

```sh
ansible-galaxy collection install -r requirements.yml
ssh-keyscan -H 192.168.56.10 >> ~/.ssh/known_hosts
ansible-playbook site.yml --tags bootstrap --ask-become-pass   # Run 0: preflight, admin users/keys/sudo, sshd
ansible-playbook site.yml -e ansible_user=hramin               # Run 1: everything
ansible-playbook site.yml -e ansible_user=hramin               # Run 2: must show changed=0 failed=0
```

`--ask-become-pass` is needed while the installer user's sudo asks for a password; Run 0 gives the
admin group passwordless sudo. Run 0 touches nothing that could cut access (no firewall), so a typo in
a key or CIDR is caught before the firewall exists.

One-shot alternative (also works on a fresh VM): `ansible-playbook site.yml --ask-become-pass`, then
`ansible-playbook site.yml` again as an admin user.

Parts only (preflight checks always run):

| Tag | Covers |
|---|---|
| `bootstrap` | admin users, keys, sudo, sshd (first contact) |
| `users`, `ssh` | the same two halves separately |
| `packages` | apt cache, base and hypervisor packages, purge list |
| `firewall` | nftables ruleset and service |
| `ntp` | chrony |
| `sysctl` | hardening and hypervisor sysctls (with `kernel`: modules, nested, /dev/kvm) |
| `kernel` | KVM modules, nested option, hypervisor sysctls |
| `logging` | journald, auditd, libvirt/QEMU logrotate (`auditd` alone: audit rules) |
| `libvirt` | libvirtd, libvirt group, pool, networks, libvirt-guests (`storage`, `network`, `guests` alone) |
| `base_hardening`, `kvm_host` | one role |

Dry run against an already configured host: `ansible-playbook site.yml --check --diff` (on a fresh host
it stops early, because later checks need the packages the run would install).

## Idempotency

| Area | What could make it non-idempotent | How this role avoids it |
|---|---|---|
| command tasks | commands always report "changed" | the only commands are read-only checks (`grep` vmx, `nft list table`, CIDR check) with `changed_when: false` and `check_mode: false`; `augenrules --load` is a handler |
| config files | rewriting files every run | `template`/`lineinfile` compare content; `validate` (`sshd -t`, `visudo -cf`, `nft -c`) means a broken file is never written |
| services | restarting on every run | handlers only, fired by a changed file; reload where possible (sshd, nftables); `force_handlers` keeps a pending reload after a failure |
| firewall | `flush ruleset` wiping libvirt's rules, which libvirt re-adds | the file replaces only `inet host_firewall` in one transaction and is loaded only when it changed; a drop-in replaces `ExecStop=nft flush ruleset`; a reload happens only if the table is missing |
| sysctls | `sysctl -p` of a whole file; multi-value keys | `ansible.posix.sysctl` per key compares file and live value (word by word, so `kernel.printk = 3 4 1 7` matches); `net.bridge.*`/`net.ipv6.*` set live only when they exist; `ip_forward` left to libvirt |
| libvirt objects | re-defining pools/networks | `virt_pool`/`virt_net` define only if absent; state and autostart are compared first; a changed pool path stops the play |
| libvirtd | Debian's `--timeout 120` lets the daemon exit when idle, so "started" changes on the next run | `/etc/default/libvirtd` clears the timeout |
| libvirt-guests | a restart handler would shut down all guests | no handler; the unit only needs to be active |
| auditd | `auditd.service` has no reload; restarting re-runs the rule loader | the role only manages its rules file; `augenrules --load` runs when it changes |
| users/keys | appending keys every run | `authorized_key exclusive: true` compares the whole key set; groups with `append` |
| packages | `latest`, upgrades, cache refresh | `state: present`, `cache_valid_time: 1800` (a cache refresh never reports changed), no upgrade task; purging an absent package is a no-op |
| downloads | download-then-delete repeats every run | nothing is downloaded outside apt |

How to check: run the playbook twice and read the second `PLAY RECAP` (`changed=0 failed=0`). To find a
task that changed: `grep -B2 '^changed:' tests/output/run2.log`, or run the second time with `--diff`.

## Testing

```sh
BOOTSTRAP=1 ASK_BECOME_PASS=1 scripts/test-idempotency.sh   # Run 0 (bootstrap), Run 1, Run 2
ASK_BECOME_PASS=1 scripts/test-idempotency.sh               # one-shot: Run 1, Run 2
```

Use a clean VM (fresh install or a snapshot taken right after install). The script runs as the inventory's
`ansible_user` first and as the first admin user afterwards (`ADMIN_USER` overrides), writes
`tests/output/run{0,1,2}.log` (git-ignored) and exits non-zero unless Run 2's PLAY RECAP shows `changed=0`,
`failed=0`, `unreachable=0`; it then lists the tasks that changed. Static checks:
`ansible-playbook --syntax-check site.yml && yamllint . && ansible-lint`.

For the submission I add the lab run's second-run output myself: `git add -f tests/output/run2.log`.

## Design decisions

- Two roles: `base_hardening` (any Debian server: access, firewall, time, sysctls, logging) and `kvm_host`
  (hypervisor). `site.yml` runs them in that order.
- Lock-out protection: users, keys and sudo exist before sshd is restricted; config files are validated;
  preflight stops if the controller's address is outside the management CIDR; `bootstrap` does access
  first, the firewall later.
- The firewall owns one nftables table and never flushes the ruleset, so libvirt's NAT rules survive
  reloads; there is no forward chain, so bridged guest traffic is not filtered by the host.
- Storage is a libvirt directory pool on the NVMe filesystem (qcow2/raw files: snapshots and backing files
  work, any filesystem); an optional mount-point check keeps images off the root filesystem.
- libvirt's default NAT network is off by default (production guests would use a bridge) and on in the
  single-NIC lab.
- On host shutdown guests get a clean ACPI shutdown (300 s), and what was running starts again on boot.
- Debian defaults are kept where they already do the job: auditd log rotation, libvirt group access via
  polkit, virtlogd rotation of QEMU logs.

## Scope cuts

Removed from earlier versions of this repository (the test tooling is on branch `dev-test-harness`):

- **molecule Docker scenario, QEMU/TCG test harness, committed test logs:** test tooling, not the role;
  the lab VM run is the test of record.
- **fail2ban:** SSH is key-only and reachable only from the management CIDR, so it would mostly ban admins.
- **auditd:** the 300-line multi-distro rule set became ~30 hypervisor rules; `auditd.conf` stays as
  Debian ships it; no `audit=1` GRUB argument (the role never touches the bootloader) and no immutable
  `-e 2` (rule changes would need a reboot).
- **Module blocklists, cron/at permissions, login.defs ageing/umask, TMOUT, /tmp tmpfs, /proc hidepid,
  SSH banner, apt.conf tweaks:** general CIS hardening beyond this task.
- **Opt-in upgrade task:** patching is a separate, scheduled process.
- **VM bridge (systemd-networkd):** with more time; it depends on each site's NIC layout and the lab VM has one NIC.
- **libvirt socket permissions/polkit changes and virtlogd tuning:** Debian's defaults are sufficient.
- **Variables nobody needs to change:** now fixed in templates with the reason next to them.

## Results / what did not work
