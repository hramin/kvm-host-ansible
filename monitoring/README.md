# Monitoring and alerting

Prometheus and Alertmanager run in Docker on the controller (WSL2). node_exporter and the libvirt
exporter run on the KVM host (`lab-kvm01`, 192.168.56.10).

```
monitoring/
├── docker-compose.yml                    Prometheus v2.53.2 + Alertmanager v0.27.0 (host network)
├── prometheus/prometheus.yml             scrape targets: 192.168.56.10:9100 (node), :9177 (libvirt)
├── prometheus/rules/kvm-host.rules.yml   production alert rules
├── prometheus/rules/lab-test.rules.yml   short-window CPU/memory twins for the 30 s demo
├── alertmanager/alertmanager.yml         routing: critical pages, warning waits for business hours
└── scripts/load-test.sh                  CPU or memory load on the host (run on the VM)
```

## Alerts and paging policy

The rule of thumb: **page when customers are down or will be within minutes; wait for business
hours when redundancy or headroom is shrinking but nobody is affected yet.**

| Alert | Fires when | Severity | Why |
|---|---|---|---|
| `HostDown` | node_exporter unreachable 2 m | **page** | Up to 300 VMs on the host may be down |
| `VMPausedOrCrashed` | libvirt state paused (3) or crashed (6) for 1 m | **page** | Customer's VM is frozen; QEMU pauses guests itself on I/O errors or full disks |
| `DiskLatencyCritical` | avg I/O latency > 100 ms for 5 m | **page** | Guests stall now; rising latency preceded the host outage in the incident scenario |
| `DiskLatencyHigh` | > 20 ms for 10 m | business hours | NVMe should be < 1 ms; early sign of a failing device |
| `RaidArrayInactive` | md array inactive | **page** | No data served: every VM on it is down |
| `RaidDegraded`, `RaidDiskFailed` | member missing or failed for 5 m | business hours | Array still serves data; swap the disk next business day (escalate on a second failure) |
| `HostMemoryCritical` | < 5 % available for 2 m | **page** | OOM killer is near, and it kills the largest process: a customer's QEMU |
| `HostOomKill` | any OOM kill in 5 m | **page** | A process, possibly a VM, was just killed |
| `HostMemoryPressure` | < 10 % available for 10 m | business hours | No headroom for placement; rebalance |
| `HostPacketLossCritical` | > 5 % drops/errors on host NICs for 5 m | **page** | Guests see broken connections |
| `HostPacketLoss` | > 0.5 % for 15 m | business hours | Cabling/NIC/switch problem to fix before it grows |
| `HostHighLoad` | load15 > 2 × CPUs for 30 m | business hours | Guests get less CPU than sold; capacity problem, not an outage |
| `HostCpuSaturated` | CPU > 90 % for 15 m | business hours | Same; find the noisy neighbour |
| `LibvirtExporterDown` | exporter unreachable 5 m | business hours | Monitoring gap (VM alerts can't fire), VMs themselves unaffected |

Alertmanager: `critical` goes to the `pager` receiver at once (repeat 1 h); `warning` goes to
`business-hours`, which notifies only Mon–Fri 09:00–18:00. `HostDown` inhibits every other alert
from that host, and a critical alert hides its own warning (same `host` and `component`). Receivers
have no integrations in the lab; add PagerDuty/Slack/email there in production.

## 1. Deploy the exporters on the KVM host

```sh
ssh hra@192.168.56.10

# node_exporter (Debian package; listens on :9100, includes the mdadm, diskstats, netdev, vmstat collectors)
sudo apt update && sudo apt install -y --no-install-recommends prometheus-node-exporter

# libvirt exporter (inovex/prometheus-libvirt-exporter; listens on :9177)
curl -LO https://github.com/inovex/prometheus-libvirt-exporter/releases/download/v2.5.0/prometheus-libvirt-exporter-2.5.0.amd64.deb
sudo apt install -y ./prometheus-libvirt-exporter-2.5.0.amd64.deb
dpkg -L prometheus-libvirt-exporter | grep -E 'bin/|\.service'   # binary path and service unit
sudo systemctl enable --now prometheus-libvirt-exporter

curl -s localhost:9100/metrics | grep -m1 node_load1
curl -s localhost:9177/metrics | grep -m3 libvirt_
```

If the package ships no service unit, create `/etc/systemd/system/prometheus-libvirt-exporter.service`
(use the binary path from `dpkg -L`), then `sudo systemctl daemon-reload && sudo systemctl enable --now prometheus-libvirt-exporter`:

```ini
[Unit]
Description=Prometheus libvirt exporter
After=libvirtd.service

[Service]
ExecStart=/usr/bin/prometheus-libvirt-exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**Open the firewall** (the host drops everything except SSH). In the playbook inventory
`inventories/lab/group_vars/all.yml`:

```yaml
base_hardening_firewall_allowed_ports:      # sources default to the management CIDRs
  - {port: 9100, proto: tcp}
  - {port: 9177, proto: tcp}
```

then from the controller: `ansible-playbook site.yml --tags firewall`. (Quick, non-persistent
alternative on the VM: `sudo nft add rule inet host_firewall input ip saddr 192.168.56.0/24 tcp dport '{ 9100, 9177 }' accept`.)

From WSL: `curl -s 192.168.56.10:9100/metrics | head -3` must answer.

## 2. Start Prometheus and Alertmanager (WSL)

```sh
cd monitoring
docker compose up -d
docker compose ps
```

- Prometheus: http://localhost:9090 → *Status → Targets*: `node` and `libvirt` both **UP**
- Alertmanager: http://localhost:9093

After editing rules: `curl -X POST localhost:9090/-/reload`. Validate first with
`docker run --rm -v "$PWD/prometheus:/p" --entrypoint promtool prom/prometheus:v2.53.2 check config /p/prometheus.yml`.

If Docker Hub refuses the images, use `quay.io/prometheus/prometheus:v2.53.2` and
`quay.io/prometheus/alertmanager:v0.27.0` in `docker-compose.yml`.

## 3. Test scenarios

Watch http://localhost:9090/alerts (pending → firing) and http://localhost:9093 at the same time.

### VM failure (pause a guest)

A test guest with an empty disk is enough: libvirt reports it as running while SeaBIOS waits for a
boot device. On the VM:

```sh
sudo apt install -y --no-install-recommends virtinst
sudo virt-install --name testvm --virt-type qemu --memory 256 --vcpus 1 \
  --disk size=1,pool=nvme --import --osinfo generic \
  --network network=default --graphics none --noautoconsole
virsh -c qemu:///system list --all          # testvm: running

sudo virsh suspend testvm                   # state 3 (paused)
# about 1 minute later: VMPausedOrCrashed firing (critical) in Alertmanager
sudo virsh resume testvm                    # alert resolves
```

(`--virt-type qemu` because the lab VM has no KVM acceleration; drop it on real hardware.)

### CPU pressure

```sh
scp scripts/load-test.sh hra@192.168.56.10:     # from WSL, once
ssh hra@192.168.56.10 ./load-test.sh cpu 30
```

`LabCpuPressure` (warning) goes firing within about 20 s and resolves shortly after the script ends.

### Memory pressure

```sh
ssh hra@192.168.56.10 ./load-test.sh mem 30 90   # hold 90 % of available memory for 30 s
```

`LabMemoryPressure` (warning) fires while the memory is held. If it does not, raise the percentage
(e.g. `95`); the script prints available memory every 2 s, and the alert needs < 15 %.

Warnings outside Mon–Fri 09:00–18:00 UTC are not notified but still show in the Alertmanager UI.
The production twins (`HostCpuSaturated`, `HostMemoryPressure`) do not fire on a 30 s test, by
design: their `for` windows are 15 and 10 minutes so short spikes never page anyone.

### Not tested in the lab

RAID (the VM has no md array), disk latency and packet loss need real faults; the rules were checked
with `promtool test rules` against synthetic series instead.
