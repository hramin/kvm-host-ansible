# Lab issues

Problems met while building the test lab (Debian 12 VM in VirtualBox on Windows 10, Ansible from
WSL2) and running the playbook, with cause and fix. Setup steps: README, "Setup and run".

## Lab setup (VirtualBox, networking)

| # | Problem | Cause | Fix |
|---|---|---|---|
| 1 | `hra` had no sudo | A root password was set in the Debian installer, so sudo was not installed | As root: `apt install sudo; usermod -aG sudo hra` |
| 2 | WSL could not reach the VirtualBox NAT port forward (`2222`), even with a Windows Firewall rule | Windows 10: WSL2 runs only in NAT mode (mirrored networking needs Windows 11); WSL-to-Windows inbound traffic was blocked | Dropped port forwarding; added a host-only adapter |
| 3 | VM not reachable at `192.168.56.10` | Adapter 2 not attached, so the VM had only the NAT address `10.0.2.15` | Enabled Adapter 2 (host-only) with the VM powered off; static IP on `enp0s8` |

## Running the playbook

| # | Problem | Cause | Fix |
|---|---|---|---|
| 4 | `ansible-galaxy collection install` failed with HTTP 403 | galaxy.ansible.com refused the connection from this network | `pip install ansible`, which bundles ansible.posix, community.general, community.libvirt |
| 5 | Warning: no vmx/svm CPU flag | WSL2 keeps Hyper-V on, so VirtualBox cannot pass nested VT-x to the VM | `kvm_host_allow_software_emulation: true`; guests run under QEMU emulation (lab only) |
| 6 | Run 1 failed right after Run 0: "Missing sudo password" | Ansible reused Run 0's SSH connection (`ControlPersist=120s`), opened before `hra` joined `admins` (passwordless sudo) | `rm -f ~/.ansible/cp/*` before Run 1. Code fix: `meta: reset_connection` after the users task |
| 7 | `virsh pool-list` / `net-list` as `hra` showed nothing | Without a URI, non-root `virsh` connects to the per-user `qemu:///session` | `virsh -c qemu:///system ...` (or `sudo virsh`) |

## Smoke test on the lab VM

`sudo virt-host-validate qemu`: hardware virtualization FAIL (expected, see 5); `/dev/vhost-net`,
`/dev/net/tun` and all cgroup controllers PASS; IOMMU and secure-guest WARN (not available in a VM).
`lsmod` shows `kvm` but no `kvm_intel`/`kvm_amd`, and `virsh capabilities` offers `domain type='qemu'`
only, both consistent with no vmx/svm.
