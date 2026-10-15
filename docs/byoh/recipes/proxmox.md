# Recipe: a Proxmox VE guest as a BYOH host

> **UNVERIFIED.** Nothing here has run on Proxmox. The commands come from
> the code and from the Proxmox `qm` documentation. The M4 gate
> G-M4-2 ([VERIFY.md](../VERIFY.md) §6) is this recipe run once with
> `scripts/byoh/verify/m4-e2.sh`. Record what you find there.

This recipe replaces `docs/byoh/deploy-scripts/` (deleted in M4). It makes
one data-plane **VM** on a Proxmox node and a `pools.yaml`, then runs the
three commands of [README.md](README.md). The detailed runbook, with
every variant and troubleshooting row, is
[SETUP_PROXMOX.md](../SETUP_PROXMOX.md); the short guide is
[platforms/proxmox.md](../platforms/proxmox.md).

```
            internet
               |
        [router/pfSense]  10.77.0.1
               |
   ------------ vmbr1  10.77.0.0/24 ------------------------
      |                        |                    |
 data-plane VM 9100       control plane         admins / VPN
 10.77.0.20 (one NIC)     on the LAN, or routed in
 pool 10.77.0.200/29 answered with proxy_arp
```

`10.77.0.0/24` is this recipe's own example network. It differs from
terraform's `10.98.0.0/16` and the company LAN of NETWORKING §9.2
(`10.80.0.0/24`), so one control plane can manage all of them. Use your
own.

## Rules

- **Point `--ssh` at the guest VM, never at the Proxmox node.** Bring-up
  reboots the host, replaces its nftables ruleset and recreates the
  `rhizome` user. Host preflight refuses a Proxmox node (`PF16-pve`, which
  cannot be accepted).
- **Dedicated, non-shared virtual disks only.** A guest cannot tell that
  its disk sits on a SAN LUN or a Ceph image something else also writes,
  so `storage-disk`'s shared-transport check cannot protect you here.
  Never attach a passed-through host disk, a LUN, or another guest's
  volume. The VM's own disks may live on any Proxmox storage.
- **No MASQUERADE over the pool** on the node or anywhere else. The
  router's normal outbound NAT for the LAN covers the pool, and a `nat`
  pool uses 1:1 NAT entries only. A blanket masquerade hides which VM
  sent a packet and breaks inbound replies.
- **No `PermitRootLogin yes` and no cloud-init password.** `host add`
  logs in with your key and installs its own root key; it allows root
  *key* login only if sshd does not already.

## 1. Node checks (read-only)

As root on the node ([SETUP_PROXMOX.md](../SETUP_PROXMOX.md) §2):

```bash
pveversion
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || cat /sys/module/kvm_amd/parameters/nested   # Y or 1
grep -m1 'model name' /proc/cpuinfo
```

Nested virtualization off: the node's owner sets `options kvm-intel
nested=Y` (or `kvm-amd nested=1`) and reboots the node; that affects every
guest. On a hybrid P+E-core node, give the guest only cores of one kind
or expect preflight `PF8-hybrid` in the guest (whether a guest sees the
core types is UNVERIFIED); [homelab.md](homelab.md) §2 explains the
choice.

## 2. The VM

Run on the node. `9100` is a free VMID, `local-lvm` your storage, `vmbr1`
the LAN bridge. Memory is a multiple of 1024 MiB (whole GiB), so
LearnMemory and the hugepage count need no rounding.

```bash
VMID=9100; STORAGE=local-lvm; BRIDGE=vmbr1
cd /var/lib/vz/template/iso
wget -nc https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create $VMID --name ubi-byoh-data --ostype l26 \
  --cpu host --cores 8 --sockets 1 --memory 32768 --balloon 0 \
  --net0 virtio,bridge=$BRIDGE,firewall=0 \
  --scsihw virtio-scsi-single --serial0 socket --vga serial0 --agent enabled=1
qm set $VMID --scsi0 $STORAGE:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
  --boot order=scsi0 --ide2 $STORAGE:cloudinit
qm resize $VMID scsi0 200G
qm set $VMID --ipconfig0 ip=10.77.0.20/24,gw=10.77.0.1 --nameserver 10.77.0.1 \
  --ciuser ubuntu --sshkeys ~/your_admin_key.pub
qm start $VMID
```

- `--cpu host` passes `vmx`/`svm` and `pdpe1gb`; `kvm64` or the PVE default
  model fails PF3 ("kvm64-class CPU model"), which cannot be accepted.
- One NIC, `firewall=0`: the Proxmox NIC firewall's IP and MAC filters can
  drop proxy-ARP replies and packets from pool addresses (UNVERIFIED which
  defaults do). A second NIC gives asymmetric egress.
- `--ciuser ubuntu --sshkeys` gives `ubuntu` your key and passwordless
  sudo (cloud image default). That login is what `host add --ssh` uses.
- Never put pool addresses in `ipconfig0` or netplan (contract C5).

**Optional extra data disk.** The 200 GB root disk already holds VM disks
under `/var/storage`. For more space, add a second, dedicated virtual
disk **before `host add`** and give it a serial, so it gets a stable
`/dev/disk/by-id` name:

```bash
qm set $VMID --virtio1 $STORAGE:500,serial=ubidata1
```

`host add --storage-disk virtio-ubidata1` then formats it as ext4 and
mounts it at `/var/storage/devices/disk1` (the by-id name
`virtio-ubidata1` follows udev's rule for virtio-blk serials;
UNVERIFIED on Proxmox: take the exact name from host preflight's PF11
line). The disk must be blank; the script never wipes. Adding a disk to a
host after its bring-up is not supported yet (M5), and nothing may ever
be mounted over `/var/storage` itself.

## 3. Router: pools reach the VM

Pick one ([SETUP_PROXMOX.md](../SETUP_PROXMOX.md) §6 has the details).

**A. LAN pool, internal addresses** (no public IPs). Shrink the router's
DHCP range so `10.77.0.200-10.77.0.207` is outside it. Nothing else: the
VM answers ARP for the pool with proxy_arp, and the router's outbound NAT
already covers the LAN.

```yaml
version: 2
uplink: ens18                  # enp6s18 on q35; informational
routed_networks:
  - cidr: 10.77.0.200/29
    delivery: onlink
    exposure: internal
    segment: 10.77.0.0/24
    gateway: 10.77.0.1
```

**B. pfSense 1:1 NAT** (extra public IPs). Add the `onlink` + `nat` pool
of SETUP_PROXMOX §6.3, with one public IP per pool address under
`external:`, a 1:1 entry and a WAN pass rule per pair on pfSense, and NAT
reflection off.

**C. Static route** (an RFC 1918 block routed to the VM). On the router,
route `10.77.10.0/28` to `10.77.0.20`, the VM, never to the node. Then:

```yaml
version: 2
uplink: ens18
routed_networks:
  - cidr: 10.77.10.0/28
    delivery: routed
    exposure: internal
```

The block reaches the site LAN through the router; for internet ingress,
use public addresses with `exposure: public` instead.

## 4. The three commands

On the control plane, which must reach `10.77.0.20:22`: on the LAN, or
routed into it (a site VPN). Copy `pools.yaml` and the private half of
`your_admin_key` there.

```bash
sudo ubicloud-admin site add pve-lab --display "Proxmox lab (BYOH)" \
  --underlay 10.77.0.0/24 --overlay 172.20.0.0/14 --cp-reach onhost \
  --cp-source <control plane IP>/32 --mgmt-allow 10.77.0.0/24 \
  --rates-from hetzner-fsn1

sudo ubicloud-admin host preflight --site pve-lab --ssh ubuntu@10.77.0.20 \
  --ssh-key ~/your_admin_key --pool-file pools.yaml        # optional dry run

sudo ubicloud-admin host add --site pve-lab --ssh ubuntu@10.77.0.20 \
  --ssh-key ~/your_admin_key --pool-file pools.yaml \
  [--storage-disk virtio-ubidata1]
```

- Off the LAN, with only the VM's address routed to it, use
  `--cp-reach public` ([SETUP_PROXMOX.md](../SETUP_PROXMOX.md) §4.1).
- `host add` shows the guest's host key fingerprints. Compare them with
  the console (`qm terminal 9100`, then `ssh-keygen -lf
  /etc/ssh/ssh_host_ed25519_key.pub`) before you type `yes`, or pass
  them with `--expect-host-key`.
- The guest reboots once. `host add` exits 0 when it accepts VMs and
  `pool verify` passes. On variant A, `pool verify` warns that no internet
  VM with IPv4 can be placed: expected, as the pool is internal.
- Development control plane: `packaging/bin/ubicloud-admin --dev` from
  `~/ubicloud`, without `sudo`, and restart `puma` and `respirate` after
  `site add`.

Then create your account, `sudo ubicloud-admin site grant pve-lab
--project pj...`, and create VMs with IPv4 exposure **internal** (variant
A or C) or **internet** (variant B). [SETUP_PROXMOX.md](../SETUP_PROXMOX.md)
§8-§9 has the VM and gate steps.

## What the old scripts did wrong

The deleted `deploy-scripts/` and `SETUP_PROXMOX_LOWTIER.md` set
`accepts_slices=false` on every host of the control plane (OPS-1), could
not log in from the control plane to the data plane (OPS-11), split a /29
into three /32s, enabled `PermitRootLogin yes` and a cloud-init password,
masqueraded the pool, dual-homed the VM, `curl | bash`ed the branch head,
and destroyed VMIDs by number. This recipe does none of that.
