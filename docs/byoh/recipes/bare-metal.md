# Recipe: a bare-metal server as a BYOH host

> **UNVERIFIED.** No bare-metal host has been registered with `host add`
> in this project. Provider facts are in
> [platforms/bare-metal-dedicated.md](../platforms/bare-metal-dedicated.md)
> (rented servers) and [platforms/own-hardware.md](../platforms/own-hardware.md)
> (your own, or a colo), labelled as provider docs.

A rented dedicated server (Hetzner Robot, OVH, Leaseweb, ...) or your own
server in a rack becomes a BYOH host. This recipe gives the machine and a
`pools.yaml`, then the three commands of [README.md](README.md).

## 1. Firmware

On your own hardware, before installing (own-hardware.md §2.2):

| Setting | Value |
|---|---|
| Intel VT-x / AMD SVM | **Enabled**. Without it, preflight fails PF3 ("no /dev/kvm"), which cannot be accepted |
| VT-d / AMD-Vi (IOMMU) | Only for GPU passthrough; then bind the GPU's whole IOMMU group to `vfio-pci` before `host add` (own-hardware.md §2.1) |
| Hyper-Threading / SMT | Enabled |
| E-cores (hybrid parts) | Disabled if the board allows; otherwise see [homelab.md](homelab.md) §2 |
| Restore on AC power loss | Power On or Last State |

Rented servers have this on already (provider docs, UNVERIFIED here);
host preflight tells you if not.

## 2. Install Ubuntu 24.04 and lay out storage

Use the provider's installer (Hetzner `installimage`, OVH templates) or
the Ubuntu ISO. Decide the storage **before** `host add`: bring-up learns
the disks once, during prep, and adding a disk afterwards is not
supported yet (M5).

- **Root filesystem and `/var/storage`.** VM disks and boot images live
  in `/var/storage`. On a single disk or software RAID 1, ext4 or xfs at
  `/` is enough; preflight warns that `/var/storage` shares the root
  filesystem (PF10), which is fine when it is large. Not ZFS (refused),
  not btrfs (fails `PF10-btrfs` unless accepted; UNVERIFIED for VMs).
- **Extra data disks.** Leave them blank (no partitions, no filesystem)
  and pass each to `host add --storage-disk <by-id name>`. That formats
  the disk as ext4 and mounts it at `/var/storage/devices/diskN`, where
  prep counts it. It never wipes: a disk with any partition, signature,
  holder, swap or mount is refused, and so are the disks of `/`, `/boot`
  and `/boot/efi`. Host preflight's PF11 line lists blank disks by their
  `/dev/disk/by-id` names. An iSCSI, FC, NVMe-over-fabrics or multipath
  disk is refused unless `--allow-shared-transport`, because another
  machine may write to it.
- **Hardware RAID** volumes appear as one disk; use them like any disk.
  SMART on them is usually unavailable, which is fine since M4 (F5).
- Never mount anything over `/var/storage` itself.

## 3. Login and network

- A user with passwordless sudo and your SSH key (`host add --ssh` logs
  in as it). Many installers give you only root: create the user, or use
  `--ssh root@<IP>` (sudo as root is a no-op; UNVERIFIED with `host add`).
- The main IP is the server's own address, the only address on the
  uplink, with exactly one IPv4 default route.
- Outbound HTTPS and HTTP (PF15).

## 4. Pools: a routed block

Order an additional block routed to the server's main IP (Hetzner
"additional subnet", OVH "Additional IP" block without virtual MACs,
Leaseweb routed subnet; provider docs, UNVERIFIED here). Do **not**
configure its addresses on the server; the block just arrives.

```yaml
version: 2
uplink: enp41s0              # your NIC (ip -br link); informational
routed_networks:
  - cidr: 5.9.10.0/29        # the routed block
    delivery: routed
    exposure: public
  # - cidr: 2a01:4f8:1:2::/64   # optional: a routed IPv6 /64; without one, VMs get ULA IPv6
```

All 8 addresses are usable: each VM address is a /32 route. The main IP
must not be inside any pool, and neither may the gateway (PF17, which
cannot be accepted). An address tied to its own virtual MAC never works:
rhizome routes every VM behind the host's MAC. With no extra block, VMs
run IPv6-only with IPv4 egress through the host NAT
(bare-metal-dedicated.md §3.7).

## 5. The three commands

The control plane must reach the server's main IP on port 22. When it
sits elsewhere on the internet, use `--cp-reach public`: VMs are then
dialled at their public addresses.

```bash
sudo ubicloud-admin site add fsn-dc1 --display "Falkenstein (BYOH)" \
  --underlay <server main IP>/32 --overlay 172.20.0.0/14 --cp-reach public \
  --cp-source <control plane public IP>/32 --mgmt-allow <your admin IP>/32 \
  --rates-from hetzner-fsn1

sudo ubicloud-admin host add --site fsn-dc1 --ssh admin@<server main IP> \
  --ssh-key ~/.ssh/id_ed25519 --pool-file pools.yaml \
  [--storage-disk nvme-SAMSUNG_MZQL2..._S6...] \
  [--bmc-endpoint https://<bmc> --bmc-user U --bmc-pass-env BMC_PASS]
```

- **BMC (Redfish only).** Put the password in the respirate environment
  first (`sudo ubicloud-admin env set BMC_PASS`), then pass
  `--bmc-pass-env BMC_PASS`. `--bmc-password` is refused: it would store
  the password in plain text. Without a BMC, never use the admin
  "Hardware Reset" (CLAUDE.md §10 #5).
- Compare the host key fingerprints `host add` shows with the server's
  console or rescue system before typing `yes`, or pass them with
  `--expect-host-key`.
- The server reboots once; bare metal takes 15-25 minutes to accept VMs.
  `host add` exits 0 then, after `pool verify` passes.
