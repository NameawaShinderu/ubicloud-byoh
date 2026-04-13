# Deploying Ubicloud BYOH on Low-Tier Proxmox Hardware

A real-world guide to running Ubicloud's Bring-Your-Own-Hardware
cloud platform on consumer-grade Proxmox hosts — the kind of
hardware most homelabbers actually own.

---

## Who this is for

You have a Proxmox server running on modest hardware — a laptop CPU,
16 GB of RAM, a consumer SSD — and you want to try Ubicloud BYOH.
The [main Proxmox guide](SETUP_PROXMOX.md) assumes beefy hardware
(10+ CPU threads, 32 GB RAM, NVMe). This guide is what happens when
you don't have that.

Everything here was tested on an **Intel i5-5200U (2 cores / 4
threads), 16 GB RAM, PVE 8.4.5, 100 GB SSD + 1 TB external HDD**.
If your hardware is stronger than this, everything here still
applies — you'll just have more room.

## What you'll end up with

Two VMs on your Proxmox host:

- **ubi-byoh-ctrl** — runs the Ubicloud control plane (web UI,
  database, dispatcher). 2 vCPU, 4 GB RAM, 40 GB disk.
- **ubi-byoh-data** — runs the Ubicloud data plane (cloud-hypervisor,
  vhost storage backend, nested VMs). 4 vCPU, 12 GB RAM, 120 GB disk.

Inside the data plane, you'll be able to create **burstable** VMs
(1-2 vCPU, 2-4 GB RAM) through the Ubicloud web UI.

## What you won't get

- **standard-2 VMs** (2 vCPU / 8 GB) — these need 8 GB of 1G
  hugepages. With 12 GB total RAM on the data plane, the OS uses
  ~5 GB, leaving only 6-7 GB for hugepages. Not enough. You need
  20+ GB on the data plane (meaning 24+ GB on the host) for standard
  VMs.
- **Multiple concurrent VMs** — with 2 usable CPU cores and 6-7 GB
  of hugepages, you can run 1-2 burstable VMs at a time.
- **Production performance** — nested virtualization on an
  overcommitted dual-core is a proof of concept, not a production
  setup.

---

## Part 1 — Pre-flight

### Verify your hardware

SSH into your Proxmox host and run:

```bash
pveversion
nproc
free -h
cat /sys/module/kvm_intel/parameters/nested
pvesm status
```

You need:

| Requirement | Minimum | How to check |
|-------------|---------|-------------|
| PVE version | 8.0+ | `pveversion` |
| CPU threads | 4 | `nproc` |
| Free RAM | 12 GB | `free -h` (stop other VMs if needed) |
| Nested virt | `Y` | `cat /sys/module/kvm_intel/parameters/nested` |
| Storage pool | 160 GB free | `pvesm status` |

### If nested virtualization is disabled

Check:
```bash
cat /sys/module/kvm_intel/parameters/nested    # Intel
cat /sys/module/kvm_amd/parameters/nested      # AMD
```

If it says `N`, enable it:

**Intel:**
```bash
echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf
update-initramfs -u -k all
reboot
```

**AMD:**
```bash
echo "options kvm-amd nested=1" > /etc/modprobe.d/kvm-amd.conf
update-initramfs -u -k all
reboot
```

After reboot, verify it says `Y`. This is non-negotiable — without
nested virt, the entire setup fails at the last step with no clear
error message.

### Free up resources

On a 16 GB host, you need to allocate 4 GB (ctrl) + 12 GB (data) =
16 GB to VMs. Proxmox itself needs ~2 GB. The math only works if
you stop non-essential containers and VMs first.

Check what's running:
```bash
qm list
pct list
```

Stop anything you don't need:
```bash
pct stop <id>
qm stop <id>
```

LXC containers are lightweight (they only use actual consumed memory,
not allocated), so you may be able to leave some running. KVM VMs
reserve their full allocation.

---

## Part 2 — Networking decision

Ubicloud's two VMs need to talk to each other on an internal network,
and both need internet access. You have two paths depending on your
existing Proxmox network setup.

### Path A — You already have internal bridges with NAT

If your `/etc/network/interfaces` already has bridges like `vmbr1`,
`vmbr2`, etc. with NAT masquerade rules, **use one of them**. Don't
create a new bridge.

Check your existing bridges:
```bash
ip -brief addr show | grep vmbr
cat /etc/network/interfaces
```

If you see something like:
```
auto vmbr1
iface vmbr1 inet static
    address 10.0.1.1/24
    bridge-ports none
    post-up iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o vmbr0 -j MASQUERADE
```

Then `vmbr1` is ready. Pick free IPs on its subnet for the Ubicloud
VMs. For example, if `vmbr1` is `10.0.1.0/24` and `.1` is the
gateway, `.15` is some other VM:

| Role | IP |
|------|----|
| Ctrl plane (net0) | `10.0.1.10` |
| Data plane (net0) | `10.0.1.30` |
| VM pool slot 0 | `10.0.1.128` |
| VM pool slot 1 | `10.0.1.129` |
| VM pool slot 2 | `10.0.1.130` |

Both VMs also get a **second NIC on vmbr0** (your physical LAN
bridge) with DHCP, so they can reach the internet for apt, image
downloads, etc. And so you can reach the web UI from your browser.

### Path B — You only have vmbr0 (default Proxmox install)

If you only have the default `vmbr0` bridge (physical NIC uplink),
create one internal bridge. In the Proxmox web UI:

1. **Datacenter → your node → System → Network**
2. **Create → Linux Bridge**
3. Settings:
   - Name: `vmbr1`
   - IPv4/CIDR: `10.98.1.1/24`
   - Bridge ports: *(leave blank)*
   - Autostart: checked
4. Click **Create**, then **Apply Configuration**

Then add NAT so VMs on this bridge can reach the internet:

```bash
cat >> /etc/network/interfaces << 'EOF'

# NAT for vmbr1
post-up echo 1 > /proc/sys/net/ipv4/ip_forward
post-up iptables -t nat -A POSTROUTING -s 10.98.1.0/24 -o vmbr0 -j MASQUERADE
post-down iptables -t nat -D POSTROUTING -s 10.98.1.0/24 -o vmbr0 -j MASQUERADE
EOF
ifreload -a
```

Your IP plan becomes:

| Role | IP |
|------|----|
| Bridge gateway (PVE host) | `10.98.1.1` |
| Ctrl plane (net0) | `10.98.1.10` |
| Data plane (net0) | `10.98.1.30` |
| VM pool | `10.98.1.128`, `.129`, `.130` |

The rest of this guide uses `10.0.1.x` (Path A). Substitute
`10.98.1.x` if you went with Path B.

---

## Part 3 — Download the Ubuntu cloud image

You need the Ubuntu 24.04 **cloud image** (not the desktop ISO). The
cloud image is ~660 MB, pre-installed, and configures itself via
cloud-init at first boot — no manual installer.

```bash
cd /var/lib/vz/template/iso
wget -nc https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

If you already have Ubuntu ISOs in your template folder, they're not
the same thing. The cloud image filename ends in `.img` and is ~660
MB.

---

## Part 4 — Create the VM template

This template gets cloned twice (ctrl + data). All commands run on
the Proxmox host as root.

**Important**: On many terminals, long `qm set` commands wrap across
lines and break. Run each setting group as a separate command.

```bash
# Create the base VM
qm create 9000 --name ubi-byoh-template --memory 2048 --cores 2 \
  --sockets 1 --net0 virtio,bridge=vmbr1 --serial0 socket \
  --vga serial0 --agent enabled=1 --ostype l26

# Import the cloud image as its disk
qm importdisk 9000 \
  /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img local-lvm

# Wire up the disk
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --ide2 local-lvm:cloudinit

# Lock it as a template
qm template 9000
```

Replace `vmbr1` with your internal bridge name. Replace `local-lvm`
with your storage pool name if different (check `pvesm status`).

---

## Part 5 — Create the control plane VM

```bash
qm clone 9000 400 --name ubi-byoh-ctrl --full
qm set 400 --cores 2 --memory 4096
qm set 400 --net0 virtio,bridge=vmbr1
qm set 400 --net1 virtio,bridge=vmbr0
qm set 400 --ipconfig0 ip=10.0.1.10/24,gw=10.0.1.1
qm set 400 --ipconfig1 ip=dhcp
qm set 400 --sshkeys /root/.ssh/id_rsa.pub
qm set 400 --ciuser ubuntu --cipassword ubuntu
qm set 400 --nameserver 1.1.1.1 --searchdomain local
qm resize 400 scsi0 +38G
qm start 400
```

Replace IPs with your plan from Part 2. The `--sshkeys` flag points
to your Proxmox host's public key — this gets injected into the VM
so you can SSH in without a password.

Wait 60 seconds for cloud-init, then verify:
```bash
ssh -o StrictHostKeyChecking=no ubuntu@10.0.1.10 "hostname"
```

### If the ctrl plane is unreachable

Common causes:
- **`systemd-networkd-wait-online` timeout**: cloud-init waits for
  both NICs. If DHCP on net1 is slow, boot stalls for ~2 minutes.
  Wait it out, or remove net1 (`qm set 400 --delete net1`) and use
  only the internal bridge (it has NAT for internet).
- **Wrong ipconfig**: verify with `qm config 400 | grep ipconfig`.
  If empty, the `--ipconfig0` command didn't apply (line wrapping).
  Re-run it and reboot: `qm reboot 400`.

---

## Part 6 — Create the data plane VM

This is the VM that runs nested VMs. The `--cpu host` flag is
**mandatory** — it passes through VT-x so cloud-hypervisor can work.

```bash
qm clone 9000 401 --name ubi-byoh-data --full
qm set 401 --cores 4 --memory 12288 --cpu host
qm set 401 --net0 virtio,bridge=vmbr1
qm set 401 --net1 virtio,bridge=vmbr0
qm set 401 --ipconfig0 ip=10.0.1.30/24,gw=10.0.1.1
qm set 401 --ipconfig1 ip=dhcp
qm set 401 --sshkeys /root/.ssh/id_rsa.pub
qm set 401 --ciuser ubuntu --cipassword ubuntu
qm set 401 --nameserver 1.1.1.1 --searchdomain local
qm resize 401 scsi0 +118G
qm start 401
```

**On low-tier hardware**: Proxmox may reject `--cores 8` with
"MAX 4 vcpus allowed per VM on this node". This happens when your
CPU only has 4 threads. Use `--cores 4` — it works, but means only
2 cores are available for nested VMs (the other 2 are reserved by
the vhost storage backend).

### Verify nested virt works

SSH into the data plane and run three checks:

```bash
ssh -o StrictHostKeyChecking=no ubuntu@10.0.1.30

# Inside the data plane:
ls -l /dev/kvm                          # must exist
grep -c -E 'vmx|svm' /proc/cpuinfo     # must be > 0
sudo modprobe kvm_intel && lsmod | grep kvm  # must load
```

**All three must pass.** If `/dev/kvm` doesn't exist:
1. Check `--cpu host` is set: `qm config 401 | grep cpu`
2. Check nested virt on host: `cat /sys/module/kvm_intel/parameters/nested`
3. If both are correct, reboot the Proxmox host

### Fix root SSH

The ctrl plane needs to SSH to the data plane as `root` during
registration. Ubuntu cloud images block root login by default. Fix
it:

```bash
# From the Proxmox host:
ssh ubuntu@10.0.1.30 "sudo sed -i 's/.*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
ssh ubuntu@10.0.1.30 "sudo systemctl restart ssh"
ssh ubuntu@10.0.1.30 "sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys"
ssh ubuntu@10.0.1.30 "sudo chmod 600 /root/.ssh/authorized_keys"
```

---

## Part 7 — Bootstrap the control plane

SSH into the ctrl plane:

```bash
ssh ubuntu@10.0.1.10
```

**Clone the repo first** — the bootstrap script expects it at
`~/ubicloud`:

```bash
git clone --branch byoh-driver \
  https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
```

Then run the bootstrap:

```bash
curl -sSL https://raw.githubusercontent.com/NameawaShinderu/ubicloud-byoh/byoh-driver/scripts/byoh/bootstrap-ctrl-plane.sh | bash
```

This installs Ruby 4.0, Node 24, Postgres 16, runs migrations, and
starts the web UI + dispatcher. **Expect 15-20 minutes on a 2-core
VM** (Ruby compile is the slow part).

When it finishes you'll see:

```
━━━━━ DONE ━━━━━
Ubicloud control plane is ready.
```

Verify:
```bash
curl -sI http://localhost:3000/ | head -1
# HTTP/1.1 302 Found
```

---

## Part 8 — Set up ctrl→data SSH and register the host

Still on the ctrl plane:

```bash
# Generate a key for ctrl→data communication
ssh-keygen -t ed25519 -f ~/.ssh/byoh_data -N '' -C 'ubi-byoh ctrl-to-data'

# Install it on the data plane as root
PUBKEY="$(cat ~/.ssh/byoh_data.pub)"
ssh ubuntu@10.0.1.30 "echo '$PUBKEY' | sudo tee -a /root/.ssh/authorized_keys > /dev/null"

# Verify
ssh -i ~/.ssh/byoh_data -o StrictHostKeyChecking=no root@10.0.1.30 'hostname && ls /dev/kvm'
# Should print: ubi-byoh-data \n /dev/kvm
```

Register the BYOH host:

```bash
cd ~/ubicloud
export PATH=$HOME/.local/share/mise/shims:$PATH
export RACK_ENV=development

bundle exec ruby bin/register-byoh-host \
  --main-ip 10.0.1.30 \
  --routed-network 10.0.1.128/32 \
  --routed-network 10.0.1.129/32 \
  --routed-network 10.0.1.130/32 \
  --ssh-key ~/.ssh/byoh_data \
  --location proxmox-homelab \
  --default-boot-image ubuntu-noble \
  --yes
```

The dispatcher (respirate) will automatically bootstrap the data
plane. This takes 6-10 minutes. Monitor progress:

```bash
tail -f /tmp/respirate.log | grep -E 'hopped|exited|error'
```

You'll see it progress through: `bootstrap_rhizome` → `prep_host` →
`install_vhost_backend` → `download_boot_images` → `wait` (done).

### Critical post-registration fix: disable slice allocation

With only 2 usable CPU cores, the slice allocator can't work. Without
this fix, every VM creation will fail with "No capacity left":

```bash
cd ~/ubicloud
export PATH=$HOME/.local/share/mise/shims:$PATH
export RACK_ENV=development

bundle exec ruby -e '
  require_relative "loader"
  DB[:vm_host].update(accepts_slices: false)
  puts "accepts_slices disabled"
'
```

---

## Part 9 — Create your first VM

### Find the web UI

The ctrl plane's LAN IP (on vmbr0) is assigned by DHCP. Find it:

```bash
# On the ctrl plane:
ip -4 addr show eth1 | grep inet
```

Open `http://<that-ip>:3000/` in your browser.

### Location mapping gotcha

The `--location proxmox-homelab` flag doesn't create a visible
location named "proxmox-homelab" in the UI. Your host gets mapped
to an existing location — typically **Germany** (`eu-central-h1`) or
whichever is the first in the database. When creating a VM, select
**Germany** from the location dropdown.

To verify which location your host is under:
```bash
bundle exec ruby -e '
  require_relative "loader"
  h = DB[:vm_host].first
  l = DB[:location].where(id: h[:location_id]).first
  puts "Host is at: #{l[:display_name]} (#{l[:name]})"
'
```

### Create the VM

1. Log in (there's usually a pre-created `admin@admin.com` account)
2. Create a project if prompted
3. Upload your laptop's SSH public key (sidebar → SSH keys)
4. Sidebar → Virtual machines → Create
5. Settings:
   - **Location**: Germany (or whatever your host mapped to)
   - **Family**: **Shared CPU** (burstable) — not Standard
   - **Size**: burstable-2 (2 vCPU / 4 GB)
   - **Boot image**: ubuntu-noble
   - **SSH key**: select yours

**Do not select standard-2.** It needs 8 GB of hugepages and will
sit in "waiting for capacity" forever on a 12 GB data plane.

### VM size reference for low-tier hardware

| Size | vCPU | RAM | Hugepages needed | Works on 12 GB data plane? |
|------|------|-----|-----------------|---------------------------|
| burstable-1 | 1 | 2 GB | 2 | Yes |
| burstable-2 | 2 | 4 GB | 4 | Yes |
| standard-2 | 2 | 8 GB | 8 | **No** (only 6-7 available) |
| standard-4 | 4 | 16 GB | 16 | No |

---

## Part 10 — Accessing your VM

Ubicloud VMs get IPs from the routed-network pool you registered
(e.g. `10.0.1.128`). These are on the data plane's internal network,
not directly reachable from your laptop.

### Option 1 — SSH via the ctrl plane as jump host

```bash
ssh -J ubuntu@<ctrl-LAN-ip> ubi@10.0.1.128
```

The VM username is **`ubi`** (not `ubuntu`, not `root`).

### Option 2 — Add a static route on your laptop

```bash
# Linux:
sudo ip route add 10.0.1.128/29 via <ctrl-LAN-ip>

# macOS:
sudo route -nv add -net 10.0.1.128/29 <ctrl-LAN-ip>

# Windows (admin cmd):
route add 10.0.1.128 mask 255.255.255.248 <ctrl-LAN-ip>
```

Then SSH directly: `ssh ubi@10.0.1.128`

### Option 3 — Tailscale

If you already run Tailscale on your Proxmox host, install it on the
data plane and advertise the subnet:

```bash
# On the data plane:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-routes=10.0.1.0/24 --accept-dns=false
```

Approve the route in the Tailscale admin panel. Now any device on
your tailnet can reach `10.0.1.128` directly.

---

## Troubleshooting

### "No capacity left" but host shows available resources

**Cause**: `accepts_slices` is `true` (default) but no slices exist.
With only 2 non-reserved CPU cores, the slice allocator fails silently.

**Fix**:
```bash
bundle exec ruby -e 'require_relative "loader"; DB[:vm_host].update(accepts_slices: false)'
```

### standard-2 VM stuck in "creating" forever

**Cause**: Not enough hugepages. Check on data plane:
```bash
cat /proc/meminfo | grep HugePages_Total
```
If it shows 6-7, standard-2 (needs 8) can't fit. Use burstable-2.

### `MAX 4 vcpus allowed per VM on this node`

**Cause**: Proxmox caps VM cores at host logical CPU count.

**Fix**: Use `--cores 4` (or whatever `nproc` reports on the host).

### Host key warnings after recreating VMs

VMs get new host keys each time they're recreated from the template.
Clear stale keys:
```bash
ssh-keygen -f ~/.ssh/known_hosts -R 10.0.1.10
ssh-keygen -f ~/.ssh/known_hosts -R 10.0.1.30
```
Do this on every machine that previously connected (Proxmox host,
any LXC containers, your laptop).

### `systemd-networkd-wait-online` hangs during ctrl plane boot

Cloud-init waits for both NICs to come up. If DHCP on the LAN NIC
(net1) is slow, boot stalls for 2+ minutes. Solutions:
- Wait it out (it will eventually timeout and continue)
- Remove the second NIC: `qm set 400 --delete net1` — the internal
  bridge has NAT so internet still works through it

### Cloud-init settings didn't apply

If `qm config <id>` shows missing `ipconfig0` or `ciuser`, the
settings weren't applied. This happens when long `qm set` commands
wrap across terminal lines. Re-run each setting group individually
(see Part 5).

### VM shows "running" but no cloud-hypervisor process

Check with the right command (process name is >15 chars):
```bash
pgrep -fa cloud-hyp     # correct
pgrep -a cloud-hypervisor  # wrong — truncated, always returns empty
```

### Bootstrap script fails at step 5 (ubicloud repo not found)

The bootstrap expects `~/ubicloud` to exist. Clone it first:
```bash
git clone --branch byoh-driver \
  https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
```
Then re-run the bootstrap — it's idempotent and will skip completed
steps.

### SPDK service not found / inactive

This branch of Ubicloud uses **vhost-block-backend** instead of
SPDK. There is no `ubi-spdk.service`. Each VM gets a per-VM
storage service:
```bash
systemctl status <vm-ubid>-0-storage.service
```
If that shows `active (running)`, storage is working correctly.

---

## What would be different with better hardware

For reference, here's how the deployment simplifies with proper
server hardware (e.g. Ryzen 5600X, 64 GB RAM, NVMe):

| Aspect | i5-5200U / 16 GB | Ryzen 5600X / 64 GB |
|--------|------------------|---------------------|
| Data plane cores | 4 (2 usable) | 12 (10 usable) |
| Data plane RAM | 12 GB (6-7 hugepages) | 48 GB (40+ hugepages) |
| `accepts_slices` | Must be `false` | Works as `true` (default) |
| VM sizes available | burstable only | standard-2 through standard-8 |
| Concurrent VMs | 1-2 burstable | 5-10 standard |
| `--cores 8` on data plane | Rejected by Proxmox | Works fine |
| Bootstrap time | 15-20 min | 5-8 min |
| Hugepage issues | Constant | None |

The setup steps are identical — you just skip the workarounds in
this guide and follow [SETUP_PROXMOX.md](SETUP_PROXMOX.md) as
written.
