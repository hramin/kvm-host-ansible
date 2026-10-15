# kvm-host-ansible

Ansible playbook and two roles that take a **fresh Debian 12 or 13 server** to a
**ready KVM/libvirt virtualization host** with local NVMe storage. A second run
reports `changed=0`.

| Role | What it does |
|---|---|
| `roles/base_hardening` | Your Ubuntu 22.04 hardening role, adapted for Debian: preflight checks, admin users + SSH keys + sudo, hardened sshd, nftables host firewall that coexists with libvirt, chrony, kernel hardening sysctls, module blocklists, `/tmp` and `/proc` mount options, persistent journald, auditd with your rules, fail2ban, apt hardening, cron permissions. |
| `roles/kvm_host` | Hypervisor: vmx/svm and `/dev/kvm` checks, QEMU/libvirt/OVMF packages, KVM kernel modules (nested configurable), hypervisor sysctls, libvirtd and socket access, NVMe directory storage pool, libvirt networks (default NAT off by default, optional bridge), libvirt-guests, libvirt/QEMU log rotation. |

```
ansible.cfg  site.yml  requirements.yml
inventories/lab/{hosts.yml,group_vars/all.yml}
roles/base_hardening/  roles/kvm_host/        defaults/ handlers/ meta/ tasks/ templates/ vars/
molecule/default/                             Docker test scenario (Debian 12 + 13)
scripts/test-idempotency.sh                   two runs against the lab VM
tests/output/                                 logs of the test runs
```

## Requirements

**Controller:** Ansible ≥ 2.16 (tested with ansible-core 2.21.5), the collections in
`requirements.yml` (ansible.posix, community.general, community.libvirt), an SSH client.

**Target:** Debian 12 (bookworm) or 13 (trixie), amd64, with `python3` and `sudo`,
reachable over SSH with a key, as a user that can `sudo`. For real use the CPU
must expose vmx (Intel VT-x) or svm (AMD-V); a lab VM needs nested virtualization.

## How to run

```sh
ansible-galaxy collection install -r requirements.yml   # into ./collections
$EDITOR inventories/lab/hosts.yml inventories/lab/group_vars/all.yml   # replace every CHANGEME
ssh-keyscan -H <vm-ip> >> ~/.ssh/known_hosts            # host_key_checking is on

ansible-playbook site.yml                               # first run, as the first-connection user
ansible-playbook site.yml -e ansible_user=<admin>       # later runs (see "Who can log in after the first run")
```

- `ansible-playbook site.yml --tags upgrade` runs **only** the full package upgrade
  (`apt upgrade: safe` by default). A normal run never upgrades packages.
- Other tags: `firewall`, `ssh`, `users`, `ntp`, `sysctl`, `logging`, `auditd`,
  `fail2ban`, `kernel`, `libvirt`, `storage`, `network`, `guests`, `packages`.
  Preflight checks always run.

### Placeholders to fill in

The values below were not provided yet. They are `CHANGEME_…` placeholders in
`inventories/lab/`, and preflight refuses to run while any is left.

| Placeholder | File | Meaning |
|---|---|---|
| `CHANGEME_LAB_VM_IP` | `hosts.yml` | Address of the lab VM (`ansible_host`) |
| `CHANGEME_FIRST_CONNECTION_USER` | `group_vars/all.yml` | `ansible_user` for the first connection |
| `CHANGEME_12_OR_13` | `group_vars/all.yml` | `base_hardening_debian_version` |
| `CHANGEME_MGMT_CIDR` | `group_vars/all.yml` | `base_hardening_management_cidrs`, e.g. `x.x.x.0/24` |
| `CHANGEME_ADMIN_USER` | `group_vars/all.yml` | admin login name |
| `CHANGEME_SSH_ED25519_PUBLIC_KEY` | `group_vars/all.yml` | the admin's public key (`ssh-ed25519 AAAA… comment`) |

### Who can log in after the first run

sshd only admits members of `base_hardening_admin_group` (`admins`), and root
login is off. Users, keys and sudo are created **before** sshd is changed, and
preflight stops the play before anything is changed when:

- an admin user has no SSH key (or no password while sudo would ask for one);
- the controller's SSH source address is **not** inside
  `base_hardening_management_cidrs` (the firewall would drop the next connection);
- any `CHANGEME` placeholder is left, or the target is not the chosen Debian release.

If the first-connection user is not one of the admin users, it can no longer
log in afterwards (the play prints a note). Connect as an admin from then on:
`-e ansible_user=<admin>`, or `RUN2_USER=<admin>` for the test script.

## Design decisions

**Firewall (nftables) and libvirt.** The role owns exactly one table,
`inet host_firewall`. `/etc/nftables.conf` has **no `flush ruleset`**: it does
`table` → `delete table` → define, which nft applies as one transaction, so only
this table is replaced. libvirt's tables (`ip/ip6 libvirt_network`, or the
iptables-nft tables it creates on Debian 12/13) and fail2ban's `inet f2b-table`
are never touched. Debian's `nftables.service` runs `nft flush ruleset` on stop
(and so on restart); a drop-in replaces that with deleting only our table, and
the handler uses **reload**, never restart. Input policy is drop. Allowed:
established/related, loopback, essential ICMP/ICMPv6 (plus rate-limited echo), SSH
from the management CIDRs, DHCP/DNS from guests on `virbr*`, and
`base_hardening_firewall_allowed_ports` (empty by default). There is **no forward
chain**: bridged guest frames never reach the input hook, `bridge-nf-call-* = 0`
keeps them out of the IP hooks entirely, and routed/NAT guest traffic is libvirt's
business. The ruleset is checked with `nft -c` before it is written; a rerun only
reloads if the file changed or the table has gone missing, so the live ruleset
does not change on rerun.

**libvirt daemon and access.** Debian runs the monolithic `libvirtd`
(socket-activated) on both releases; the role keeps that. Debian's unit passes
`--timeout 120`, which stops libvirtd after two idle minutes; `/etc/default/libvirtd`
clears it, so the daemon stays running (and "running" stays true on reruns).
The sockets are `0770 root:libvirt` instead of Debian's world-connectable `0666`
+ polkit, with `auth_unix_ro/rw = "none"`: access is the libvirt group (the admins),
and it does not depend on polkit (which matters with `hidepid`).

**Storage: directory pool.** Pool `nvme` (`dir` type) at
`kvm_host_storage_pool_path`, default `/var/lib/libvirt/nvme`. Mount the NVMe
filesystem (XFS or ext4) there; guest disks are qcow2/raw files. A directory pool
keeps snapshots/backing files/`virsh vol-*` simple and works on any filesystem; LVM
gives raw block devices but no qcow2 features and is harder to resize safely
from Ansible. `kvm_host_storage_pool_require_mountpoint: true` makes the play fail
when the NVMe is not mounted, so images never land on the root filesystem. The
role does not partition or format disks. Changing the path of an existing pool
fails loudly (libvirt `define` would silently keep the old path).

**libvirt's default NAT network: disabled by default.** Production guests use
the bridge; the NAT network would add a `192.168.122.0/24` router, dnsmasq and
libvirt firewall rules to every hypervisor. It is stopped and not autostarted
but stays **defined**, so `virsh net-start default` still works.
`kvm_host_libvirt_default_network_enabled: true` (set in the lab inventory,
because the lab VM has one NIC and the bridge is off) starts and autostarts it.

**VM bridge: off by default.** When enabled, systemd-networkd creates
`kvm_host_bridge_name` with the uplinks in `kvm_host_bridge_interfaces`, and a
libvirt network (`forward mode="bridge"`) points at it. networkd only manages
those interfaces, so it coexists with ifupdown/netplan on the management NIC. The
play refuses to enslave the interface carrying the default route unless
`kvm_host_bridge_allow_default_route_interface: true` (do that with console
access: the host's address moves to the bridge).

**libvirt-guests.** On host shutdown guests get a clean ACPI shutdown (4 in
parallel, 300 s timeout); on boot the guests that were running are started again.
`kvm_host_guests_on_shutdown: suspend` switches to managed save/resume (needs disk
space equal to guest RAM under `/var/lib/libvirt/qemu/save`). There is deliberately
no restart handler: stopping libvirt-guests shuts down all guests.

**Kernel parameters.** Hardening sysctls from your `tuning.yaml` stay in
`/etc/sysctl.d/99-hardening.conf`; hypervisor settings (each with a one-line why)
go to `/etc/sysctl.d/60-kvm-host.conf`: `bridge-nf-call-{iptables,ip6tables,arptables}=0`,
`vm.swappiness=10`, `vm.dirty_background_ratio=5`, `vm.dirty_ratio=10`,
`vm.zone_reclaim_mode=0`, `fs.aio-max-nr=1048576`. `net.bridge.*` only exists while
`br_netfilter` is loaded; a udev rule re-applies it whenever the module loads later.
Every key is set live one by one (no `sysctl -p` of a whole file). `ip_forward` is
not managed: libvirt switches it on for NAT networks, and pinning it would undo
that on every run. Modules `kvm`, `kvm_intel`/`kvm_amd` (detected from vmx/svm),
`vhost_net`, `tun`, `bridge` load now and via `modules-load.d`; nested
virtualization is set in `modprobe.d` and applies on the next module load (the
play says so when the running value differs).

**Hypervisor defaults for the three requested switches.** `kernel.sysrq = 176`
(sync + remount read-only + reboot: enough to recover a hung host from the
console, no debug/kill functions). IPv6 stays **enabled** (guests and libvirt
networks may need it; the inet firewall table filters IPv6 like IPv4). `/proc` is
mounted `hidepid=invisible`: QEMU command lines name every VM and disk, and
non-root users have no need to see them. A kernel booted with `ipv6.disable=1`
is handled (the `net.ipv6.*` keys are written but not set live).

**auditd.** Your rules, adapted: Docker block replaced by libvirt/QEMU watches,
Ubuntu-only and RHEL-only paths removed, `/etc/nftables.conf` and
`/etc/sysctl.d` watched. `-e 2` (immutable) is kept, behind
`base_hardening_auditd_immutable`; the rules handler sees immutable mode and
reports "applies after the next reboot" instead of failing. `audit=1
audit_backlog_limit=8192` go into `/etc/default/grub.d/99-hardening-audit.cfg`
and `update-grub` runs as a handler (skipped with a message if the host does
not boot through GRUB). `space_left_action` is `syslog` instead of your `email`:
a minimal Debian install has no MTA.

**Logging.** journald is persistent (`/var/log/journal`) with `SystemMaxUse=1G`,
`SystemKeepFree=2G`, 128 MB files and 3 months retention, as a drop-in. QEMU guest
logs are rotated by virtlogd itself (2 MiB × 3 backups, configurable);
`/etc/logrotate.d/libvirtd.qemu` replaces the package file with a size threshold
just above virtlogd's (a fallback if virtlogd is switched off), and
`/etc/logrotate.d/libvirtd` covers daemon log files. Replacing the package files
(rather than adding new ones) avoids duplicate logrotate entries, which make
logrotate fail.

**Packages.** Debian names only, installed without recommends (as your apt
config asks): see `base_hardening_packages` and `kvm_host_packages`. A small
blocklist is purged (telnet/rsh/talk/nis/tftp/xinetd, avahi-daemon, rpcbind,
popularity-contest, prelink), plus ntp/ntpsec/systemd-timesyncd/openntpd.

**Idempotency.** Declarative modules wherever one exists; every
`command`/`shell` task has `changed_when` (and `failed_when` where needed); no
download-then-delete; no append-style firewall restore; handlers only
reload/restart the service whose own config changed; `force_handlers` in
`ansible.cfg` so a written config is never left unapplied after a failure.

### What was adapted, added and dropped

| Seed file | Change |
|---|---|
| all seed files | CRLF → LF in a separate commit (CR would end up in TMOUT, audit keys, sshd values) |
| `tasks/*.yml` | FQCN, booleans, quoted modes, `loop`, role-prefixed variables, play-level become |
| `account_settings.yml` | anchored `login.defs` regexps (comments matched too), umask variable, TMOUT task |
| `cron.yml` | `touch` with preserved timestamps (was "changed" on every run) |
| `packagemgmt.yml` | `98-hardening` instead of `98-hardening-ubuntu`; upgrade moved to opt-in `upgrade.yml`; dead clean/autoremove handlers dropped |
| `tuning.yaml` → `tuning.yml` | K8s `ip_forward` dropped; IPv6 and sysrq from variables; swappiness moved to kvm_host; live per-key apply |
| `auditd.yml` | anchored GRUB drop-in + `update-grub` handler; auditd.conf changes reload auditd; auditd enabled/started |
| `sshd_config.j2` | `PermitRootLogin no`, `AllowGroups`, `KbdInteractiveAuthentication`, ML-KEM KEX on Debian 13, `Include` moved last |
| `jail.local.j2` | nftables ban actions, systemd backend, sshd jail enabled explicitly |
| `hardening.rules.j2` | Docker → libvirt/QEMU watches, Ubuntu/RHEL paths removed, `-e 2` optional |
| `journald.conf.j2` | drop-in, size limits, no syslog forwarding |
| `tmp.mount.j2`, `tmout.sh.j2` | Debian unit options + size cap; readonly-safe TMOUT |

New: preflight, users/sudo, ssh tasks, nftables firewall, chrony, mounts,
journald/fail2ban tasks, the whole `kvm_host` role, inventory, molecule scenario,
test script.

Dropped: Kubespray preparation and K8s sysctls, Lynis download, Ubuntu-only
packages and paths (apport, whoopsie, update-notifier, fwupd/secureboot-db, snap),
Docker audit rules, iptables/netfilter-persistent (replaced by nftables), the
apt upgrade in the normal run, auditd `email` action (no MTA).

### Variable names of the old role

| Old | New |
|---|---|
| `password_max_day`, `password_min_day` | `base_hardening_password_max_days`, `base_hardening_password_min_days` |
| `timeout_time` | `base_hardening_shell_timeout` |
| `sshd_config.Port` / `.ListenAddress` | `base_hardening_sshd_port` / `base_hardening_sshd_listen_addresses` (list) |
| `sshd_config.PasswordAuthentication` | `base_hardening_sshd_password_authentication` (bool) |
| `sshd_config.AllowUsers` / `.AllowGroups` | `base_hardening_sshd_allow_users` (list) / `base_hardening_admin_group` |
| `sshd_config.PermitRootLogin` | fixed to `no` |
| `fail2ban.*` | `base_hardening_fail2ban.*` |
| `auditd_apply_audit_rules`, `auditd_*` | `base_hardening_auditd_apply_rules`, `base_hardening_auditd_*` |
| `grub_audit_cmdline`, `grub_audit_backlog_cmdline` | `base_hardening_grub_audit_cmdline`, `base_hardening_grub_audit_backlog_cmdline` |
| `block_blacklisted`, `*_modules_blocklist` | `base_hardening_block_blacklisted`, `base_hardening_*_modules_blocklist` |
| `packages_blocklist` | `base_hardening_packages_blocklist` |

## Variables

Every variable is documented in the role's `defaults/main.yml`; this table is
generated from those comments.

#### base_hardening

| Variable | Default | Description |
|---|---|---|
| `base_hardening_test_mode` | `"{{ kvm_host_test_mode \| default('off') }}"` | Follows kvm_host_test_mode; set that one, not this. "container" skips only what a container cannot do (live non-namespaced sysctls, live nftables load, auditd service/rule load, GRUB). See README "Container test mode". |
| `base_hardening_debian_version` | `"13"` | Debian major version the target must run. The play fails on any other release. |
| `base_hardening_supported_debian_versions` | `["12", "13"]` | Debian major versions this role supports. |
| `base_hardening_check_controller_in_management_cidrs` | `true` | Fail before touching SSH/firewall when the controller's SSH source address is outside base_hardening_management_cidrs (the next connection would be dropped by the firewall). Only checked for SSH connections. |
| `base_hardening_management_cidrs` | `[]` | Networks (IPv4 and/or IPv6 CIDRs) allowed to reach SSH. Required. |
| `base_hardening_admin_group` | `"admins"` | Group whose members may log in over SSH (sshd AllowGroups) and use sudo. |
| `base_hardening_admin_users` | `[]` | Admin accounts, created before sshd is reconfigured. Each item: name:     login name (required) ssh_keys: list of public keys (required, at least one) comment:  GECOS field (optional) shell:    login shell (optional, default /bin/bash) password: crypt(3) hash (optional; needed only when sudo asks for passwords) |
| `base_hardening_admin_keys_exclusive` | `true` | Remove authorized keys that are not listed in ssh_keys from admin accounts. |
| `base_hardening_admin_sudo_nopasswd` | `true` | Passwordless sudo for the admin group. Key-only accounts have no password, so they need this; set false only if every admin has a password hash. |
| `base_hardening_sshd_port` | `22` | Port sshd listens on (also used by the firewall and fail2ban). |
| `base_hardening_sshd_listen_addresses` | `["0.0.0.0"]` | Addresses sshd binds to. |
| `base_hardening_sshd_address_family` | `"inet"` | inet (IPv4 only), inet6 or any. Must cover base_hardening_sshd_listen_addresses. |
| `base_hardening_sshd_password_authentication` | `false` | Allow password logins (keys only by default). |
| `base_hardening_sshd_allow_tcp_forwarding` | `false` | Allow SSH TCP port forwarding (-L/-R). |
| `base_hardening_sshd_allow_users` | `[]` | Optional AllowUsers list, applied in addition to AllowGroups (both must match). |
| `base_hardening_sshd_max_auth_tries` | `3` | Authentication attempts per connection. |
| `base_hardening_sshd_max_sessions` | `2` | Sessions per connection (Ansible's ControlPersist reuses one connection). |
| `base_hardening_sshd_client_alive_interval` | `300` | Seconds between keepalive probes to idle clients. |
| `base_hardening_sshd_client_alive_count_max` | `2` | Unanswered keepalive probes before the client is disconnected. |
| `base_hardening_firewall_enabled` | `true` | Manage /etc/nftables.conf and nftables.service. |
| `base_hardening_firewall_table` | `"host_firewall"` | The one nftables table this role owns. Reloads replace only this table. |
| `base_hardening_firewall_allowed_ports` | `[]` | Extra inbound ports. Each item: port (number or "from-to"), proto (tcp\|udp), sources (list of CIDRs; default base_hardening_management_cidrs). Example: [{port: "5900-5999", proto: tcp}] for VNC consoles from management. |
| `base_hardening_firewall_guest_service_interfaces` | `["virbr*"]` | Interfaces on which guests reach the host's dnsmasq (DHCP/DNS) — libvirt NAT and isolated network bridges. Matching nothing is harmless. |
| `base_hardening_firewall_allow_icmp_echo` | `true` | Accept ICMP/ICMPv6 echo requests (rate limited). |
| `base_hardening_firewall_log_dropped` | `true` | Log dropped inbound packets (rate limited) with prefix "host_firewall drop: ". |
| `base_hardening_chrony_pools` | `["2.debian.pool.ntp.org"]` | NTP pools for chrony. Debian's own default; point to internal servers in production. |
| `base_hardening_chrony_servers` | `[]` | Individual NTP servers (used in addition to the pools). |
| `base_hardening_chrony_makestep` | `"1 3"` | chrony "makestep" threshold/limit: step the clock if off by more than 1 s in the first 3 updates. |
| `base_hardening_ntp_conflicting_packages` | `["ntp", "ntpsec", "systemd-timesyncd", "openntpd"]` | Time daemons that conflict with chrony; purged. |
| `base_hardening_packages` | see `defaults/main.yml` | Base packages: services this role configures plus basic admin tools. |
| `base_hardening_packages_extra` | `[]` | Additional site-specific packages. |
| `base_hardening_packages_blocklist` | see `defaults/main.yml` | Packages purged when present (legacy clear-text/network services, telemetry). |
| `base_hardening_upgrade_mode` | `"safe"` | apt upgrade mode for the opt-in upgrade task (--tags upgrade): safe \| full \| dist \| yes. |
| `base_hardening_password_max_days` | `120` | login.defs PASS_MAX_DAYS for new passwords. |
| `base_hardening_password_min_days` | `7` | login.defs PASS_MIN_DAYS for new passwords. |
| `base_hardening_umask` | `"077"` | login.defs UMASK (also the home directory mode basis). |
| `base_hardening_shell_timeout` | `600` | Idle timeout in seconds for interactive login shells (TMOUT, read-only). |
| `base_hardening_block_blacklisted` | `false` | Also block every module that is already "blacklist"ed in modprobe.d. |
| `base_hardening_fs_modules_blocklist` | see `defaults/main.yml` | Filesystems nobody needs on a hypervisor (vfat is kept when booted via EFI). |
| `base_hardening_misc_modules_blocklist` | see `defaults/main.yml` | Hardware/protocol modules a server does not use. |
| `base_hardening_net_modules_blocklist` | `["atm", "dccp", "sctp", "rds", "tipc"]` | Rarely used network protocols with a history of kernel bugs. |
| `base_hardening_disable_ipv6` | `false` | Disable IPv6 on the host. Off by default: guests and libvirt networks may need IPv6, and the inet firewall table filters IPv6 exactly like IPv4. |
| `base_hardening_sysctl_kernel_sysrq` | `176` | kernel.sysrq bitmask. 176 = sync (16) + remount read-only (32) + reboot (128): enough to recover a hung hypervisor from the console, no debug/kill functions. |
| `base_hardening_tmp_mount_enabled` | `true` | Mount /tmp as tmpfs with noexec,nodev,nosuid. |
| `base_hardening_tmp_mount_size` | `"2G"` | Size cap for the /tmp tmpfs (tmpfs memory competes with guest RAM). |
| `base_hardening_proc_hidepid` | `"invisible"` | /proc hidepid: off \| noaccess \| invisible \| ptraceable. "invisible" hides other users' processes (QEMU command lines name every VM and disk) from non-root users; libvirt access does not depend on it (socket group, no polkit). |
| `base_hardening_proc_hidepid_group` | `""` | Group exempt from hidepid (procfs gid=), e.g. for a monitoring agent. "" = none. |
| `base_hardening_journald_system_max_use` | `"1G"` | Disk space the persistent journal may use. |
| `base_hardening_journald_system_keep_free` | `"2G"` | Disk space journald always leaves free. |
| `base_hardening_journald_system_max_file_size` | `"128M"` | Size of one journal file before rotation. |
| `base_hardening_journald_max_retention` | `"3month"` | Drop journal entries older than this. |
| `base_hardening_journald_forward_to_syslog` | `false` | Also forward to a syslog daemon (Debian 12/13 install none by default). |
| `base_hardening_auditd_apply_rules` | `true` | Install the role's audit rules (templates/hardening.rules.j2). |
| `base_hardening_auditd_immutable` | `true` | Make the loaded rules immutable (-e 2). Later rule changes need a reboot; the rules handler detects this and reports it instead of failing. |
| `base_hardening_auditd_action_mail_acct` | `"root"` | Account notified by auditd mail actions. |
| `base_hardening_auditd_admin_space_left_action` | `"suspend"` | Action when free space reaches admin_space_left. |
| `base_hardening_auditd_disk_error_action` | `"suspend"` | Action on a disk write error. |
| `base_hardening_auditd_disk_full_action` | `"suspend"` | Action when the audit partition is full. |
| `base_hardening_auditd_max_log_file` | `8` | Maximum size of one audit log file in MB. |
| `base_hardening_auditd_max_log_file_action` | `"keep_logs"` | What to do when max_log_file is reached. |
| `base_hardening_auditd_mode` | `1` | Failure mode (-f): 0 silent, 1 printk, 2 panic. |
| `base_hardening_auditd_num_logs` | `5` | Number of rotated logs kept (with max_log_file_action = rotate). |
| `base_hardening_auditd_space_left` | `75` | Free space (MB) that triggers space_left_action. |
| `base_hardening_auditd_space_left_action` | `"syslog"` | The old role used "email", which needs an MTA (/usr/lib/sendmail) that a minimal Debian install does not have, so the warning would go nowhere; log it. |
| `base_hardening_auditd_grub_cmdline_enabled` | `true` | Add the audit kernel arguments to GRUB and run update-grub (handler). |
| `base_hardening_grub_audit_cmdline` | `"audit=1"` | Enable auditing from early boot, before auditd starts. |
| `base_hardening_grub_audit_backlog_cmdline` | `"audit_backlog_limit=8192"` | Kernel audit backlog so early-boot events are not lost. |
| `base_hardening_fail2ban` | see `defaults/main.yml` | Ban time, find window and retries for all jails (jail.local [DEFAULT]). |
| `base_hardening_fail2ban_ignoreip` | `[]` | Extra addresses/CIDRs fail2ban never bans (localhost is always ignored). |

#### kvm_host

| Variable | Default | Description |
|---|---|---|
| `kvm_host_test_mode` | `"off"` | "off" for real hosts. "container" (molecule Docker scenario only) skips what a container cannot do: kernel module loading, live non-namespaced sysctls, the /dev/kvm check — plus, in base_hardening, the live nftables load, auditd and GRUB. Everything else runs. See README "Container test mode". |
| `kvm_host_supported_debian_versions` | `["12", "13"]` | Debian major versions this role supports. |
| `kvm_host_allow_software_emulation` | `false` | Allow a host without hardware virtualization (no vmx/svm, no /dev/kvm), e.g. a lab VM without nested virtualization. Guests then run under QEMU TCG software emulation (10-50x slower); the play prints a warning. Never for production. |
| `kvm_host_kvm_vendor_module` | `"auto"` | KVM vendor module: auto (vmx -> kvm_intel, svm -> kvm_amd), kvm_intel, kvm_amd, none. |
| `kvm_host_nested_virtualization` | `true` | Let guests run their own hypervisor (kvm_intel/kvm_amd "nested" parameter). Takes effect when the module is (re)loaded, i.e. after a reboot. |
| `kvm_host_packages` | see `defaults/main.yml` | Hypervisor packages (Debian names; installed without recommends). |
| `kvm_host_packages_extra` | `[]` | Additional site-specific packages (e.g. virtinst, swtpm-tools). |
| `kvm_host_kernel_modules` | `["kvm", "vhost_net", "tun", "bridge"]` | Modules loaded now and at boot (modules-load.d); the vendor module is added. |
| `kvm_host_sysctl_settings` | see `defaults/main.yml` | Hypervisor sysctls, written to /etc/sysctl.d/60-kvm-host.conf with the "why" as a comment and applied live. net.bridge.* keys exist only while br_netfilter is loaded: they are applied when it is, and re-applied by a udev rule whenever br_netfilter loads later (e.g. pulled in by Docker). |
| `kvm_host_libvirtd_args` | `""` | Arguments for libvirtd. Debian's unit default is "--timeout 120", which makes the daemon exit after 2 idle minutes; empty keeps it running. |
| `kvm_host_libvirt_users` | `"{{ base_hardening_admin_users \| default([]) \| map(attribute='name') \| list }}"` | Users added to the libvirt group (full libvirt access over qemu:///system). |
| `kvm_host_libvirt_socket_group` | `"libvirt"` | Group that may use the libvirt sockets (socket mode 0770, no polkit). |
| `kvm_host_storage_pool_name` | `"nvme"` | Name of the libvirt storage pool. |
| `kvm_host_storage_pool_path` | `"/var/lib/libvirt/nvme"` | Directory holding guest images; put the NVMe filesystem (XFS/ext4) here. |
| `kvm_host_storage_pool_require_mountpoint` | `false` | Fail unless the pool path is its own mount point (protects the root filesystem from filling with guest images when the NVMe is not mounted). |
| `kvm_host_libvirt_default_network_enabled` | `false` | libvirt's "default" NAT network (virbr0, 192.168.122.0/24, dnsmasq on the host). false: stopped and not autostarted (kept defined, so "virsh net-start default" still works). true: defined, started and autostarted — useful on single-NIC labs. |
| `kvm_host_bridge_enabled` | `false` | Linux bridge for bridged guests (systemd-networkd). Off by default: on a single-NIC host enslaving the NIC moves the host's IP and can cut SSH. |
| `kvm_host_bridge_name` | `"br0"` | Bridge interface name. |
| `kvm_host_bridge_interfaces` | `[]` | Physical uplinks enslaved to the bridge. [] = bridge without uplink. |
| `kvm_host_bridge_ip_mode` | `"none"` | Host address on the bridge: none (L2 only, the host is not reachable via the bridge), dhcp, or static (then set kvm_host_bridge_address/gateway/dns). |
| `kvm_host_bridge_address` | `""` | Static address in CIDR form, e.g. 10.0.20.5/24 (ip_mode static only). |
| `kvm_host_bridge_gateway` | `""` | Default gateway on the bridge (ip_mode static only, optional). |
| `kvm_host_bridge_dns` | `[]` | DNS servers for the bridge (ip_mode static only, optional). |
| `kvm_host_bridge_stp` | `false` | Spanning tree on the bridge. |
| `kvm_host_bridge_allow_default_route_interface` | `false` | Allow the interface carrying the default route (usually the management NIC) in kvm_host_bridge_interfaces. Only with console access to the host. |
| `kvm_host_bridge_libvirt_network` | `"host-bridge"` | libvirt network (forward mode=bridge) pointing at the bridge, for "virt-install --network network=<name>". |
| `kvm_host_guests_on_boot` | `"start"` | On boot: "start" restarts guests that were running at shutdown; "ignore" leaves them off. |
| `kvm_host_guests_start_delay` | `0` | Seconds between starting guests on boot. |
| `kvm_host_guests_on_shutdown` | `"shutdown"` | On shutdown: "shutdown" (ACPI, clean) or "suspend" (managed save: RAM written to /var/lib/libvirt/qemu/save and resumed on boot — needs disk space = guest RAM). |
| `kvm_host_guests_parallel_shutdown` | `4` | Guests shut down in parallel (0 = one at a time). |
| `kvm_host_guests_shutdown_timeout` | `300` | Seconds to wait for guests to shut down before the host continues. |
| `kvm_host_guests_bypass_cache` | `false` | Bypass the page cache when saving guests (on_shutdown: suspend). |
| `kvm_host_guests_sync_time` | `true` | Resync the guest clock after resume (needs the QEMU guest agent). |
| `kvm_host_virtlogd_max_size` | `2097152` | virtlogd rotates the per-guest QEMU logs itself: size in bytes per log file... |
| `kvm_host_virtlogd_max_backups` | `3` | ...and number of rotated files kept per guest. |
| `kvm_host_logrotate_frequency` | `"weekly"` | logrotate for /var/log/libvirt/*.log (daemon logs). |
| `kvm_host_logrotate_rotate` | `8` | Rotated daemon logs kept. |
| `kvm_host_logrotate_maxsize` | `"100M"` | Rotate daemon logs early when bigger than this. |


## Testing

### Static checks

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install ansible-core ansible-lint yamllint molecule 'molecule-plugins[docker]' docker
ansible-galaxy collection install -r requirements.yml
ansible-playbook --syntax-check site.yml
yamllint .
ansible-lint            # profile: production
```

Lint exceptions (intentional, inline, each with its reason next to it):

- `roles/base_hardening/tasks/tuning.yml` disables yamllint's `commas` rule for
  that file, to keep the seed's column-aligned sysctl table.
- `roles/base_hardening/handlers/main.yml`, handler "Reload auditd":
  `noqa: command-instead-of-module` for `systemctl kill --signal=SIGHUP auditd`.
  Debian's auditd unit has no reload, and no module sends a signal to a unit.
- `tests/tcg-vm/build-rootfs.sh`: shellcheck SC2016 is disabled because the
  single quotes are deliberate (mmdebstrap expands `$1`).

No rule is skipped globally.

### Molecule (Docker, Debian 12 + 13)

The preferred test is a QEMU/KVM VM booting Debian's genericcloud image. That needs
`/dev/kvm`, which the machine these roles were developed on does not have, so the
scenario here is `molecule/default`: two privileged systemd containers
(`debian:12`, `debian:13`) that run the **unchanged `site.yml`** with
`kvm_host_test_mode: container`.

```sh
molecule test                 # dependency, destroy, create, converge, idempotence, verify, destroy
# or step by step:
molecule create && molecule converge && molecule idempotence && molecule verify && molecule destroy
```

Needs Docker and `rsync` on the controller. On cgroup v2 hosts this works as is;
on cgroup v1 hosts Debian 13's systemd 257 also booted fine in testing.

#### Container test mode

`kvm_host_test_mode: container` (default `"off"`) is the only test switch. It skips
only what a container cannot do; everything else runs, including package
installs, users/sudo, sshd (validated with `sshd -t`), chrony, fail2ban, journald,
tmp.mount, `/proc` hidepid, libvirtd, storage pool, networks, libvirt-guests,
logrotate and all file templates. Skipped tasks:

| Role / file | Task | In the container instead |
|---|---|---|
| base_hardening `tuning.yml` | Apply kernel hardening sysctl settings — live value of non-namespaced keys (`kernel.*`, `fs.*`, `dev.*`, `net.core.bpf_jit_harden`) | file `/etc/sysctl.d/99-hardening.conf` written; `net.ipv4.*`/`net.ipv6.*` set live |
| base_hardening `firewall.yml` | Start nftables (loads the ruleset) | ruleset rendered and checked with `nft -c -f`, service enabled |
| base_hardening `firewall.yml` | Check that the host firewall table is loaded; Reload the ruleset when the host firewall table is missing | — |
| base_hardening handlers | Reload nftables | — |
| base_hardening `auditd.yml` | Enable and start auditd | `auditd.conf` edited and rules file rendered |
| base_hardening handlers | Load audit rules; Reload auditd | — |
| base_hardening `auditd.yml` | Check for update-grub; Set Debian audit grub cmdline; Warn that the audit kernel arguments were not applied (GRUB) | — |
| kvm_host `kernel.yml` | Load KVM-related modules now | `modules-load.d` and `modprobe.d` files written |
| kvm_host `kernel.yml` | Read the current nested virtualization setting; Report that the nested setting applies after a reboot | — |
| kvm_host `kernel.yml` | Check /dev/kvm; Assert /dev/kvm exists…; Warn that /dev/kvm is missing | — |
| kvm_host `kernel.yml` | Apply hypervisor sysctls — live value of `vm.*`/`fs.*` keys | file `/etc/sysctl.d/60-kvm-host.conf` written; `net.bridge.*` set live |

The vmx/svm check is **not** skipped. The test machine has no vmx/svm, so the
scenario sets `kvm_host_allow_software_emulation: true` and the warning path runs.

The scenario also exercises paths that are off by default: Debian 12 builds the
bridge (systemd-networkd, no uplink) and its libvirt network; Debian 13 enables
the default NAT network.

Test-harness details (in `Dockerfile.j2`, not in the roles): `policy-rc.d` is
removed so packages start their services like on a real host; udev is masked (a
privileged udevd would receive the host's device events); chronyd runs with `-x`
so it does not steer the clock of the kernel it shares with the Docker host.

### Extra: full role on a QEMU/TCG VM

Containers cannot load modules, set global sysctls, run auditd or load a
firewall, so `tests/tcg-vm/` boots a fresh Debian 13 server image (built from
deb.debian.org with mmdebstrap) under QEMU software emulation. It then runs
`scripts/test-idempotency.sh` against it over real SSH, with no test mode. See
`tests/tcg-vm/README.md`. This is in addition to, not instead of, the lab run
below: it has no vmx/svm, so it uses `kvm_host_allow_software_emulation: true`.

### Results of the runs made while developing (2026-10-15)

| Test | Result | Logs |
|---|---|---|
| `ansible-playbook --syntax-check`, `yamllint`, `ansible-lint` (production) | clean | — |
| molecule `default`, Debian 12 + 13: create → converge → idempotence → verify → destroy | converge `changed=75` / `68`, `failed=0`; **idempotence `changed=0` on both**; verify 44 / 42 checks ok, `failed=0` | `tests/output/molecule-*.log` |
| QEMU/TCG Debian 13 VM, `scripts/test-idempotency.sh` (run 1 as `debian`, run 2 as admin) | run 1 `changed=75 failed=0`; run 2 `changed=0 failed=0` → PASS | `tests/output/tcg-vm-run{1,2}.log` |
| same VM, third run + live ruleset comparison | `changed=0`; ruleset identical apart from counters (7 tables: ours + libvirt's 6) | `tests/output/tcg-vm-ruleset-rerun.log`, `tcg-vm-run3.log` |
| same VM, state checks | debian/root/password logins refused; libvirt tables survive nftables reload **and** restart; `-e 2` rules loaded; no failed units | `tests/output/tcg-vm-checks.log` |

Bugs these runs found and fixed: `ipv6.disable=1` kernels, `/etc/protocols` lookup
in nft rules, mounting `/tmp` from under the running module, a leftover seed
variable, the udev rules directory, `virtlockd` on Debian 13, the missing
`default_ipv4` fact (all in molecule), and `auditd.service` having no reload
(only on the VM). The first VM attempt was stopped by the preflight lock-out
guard before any change (`tcg-vm-attempt1-lockout-guard.log`).

Not tested here: a real KVM-accelerated host (no `/dev/kvm`), Debian's
genericcloud image (download refused by this environment's egress proxy), Debian
12 on a VM (only in a container), and the bridge with a physical uplink.

### Clean-VM run (your lab)

Prerequisites: a **fresh** Debian 12 or 13 VM, **nested virtualization enabled**
(the VM's CPU shows `vmx` or `svm`), SSH key access as a user with sudo, the
placeholders filled in, and the VM's host key in `known_hosts`.

```sh
scripts/test-idempotency.sh                       # first-connection user is an admin user
RUN2_USER=<admin> scripts/test-idempotency.sh     # first-connection user is not
```

The script runs `site.yml` twice against `inventories/lab` with
`kvm_host_test_mode=off`, writes `tests/output/run1.log` and
`tests/output/run2.log`, and exits non-zero unless the second run's PLAY RECAP
shows `changed=0`, `failed=0` and `unreachable=0` (it then lists the tasks that
changed). Extra arguments are passed to `ansible-playbook`.

### Results / what did not work

_To be filled in from the lab run._
