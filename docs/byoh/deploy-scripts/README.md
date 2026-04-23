# Ubicloud BYOH — Proxmox Deployment Scripts

Automated shell scripts to deploy Ubicloud BYOH on a Proxmox VE host.

## Target deployment

- **Server**: Proxmox VE 8+ on bare metal (tested on OVH 64 GB, and homelab 16 GB)
- **Output**: Ctrl plane VM + data plane VM + ready-to-use Ubicloud web UI
- **Time**: ~30-40 minutes end-to-end (Ruby compile dominates)

## Files

| Script | Run on | Purpose |
|--------|--------|---------|
| `00-preflight.sh` | Proxmox host | Verify hardware, enable nested virt, create vmbr1 bridge |
| `01-create-vms.sh` | Proxmox host | Create VM template + ctrl plane (400) + data plane (401) |
| `02-post-boot-fixup.sh` | Proxmox host | Fix root SSH on data plane, stage scripts on ctrl plane |
| `03-bootstrap-ctrl.sh` | Ctrl plane VM | Clone repo + install Ruby/Node/Postgres + start services |
| `04-register-host.sh` | Ctrl plane VM | Generate SSH key, register host with Ubicloud |
| `05-monitor.sh` | Ctrl plane VM | Live monitoring dashboard |
| `99-deploy-all.sh` | Proxmox host | Master orchestrator — runs phases 1-5 |
| `reset.sh` | Proxmox host | Destroy all Ubicloud VMs (to start over) |

## Quick start

```bash
# On Proxmox host:
mkdir -p /root/ubicloud-deploy
cd /root/ubicloud-deploy
# Copy all the .sh files here, then:
chmod +x *.sh
bash 99-deploy-all.sh
```

## Tunable parameters

Every script reads environment variables for sizing. Defaults target
a 64 GB host with 40 GB reserved for other workloads (leaving ~22 GB
for Ubicloud):

### `01-create-vms.sh`

```bash
# VM IDs
VMID_TMPL=9000      # template
VMID_CTRL=400       # ctrl plane
VMID_DATA=401       # data plane

# Storage pool (check with: pvesm status)
STORAGE=local-lvm

# SSH key
PUBKEY=/root/.ssh/id_rsa.pub

# Ctrl plane sizing
CTRL_CORES=2
CTRL_MEM=4096
CTRL_DISK_ADD=38    # disk added to template's 2 GB base

# Data plane sizing — adjust based on your host
DATA_CORES=8        # must be <= host logical CPUs
DATA_MEM=18432      # 18 GB — gives ~12 hugepages after OS overhead
DATA_DISK_ADD=198   # 200 GB total

# IPs
CTRL_IP=10.98.1.10
DATA_IP=10.98.1.30
GATEWAY=10.98.1.1
```

Override like this:

```bash
DATA_CORES=16 DATA_MEM=32768 DATA_DISK_ADD=498 bash 01-create-vms.sh
```

### Low-tier hardware (16 GB host, 4 threads)

```bash
DATA_CORES=4 DATA_MEM=12288 DATA_DISK_ADD=118 bash 01-create-vms.sh
```

With 12 GB data plane RAM you get 6-7 hugepages — enough for
burstable VMs but not standard-2. `04-register-host.sh` will
auto-detect <6 cores and set `accepts_slices=false`.

### Medium-tier (32 GB host, 8 threads)

```bash
DATA_CORES=8 DATA_MEM=20480 DATA_DISK_ADD=198 bash 01-create-vms.sh
```

### High-tier (64 GB+ host, 16+ threads)

```bash
DATA_CORES=16 DATA_MEM=40960 DATA_DISK_ADD=498 bash 01-create-vms.sh
```

## Phased execution

If you want to run phases separately (debug / resume):

```bash
# Phase 1 - hardware check
bash /root/ubicloud-deploy/00-preflight.sh

# Phase 2 - VMs
bash /root/ubicloud-deploy/01-create-vms.sh

# Phase 3 - SSH setup
bash /root/ubicloud-deploy/02-post-boot-fixup.sh

# Phase 4 - bootstrap ctrl plane (SSH in first)
ssh ubuntu@10.98.1.10 'bash /tmp/03-bootstrap-ctrl.sh'

# Phase 5 - register data plane
ssh ubuntu@10.98.1.10 'bash /tmp/04-register-host.sh'
```

## Logging

Each script writes to its own log file for post-mortem analysis.

| Script | Log path |
|--------|----------|
| `00-preflight.sh` | `/var/log/ubicloud-deploy-00.log` (Proxmox host) |
| `01-create-vms.sh` | `/var/log/ubicloud-deploy-01.log` (Proxmox host) |
| `02-post-boot-fixup.sh` | `/var/log/ubicloud-deploy-02.log` (Proxmox host) |
| `03-bootstrap-ctrl.sh` | `/tmp/ubicloud-deploy-03.log` (ctrl plane) |
| `04-register-host.sh` | `/tmp/ubicloud-deploy-04.log` (ctrl plane) |
| `99-deploy-all.sh` | `/var/log/ubicloud-deploy-99.log` (Proxmox host) |

Tail everything at once:

```bash
# On Proxmox host:
tail -f /var/log/ubicloud-deploy-*.log

# On ctrl plane:
tail -f /tmp/ubicloud-deploy-*.log
```

## Monitoring running system

```bash
# Live dashboard (refreshes every 10s)
ssh ubuntu@10.98.1.10 'bash /tmp/05-monitor.sh'

# One-shot snapshot
ssh ubuntu@10.98.1.10 'bash /tmp/05-monitor.sh once'
```

Shows: ctrl services, Postgres, VM host state, VMs, active strands,
data plane health.

### Manual Postgres queries

```bash
ssh ubuntu@10.98.1.10
cd ~/ubicloud
export PATH=$HOME/.local/share/mise/shims:$PATH
export RACK_ENV=development

# Direct psql
sudo -u postgres psql -d clover_development
# Then: SELECT name, display_state FROM vm;

# Or via Ruby
bundle exec ruby -e '
  require_relative "loader"
  DB[:vm].each { |v| puts v.inspect }
'
```

### Ubicloud service logs

On ctrl plane:

```bash
tail -f /tmp/puma.log           # web UI access
tail -f /tmp/puma.err           # web UI errors
tail -f /tmp/respirate.log      # dispatcher (JSON lines, pipe to jq)
tail -f /tmp/respirate.err      # dispatcher errors

# Attach to live tmux sessions
tmux attach -t puma             # Ctrl+B d to detach
tmux attach -t respirate
```

### Data plane logs

```bash
ssh root@10.98.1.30
tail -f /var/log/ubi-rhizome/*.log       # rhizome agent
systemctl list-units '*-storage.service' # per-VM vhost backends
tail -f /vm/<vm-ubid>/serial.log         # nested VM console
```

## Troubleshooting

**`/dev/kvm` missing in data plane**
- Verify `qm config 401 | grep cpu` shows `cpu: host`
- Verify `cat /sys/module/kvm_intel/parameters/nested` shows `Y` on host
- Reboot Proxmox host if both are correct but still broken

**"MAX 4 vcpus allowed per VM on this node"**
- Proxmox caps VM cores at host thread count
- Lower `DATA_CORES` to match `nproc` on host

**Ctrl plane SSH "No route to host"**
- Cloud-init didn't apply IP config
- Check `qm config 400 | grep ipconfig` — if empty, the cloud-init command was wrapped/broken
- Redo with `qm set 400 --ipconfig0 ip=10.98.1.10/24,gw=10.98.1.1` and `qm reboot 400`

**"No capacity left" creating VMs in UI**
- On <6-core hosts: run `04-register-host.sh` — it auto-sets `accepts_slices=false`
- On higher-tier: check standard-2 needs 8 GB hugepages; if you only have 6-7, use burstable

**Start over**
```bash
bash /root/ubicloud-deploy/reset.sh
bash /root/ubicloud-deploy/99-deploy-all.sh
```

## Companion docs

- [SETUP_PROXMOX.md](../SETUP_PROXMOX.md) — full narrative guide
- [SETUP_PROXMOX_LOWTIER.md](../SETUP_PROXMOX_LOWTIER.md) — low-tier hardware gotchas
