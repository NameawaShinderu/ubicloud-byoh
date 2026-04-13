# Ubicloud BYOH — Proxmox VE Setup (homelab edition)

**Audience**: you have a Proxmox VE host running on your own hardware,
a web browser, and an SSH client for your Proxmox host. You don't
need AWS, Terraform, Kubernetes, a cloud account, or money. You
already own the hardware.

**Time**: ~60-90 minutes end to end. The long tail is the ctrl plane
bootstrap (~10 min of Ruby compile + package install) and the
nested-KVM cold start for your first VM.

**Cost**: $0. Your electric bill.

**End state**: you have a fully functional Ubicloud control plane
running in a VM on your Proxmox host, a fully functional Ubicloud
data plane running in *another* VM on the same host (or a different
one), and you can log into the web UI, create a VM through the UI,
and SSH into that VM from your laptop. Everything on hardware you
own, nothing rented.

This guide is a sibling of
[`SETUP.md`](SETUP.md) (the AWS Console path). Use this one if you
have physical hardware; use `SETUP.md` if you want to spin it up on
AWS. Both take you to the same end state.

---

## Table of contents

- [Part 1 — Background](#part-1--background)
    1. [What Ubicloud is, in one page](#1-what-ubicloud-is-in-one-page)
    2. [What "BYOH" means](#2-what-byoh-means)
    3. [What you're building on Proxmox](#3-what-youre-building-on-proxmox)
    4. [Why Proxmox is a better fit than AWS](#4-why-proxmox-is-a-better-fit-than-aws)
- [Part 2 — Pre-flight: inspect your current Proxmox host](#part-2--pre-flight-inspect-your-current-proxmox-host)
    5. [Step 0.1 — Confirm Proxmox version](#step-01--confirm-proxmox-version)
    6. [Step 0.2 — Check CPU virtualization extensions](#step-02--check-cpu-virtualization-extensions)
    7. [Step 0.3 — Check nested virtualization status](#step-03--check-nested-virtualization-status)
    8. [Step 0.4 — Audit free resources (RAM, disk, CPU)](#step-04--audit-free-resources-ram-disk-cpu)
    9. [Step 0.5 — List your storage pools](#step-05--list-your-storage-pools)
    10. [Step 0.6 — Map your current network layout](#step-06--map-your-current-network-layout)
    11. [Step 0.7 — Check internet reachability](#step-07--check-internet-reachability)
    12. [Step 0.8 — List existing VMs and next free VMID](#step-08--list-existing-vms-and-next-free-vmid)
    13. [Step 0.9 — (Optional) List NVMe devices for future passthrough](#step-09--optional-list-nvme-devices-for-future-passthrough)
- [Part 3 — Plan before you click](#part-3--plan-before-you-click)
    14. [The one big decision: how will VMs be reachable?](#the-one-big-decision-how-will-vms-be-reachable)
    15. [IP address plan](#ip-address-plan)
    16. [VM spec plan](#vm-spec-plan)
- [Part 4 — Build it](#part-4--build-it)
    17. [Step 1 — Enable nested virtualization on the Proxmox host](#step-1--enable-nested-virtualization-on-the-proxmox-host)
    18. [Step 2 — Create a bridge for BYOH traffic](#step-2--create-a-bridge-for-byoh-traffic)
    19. [Step 3 — Download the Ubuntu 24.04 cloud image](#step-3--download-the-ubuntu-2404-cloud-image)
    20. [Step 4 — Create a reusable VM template](#step-4--create-a-reusable-vm-template)
    21. [Step 5 — Create the control plane VM](#step-5--create-the-control-plane-vm)
    22. [Step 6 — Create the data plane VM](#step-6--create-the-data-plane-vm)
    23. [Step 7 — First-boot verification (the nested-virt smoke test)](#step-7--first-boot-verification-the-nested-virt-smoke-test)
    24. [Step 8 — Bootstrap the control plane](#step-8--bootstrap-the-control-plane)
    25. [Step 9 — Generate the ctrl→data SSH key](#step-9--generate-the-ctrldata-ssh-key)
    26. [Step 10 — Install the key on the data plane](#step-10--install-the-key-on-the-data-plane)
    27. [Step 11 — Register the BYOH host](#step-11--register-the-byoh-host)
    28. [Step 12 — Watch the host bootstrap strand](#step-12--watch-the-host-bootstrap-strand)
    29. [Step 13 — Open the web UI and create your first VM](#step-13--open-the-web-ui-and-create-your-first-vm)
    30. [Step 14 — SSH into your VM](#step-14--ssh-into-your-vm)
- [Part 5 — Networking deep dive](#part-5--networking-deep-dive)
    31. [Option A — Private lab, LAN-only](#option-a--private-lab-lan-only)
    32. [Option B — Router DNAT port forwarding](#option-b--router-dnat-port-forwarding)
    33. [Option C — Routed subnet from ISP](#option-c--routed-subnet-from-isp)
    34. [Option D — Tailscale / WireGuard overlay](#option-d--tailscale--wireguard-overlay)
- [Part 6 — Operations](#part-6--operations)
    35. [Troubleshooting](#troubleshooting)
    36. [FAQ](#faq)
    37. [Performance tuning — PCI passthrough for NVMe](#performance-tuning--pci-passthrough-for-nvme)
    38. [Cleanup — tear it all down](#cleanup--tear-it-all-down)
- [Appendix A — Command reference for the impatient](#appendix-a--command-reference-for-the-impatient)
- [Appendix B — What's in the rhizome agent, and why it matters](#appendix-b--whats-in-the-rhizome-agent-and-why-it-matters)

---

# Part 1 — Background

## 1. What Ubicloud is, in one page

Ubicloud is an open-source "cloud platform you run yourself." Think:
the parts of AWS (EC2, VPC, block storage, private networks) you
most commonly use, re-implemented as software that runs on your
own bare-metal servers. You download it, point it at one or more
Linux machines you control, and it turns them into a cloud: you get
a web UI, a REST API, and the ability to create VMs, attach them to
private networks, give them public IPs, and SSH into them — without
any cloud provider in the middle.

**How it's built**, at a high level:

- **Control plane** (written in Ruby) runs the database, the web UI,
  and the state-machine dispatcher called `respirate`. Users talk
  to it. It does not run VMs itself.
- **Data plane** is any Linux host running Ubicloud's on-host agent
  (`rhizome`). The control plane SSHes into it and drives everything
  via shell commands. The data plane runs the actual VMs using
  `cloud-hypervisor` (Rust VMM) + `SPDK` (userspace storage) + per-VM
  network namespaces + nftables for firewalling.
- **Overlay networking** uses IPsec + VXLAN to tunnel private
  networks between data plane hosts, so VMs on different physical
  machines can talk to each other as if they were on the same
  L2 segment.

**Why it exists**: as a reaction to cloud vendor lock-in and the
cost of running large workloads on Hetzner or Equinix bare metal
vs. hyperscaler VMs. A k8s cluster of 50 machines on Hetzner costs
1/10th of the same cluster on AWS, but there's no EC2-equivalent
API in front of that Hetzner hardware — Ubicloud fills that gap.

## 2. What "BYOH" means

Up until recently, Ubicloud's host provisioning code assumed you
bought machines from **Hetzner** via their API. `lib/hosting/hetzner_apis.rb`
handles: calling Hetzner's REST to pull your machine list, doing
reimage + hardware-reset via the Hetzner panel, pulling the routed
IP blocks Hetzner assigned to each box. If you wanted to run on
anything other than Hetzner (OVH, Equinix, your own hardware), the
code refused to provision.

**BYOH ("Bring Your Own Hardware") generic provider** is a new driver
that removes this assumption. Instead of talking to a provider API,
it takes all the information it would have fetched (SSH endpoint,
routed IP range, BMC address) as static configuration supplied by
you at registration time, and calls zero provider APIs. This means
Ubicloud can run on **any** Linux box you can SSH into, as long as:

- It's Ubuntu 24.04 LTS (the rhizome agent expects apt + systemd +
  Ubuntu-specific paths).
- It has a CPU with hardware virtualization extensions (VT-x or SVM)
  visible to the OS.
- It has enough disk for the image cache + VM disks.
- You can reach it from the control plane over SSH.

It does **not** need to be physical hardware — a VM with nested virt
enabled is fine. Which brings us to the Proxmox path.

## 3. What you're building on Proxmox

Your Proxmox host becomes the **rack**. Inside it you'll run two
VMs:

```
  +-------------------- Proxmox host (your hardware) -------------------+
  |                                                                     |
  |   physical NIC  --- vmbr0 (existing LAN uplink) --- 192.168.1.1    |
  |                                                                     |
  |   vmbr1 (new, BYOH-internal bridge) --- 10.98.1.1/24                |
  |     |                                                               |
  |     +-- ubi-byoh-ctrl  VM  (2 vCPU / 4 GB / 40 GB)                  |
  |     |     * Ubicloud web UI (Puma on :3000)                         |
  |     |     * Postgres 16                                             |
  |     |     * respirate dispatcher                                    |
  |     |     * NICs: 10.98.1.10 (vmbr1) + DHCP on vmbr0                |
  |     |                                                               |
  |     +-- ubi-byoh-data  VM  (8 vCPU / 24 GB / 120 GB)                |
  |           * cpu=host + nested KVM enabled                           |
  |           * rhizome agent (installed by ctrl plane via SSH)         |
  |           * SPDK + cloud-hypervisor                                 |
  |           * NICs: 10.98.1.20 (vmbr1) + DHCP on vmbr0                |
  |           * inside it: your Ubicloud VMs                            |
  |                                                                     |
  +---------------------------------------------------------------------+
```

The control plane VM is a normal Ubuntu VM — no special flags, no
nested virt. It runs only user-space software.

The data plane VM is the interesting one. It's also a Ubuntu VM, but
configured with `cpu: host` (passes through all CPU features) and
nested-virt enabled on the Proxmox host (passes through VT-x). This
means that **inside** the data plane VM, `/dev/kvm` exists and works,
and cloud-hypervisor can run more VMs on top of it. Those are your
Ubicloud workloads.

You can, if you want, run the control plane on one Proxmox host and
the data plane on a completely different Proxmox host. The BYOH
driver doesn't care. This guide puts them on the same Proxmox host
to keep things simple, and because "one host, two VMs" is the most
common homelab.

## 4. Why Proxmox is a better fit than AWS

If you read the AWS version of this guide ([SETUP.md](SETUP.md)),
you may have noticed that AWS requires a **bare-metal instance type**
like `m5d.metal` (~$5.42/hr) for the data plane. That's because
AWS's Nitro hypervisor does not expose CPU virtualization extensions
to normal EC2 instances — you can't run nested KVM on a regular
t3/m5/c5 instance, so the only way to get `/dev/kvm` is to rent
the physical machine.

Proxmox has no such restriction. Proxmox **is** a hypervisor running
directly on real hardware, and it happily exposes VT-x/SVM to its
guests when you flip a single modprobe flag. The result:

| Property                | AWS (SETUP.md)              | Proxmox (this doc)                |
|-------------------------|-----------------------------|-----------------------------------|
| Data plane hardware     | m5d.metal (~$3,900/mo)      | a VM on your homelab box (~$0/mo) |
| Spin-up time            | ~8 min (AWS races to rack)  | ~60 seconds (`qm clone && start`) |
| Teardown time           | 10-20 min                   | 2 seconds                         |
| Snapshots               | No (bare metal)             | Yes                               |
| Can iterate quickly     | Expensive                   | Trivially                         |
| Public IP provisioning  | Elastic IP mapping gotcha   | Your choice (LAN / router / ISP / Tailscale) |
| Storage                 | EBS-backed (nested)         | Real local disks, optional NVMe passthrough |

The only thing AWS has going for it is "I already have an AWS account
and I don't want to buy hardware." For anyone who already has a
Proxmox box, this path is better in every dimension.

---

# Part 2 — Pre-flight: inspect your current Proxmox host

Before you change anything, spend 5 minutes understanding what your
Proxmox host currently looks like. The answers to these questions
determine which networking option you pick and whether you'll need to
reboot the host to enable nested virt.

**How to run these commands**: SSH into the Proxmox host as `root`
(or use **Datacenter → your node → Shell** in the web UI, which opens
a root shell directly in the browser). All commands in Part 2 are
read-only — they inspect state, they don't change it.

## Step 0.1 — Confirm Proxmox version

```bash
pveversion
```

Expected output (something like):

```
pve-manager/8.2.4/eeaa0e7a7c0bc0b8 (running kernel: 6.8.8-4-pve)
```

**What you want**: Proxmox VE **8.0 or newer**. This guide was
written against PVE 8.x. It'll work on 7.x with minor UI differences,
but if you're on PVE 7 and have the option, upgrade first —
8.x ships the 6.x kernel which has much better KVM nested virt
support and a newer cloud-init.

**If you get "command not found"**: you're not on a Proxmox host.
This guide doesn't apply to plain Debian + libvirt or to TrueNAS or
to ESXi.

## Step 0.2 — Check CPU virtualization extensions

```bash
lscpu | grep Virtualization
# OR equivalently:
grep -E 'vmx|svm' /proc/cpuinfo | head -1
```

Expected output:

```
Virtualization:                  VT-x            # Intel
# or
Virtualization:                  AMD-V           # AMD
```

**What you want**: any of the following:
- `VT-x` (Intel)
- `AMD-V` / `SVM` (AMD)

**If the line is empty** or says "Not supported": your CPU either
doesn't have hardware virt support or it's disabled in BIOS. Reboot,
enter BIOS/UEFI setup, look for "Intel VT-x / Virtualization
Technology" or "AMD SVM / AMD-V" and enable it. This is the single
most common failure mode for first-time Proxmox users: the CPU
supports it, but the BIOS ships with it disabled. You'll see it in
settings like "CPU Configuration" or "Advanced CPU Settings".

Also verify the kernel module is loaded:

```bash
lsmod | grep kvm
```

Expected:

```
kvm_intel             495616  0
kvm                  1355776  1 kvm_intel
# or kvm_amd on AMD
```

If empty, `modprobe kvm_intel` (or `kvm_amd`) manually and check
`dmesg` for errors.

## Step 0.3 — Check nested virtualization status

This is the **single most important check** in the whole doc. If
nested virt isn't on, the data plane VM won't be able to run
cloud-hypervisor, and everything downstream will fail at the final
step.

```bash
# Intel
cat /sys/module/kvm_intel/parameters/nested

# AMD
cat /sys/module/kvm_amd/parameters/nested
```

**What you want**: `Y` or `1`.

**If you see `N` or `0`**: nested virt is disabled. You'll enable it
in Step 1 of Part 4. Don't worry about it now — just note it.

**What nested virt means in practice**: it tells the KVM kernel module
inside Proxmox to advertise VT-x/SVM to the VMs it runs. Without
this flag, VMs see a CPU without virtualization extensions and their
own kernel will refuse to load `kvm_intel`/`kvm_amd`. This is the
setting that makes the whole "VMs inside VMs" thing possible.

## Step 0.4 — Audit free resources (RAM, disk, CPU)

```bash
echo '--- memory ---'
free -h
echo
echo '--- disk (root + local storage) ---'
df -h /var/lib/vz /var/lib/pve 2>/dev/null
echo
echo '--- logical CPUs ---'
nproc
echo
echo '--- running VMs memory usage ---'
qm list 2>/dev/null
```

Example output:

```
--- memory ---
               total        used        free      shared  buff/cache   available
Mem:            62Gi        18Gi        38Gi       120Mi       6.4Gi        44Gi
Swap:          8.0Gi          0B       8.0Gi

--- disk ---
Filesystem      Size  Used Avail Use% Mounted on
/dev/mapper/pve-root   94G   12G   78G  14% /

--- logical CPUs ---
16

--- running VMs ---
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 pihole               running    1024       8.00         2531
       200 homeassistant        running    4096       32.00        2612
```

**What you need for this guide**:

| Resource            | Minimum | Recommended | Why                                 |
|---------------------|---------|-------------|-------------------------------------|
| Free RAM            | 12 GB   | **32 GB**   | 4 GB ctrl + 24 GB data + headroom   |
| Free disk           | 160 GB  | **250 GB**  | 40 GB ctrl + 120 GB data + template + snapshots |
| Free logical CPUs   | 4       | **10**      | 2 ctrl + 8 data                     |

**If you're tight on RAM**: the data plane VM is the big eater.
Shrink it to 16 GB if you must (guide assumes 24), but don't go
below 12 GB — SPDK wants hugepages and you'll run into "not enough
free memory for hugepages" failures.

**If you're tight on disk**: Ubicloud will download Ubuntu boot
images onto the data plane (~800 MB each) plus allocate disk space
for each VM you create. At 120 GB the data plane has room for the
image + 1-2 VMs of 20-40 GB each. Bump the data plane disk to 200
GB if you plan to have many concurrent VMs.

## Step 0.5 — List your storage pools

```bash
pvesm status
```

Example:

```
Name             Type     Status           Total            Used       Available        %
local             dir     active        98304000        12582912        80789504    12.80%
local-lvm     lvmthin     active       800000000       100000000       700000000    12.50%
```

**What you want**: at least one storage pool of type `dir`, `lvm`,
`lvmthin`, `zfspool`, or `zfs`. Almost all Proxmox installs have
`local` (directory on /var/lib/vz) and one of `local-lvm` or
`local-zfs`. Either works for this guide.

**Pick one to use for the Ubicloud VMs**. The guide uses `local-lvm`
in its examples but you can substitute anything. Note the name —
you'll reference it in Step 4 and Step 5.

**Storage type tradeoffs for the data plane specifically**:
- `local-lvm` (LVM-Thin) — default on most installs, supports
  snapshots and thin provisioning. Good choice.
- `local-zfs` — excellent for snapshots, compression, and integrity,
  but ZFS has memory pressure implications (ARC) that compete with
  VM memory. Use if you already run ZFS.
- `local` (directory, qcow2 on ext4) — most flexible, supports
  all disk formats. Slightly slower than LVM-Thin under heavy load.
  Fine for testing.

**Avoid for the data plane**: NFS, CIFS, Ceph. The data plane does
lots of small random I/O (SPDK metadata, nested VM file systems),
and network-backed storage will choke the whole stack. Keep it
local.

## Step 0.6 — Map your current network layout

Two layers to check.

**Layer 1 — what bridges does Proxmox already have:**

```bash
ip -brief addr show
echo '---'
cat /etc/network/interfaces
```

Expected (trimmed):

```
lo               UNKNOWN        127.0.0.1/8 ::1/128
eno1             UP             
vmbr0            UP             192.168.1.50/24
```

**What you want**: a bridge (usually `vmbr0`) with a LAN IP
(192.168.x.x, 10.x.x.x, 172.16-31.x.x). This is your Proxmox host's
uplink to your network.

**What you need to remember**:
- The `vmbr0` IP — it's your Proxmox host's LAN address. Write it
  down.
- The subnet mask — e.g. `/24` means 192.168.1.0/24. This is the
  range your router assigns LAN IPs from.
- You need a free IP range **not overlapping** with this for the
  BYOH bridge. If your LAN is `192.168.1.0/24`, using `10.98.1.0/24`
  for the BYOH bridge is perfect (they can't conflict).

**Layer 2 — what does your default route look like:**

```bash
ip route
```

Expected:

```
default via 192.168.1.1 dev vmbr0 proto kernel onlink
192.168.1.0/24 dev vmbr0 proto kernel scope link src 192.168.1.50
```

**What you want**: a `default via X.X.X.X` line pointing to your
router. That's the gateway your Proxmox host uses to reach the
internet. Note the router's IP — you may need it if you choose
networking Option B or C later.

**Layer 3 — is there a firewall (Proxmox side) in the way:**

```bash
cat /etc/pve/firewall/cluster.fw 2>/dev/null
pve-firewall status
```

**What you want**: either the cluster firewall is `disabled`, or if
it's enabled, you know it won't block `vmbr1` traffic. For the
default homelab setup, Proxmox's datacenter firewall is off — if
it's on, you'll need to add allow rules for `vmbr1` in Part 4.

## Step 0.7 — Check internet reachability

From the Proxmox host:

```bash
ping -c 2 8.8.8.8
curl -sI https://cloud-images.ubuntu.com | head -1
```

Expected:

```
PING 8.8.8.8: 56 data bytes
64 bytes from 8.8.8.8: icmp_seq=1 ttl=115 time=12.3 ms
--- 8.8.8.8 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss

HTTP/2 200 
```

**What you want**: both succeed. The first proves outbound IP
connectivity. The second proves DNS + HTTPS + that you can reach
Ubuntu's cloud image mirror (which you'll download from in Step 3).

**If ping fails**: your Proxmox host has no internet. Fix that first
— check your router, the `vmbr0` config, and DNS (`cat /etc/resolv.conf`).
Nothing else in this guide will work without internet on the
Proxmox host.

**If curl fails but ping works**: DNS issue. Add `nameserver 1.1.1.1`
to `/etc/resolv.conf` (or configure it properly via the Proxmox web UI
**Datacenter → DNS**).

## Step 0.8 — List existing VMs and next free VMID

```bash
qm list
```

Example:

```
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB)
       100 pihole               running    1024       8.00
       101 unifi                running    2048       16.00
       200 homeassistant        running    4096       32.00
```

**Pick 3 free VMIDs** for the template, ctrl plane, and data plane.
The guide uses:

- **9000** — template (high VMID keeps templates grouped)
- **101** — ctrl plane (or the next free ID in your usual range)
- **102** — data plane

Substitute whatever fits your naming scheme. Every `qm` command below
uses these as variables at the top — change them once and the rest
follows.

## Step 0.9 — (Optional) List NVMe devices for future passthrough

If you care about VM disk performance and have a spare NVMe drive
you're willing to dedicate to the Ubicloud data plane, find its PCI
address now:

```bash
lspci -nn | grep -i -E 'nvme|non-volatile'
```

Example:

```
01:00.0 Non-Volatile memory controller [0108]: Samsung Electronics Co Ltd NVMe SSD Controller 980 [144d:a809]
02:00.0 Non-Volatile memory controller [0108]: KIOXIA Corporation NVMe SSD [1e0f:0001]
```

The `01:00.0` and `02:00.0` are the PCI BDFs (bus/device/function).
If you have a spare one (not the one Proxmox boots from!), make a
note — you'll use it in the Performance Tuning section.

**First time through, skip this.** Get Ubicloud running with plain
virtual disks first, prove everything works, then come back and add
NVMe passthrough as a follow-up optimization. Passthrough is fiddly
and not worth debugging on day one.

---

# Part 3 — Plan before you click

Spend 2 minutes making three decisions in advance. It'll save you
an hour of "wait, I have to redo this because I picked the wrong…".

## The one big decision: how will VMs be reachable?

Ubicloud VMs need IPs from a "routed network" — a CIDR block you
hand to `register-byoh-host` as the pool to draw VM IPs from. How
those IPs become reachable depends entirely on where they're routed
to.

Four options, pick one based on what you want:

**Option A — Private lab, LAN-only (recommended for first run)**
- VMs get IPs from an isolated subnet like `10.98.1.128/29` (range:
  `.128` through `.135`, 8 IPs, 6 usable for VMs).
- Reachable only from the ctrl plane VM or from machines you explicitly
  add a route for.
- No router config. No ISP involvement. No public exposure.
- **Best for**: your first run, learning, testing.
- **Not good for**: running public web servers or anything internet-facing.

**Option B — Router DNAT (port forwarding)**
- VMs get IPs from Option A's private range.
- Your home router is configured to port-forward specific ports to
  specific VM IPs (e.g. "TCP 2201 → 10.98.1.128:22").
- Reachable from the internet on those forwarded ports only.
- **Best for**: exposing 1-2 specific services behind your existing
  public IP.
- **Not good for**: many VMs, or when you want each VM to have its
  own clean "public IP".

**Option C — Routed subnet from ISP**
- You have a static routed IPv4 range from your ISP (common with
  business-class internet, rare on consumer). e.g. `203.0.113.0/29`
  routed to your WAN IP.
- Your router routes that /29 to your Proxmox host; Proxmox routes
  it to the data plane; the data plane forwards to VMs.
- Each VM gets a real public IP. The web UI shows the real IP. No
  NAT confusion.
- **Best for**: "production-like" setup, matching how Hetzner/OVH/
  Equinix bare-metal works.
- **Not good for**: consumer internet users (most people).

**Option D — Tailscale / WireGuard overlay**
- VMs get IPs from Option A's private range + Tailscale installed
  inside each VM (or on the data plane as a subnet router).
- Reachable from any machine on your Tailscale network.
- No ISP involvement, no router config, works from anywhere, encrypted.
- **Best for**: accessing your VMs from outside your home LAN,
  easily, without opening anything.
- **Not good for**: running public-facing services (VMs aren't
  on the public internet).

**Which should you pick now**: if you're doing this for the first
time, **pick Option A**. You can always switch later. Don't get
distracted by the "which is best" question — Option A works
immediately and everything else is an optimization.

The rest of this guide assumes Option A. [Part 5](#part-5--networking-deep-dive)
has full walkthroughs for B/C/D including the exact commands.

## IP address plan

Based on Option A, reserve these addresses:

| Role                       | IP              | Notes                              |
|----------------------------|-----------------|------------------------------------|
| BYOH bridge gateway (on PVE)| `10.98.1.1/24` | Proxmox host's IP on `vmbr1`       |
| ctrl plane — `vmbr1`       | `10.98.1.10`    | internal-facing                    |
| ctrl plane — `vmbr0`       | `dhcp`          | LAN-facing (for web UI access)     |
| data plane — `vmbr1`       | `10.98.1.20`    | internal-facing (main_ip)          |
| data plane — `vmbr0`       | `dhcp`          | LAN-facing (for internet)          |
| VM pool slot 0             | `10.98.1.128`   | first BYOH VM's IP                 |
| VM pool slot 1             | `10.98.1.129`   | second BYOH VM's IP                |
| VM pool slot 2             | `10.98.1.130`   | third BYOH VM's IP                 |

You can pick different values for anything — just stay consistent.
**Write them down somewhere before you start.** The ctrl plane VM's
`vmbr1` IP is what you'll give `register-byoh-host` as the main_ip,
and the VM pool IPs are what you'll give as `--routed-network` flags.

## VM spec plan

| VM                 | vCPU | RAM   | Disk   | CPU type | Nested virt | Notes                 |
|--------------------|------|-------|--------|----------|-------------|-----------------------|
| `ubi-byoh-template`| 2    | 2 GB  | 2 GB   | default  | no          | not booted; template only |
| `ubi-byoh-ctrl`    | 2    | 4 GB  | 40 GB  | default  | no          | user-space only        |
| `ubi-byoh-data`    | **8**| **24 GB** | **120 GB** | **host** | **yes**     | runs nested VMs       |

**Scale down if you must**: data plane can go to `4 vCPU / 16 GB /
80 GB` and still work for a 1-VM test. Don't go below that — SPDK
will refuse to start on <4 cores, and Ubuntu image cache + 1 nested
VM needs ~60 GB minimum.

**Scale up if you can**: data plane at `16 vCPU / 64 GB / 500 GB`
gives you headroom for many VMs. Ubicloud will happily use all of
it.

---

# Part 4 — Build it

Everything from here on actually changes state on the Proxmox host.
The commands assume you're root on the Proxmox host (use the web UI's
**Shell** or SSH in). Variables at the top of each block — change
them once if you picked different VMIDs / storage / bridge names.

```bash
# Set these once and they apply everywhere
VMID_TMPL=9000
VMID_CTRL=101
VMID_DATA=102
STORAGE=local-lvm       # from Step 0.5
BRIDGE_UPLINK=vmbr0     # your existing LAN bridge
BRIDGE_BYOH=vmbr1       # the new internal bridge
```

Copy that into your shell, then proceed step by step.

## Step 1 — Enable nested virtualization on the Proxmox host

Check current state (from Step 0.3):

```bash
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || \
cat /sys/module/kvm_amd/parameters/nested
```

**If it already printed `Y` or `1`**: skip to Step 2, you're done.

**If it printed `N` or `0`**: enable it.

On Intel:

```bash
echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf
update-initramfs -u -k all
```

On AMD:

```bash
echo "options kvm-amd nested=1" > /etc/modprobe.d/kvm-amd.conf
update-initramfs -u -k all
```

Then either reboot the host:

```bash
reboot
```

Or unload-and-reload the module **if no VMs are currently running**:

```bash
# DANGER: fails if any VM is running. Stop all VMs first or just reboot.
modprobe -r kvm_intel     # or kvm_amd
modprobe kvm_intel
```

Verify after reboot/reload:

```bash
cat /sys/module/kvm_intel/parameters/nested     # should print Y
```

**What this does**: the modprobe option tells the KVM kernel module
to tell its guest VMs "yes, you have hardware virtualization". This
is the single most important change on the Proxmox host — without
it, nothing downstream works.

**If you get `Operation not permitted`** on `modprobe -r`: there are
running VMs. Either stop them all (`qm list` → `qm stop <id>` for
each) or reboot the host at a convenient time. The `options` line
takes effect on next module load, whichever method you use.

## Step 2 — Create a bridge for BYOH traffic

Two ways: web UI or command line. Use whichever you're comfortable
with.

**Via web UI:**

1. **Datacenter → your node → System → Network**
2. **Create → Linux Bridge**
3. Fill in:
    - Name: `vmbr1`
    - IPv4/CIDR: `10.98.1.1/24`
    - Gateway: *(leave blank)*
    - Bridge ports: *(leave blank — no physical uplink)*
    - Autostart: ✓
    - Comment: `Ubicloud BYOH internal bridge`
4. Click **Create**
5. **Critical**: click **Apply Configuration** at the top of the
   Network page. Without this, the bridge sits in staging and
   isn't active. You'll get confusing "network not found" errors
   in Step 5 if you skip this.

**Via CLI (equivalent):**

```bash
cat >> /etc/network/interfaces <<'EOF'

auto vmbr1
iface vmbr1 inet static
    address 10.98.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Ubicloud BYOH internal bridge
EOF

ifreload -a
# Or alternatively:
# systemctl restart networking
```

Verify:

```bash
ip -brief addr show vmbr1
# should print:
# vmbr1            UP             10.98.1.1/24
```

**Why no physical uplink**: this bridge exists purely for ctrl↔data
communication and for VMs to forward their traffic through the data
plane. No packets need to leave the Proxmox host on this bridge. The
data plane VM will have a **second** NIC on `vmbr0` (your existing
uplink) for internet access. This is the Proxmox analogue of the
AWS VPC's "private + public subnet" split.

**Why 10.98.1.1/24**: arbitrary — you just need something that
doesn't overlap with your LAN subnet (from Step 0.6). If your LAN is
already 10.98.x.x for some reason, substitute 10.77.0.0/24 or
172.30.0.0/24 or whatever is free in RFC1918.

## Step 3 — Download the Ubuntu 24.04 cloud image

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
ls -lh noble-server-cloudimg-amd64.img
```

Expected: a ~660 MB qcow2 file.

**What this is**: the official Ubuntu 24.04 LTS "cloud image" — a
pre-built disk with Ubuntu installed, cloud-init enabled, and no
root password. It's designed to be cloned and configured via
cloud-init at boot. It's the exact same image AWS uses internally
for its Ubuntu AMIs.

**Why not the ISO?** Because the ISO installer is interactive —
you'd have to click through a GUI or answer questions over a serial
console. The cloud image is "already installed, ready to boot",
which is what you want when you're spawning VMs from scripts.

## Step 4 — Create a reusable VM template

You'll clone this template twice (once for ctrl, once for data). It
takes 30 seconds.

```bash
qm create $VMID_TMPL \
    --name ubi-byoh-template \
    --memory 2048 --cores 2 --sockets 1 \
    --net0 virtio,bridge=$BRIDGE_BYOH \
    --serial0 socket --vga serial0 \
    --agent enabled=1 \
    --ostype l26

# Import the cloud image as this template's disk
qm importdisk $VMID_TMPL \
    /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
    $STORAGE

# Wire up the imported disk as scsi0 + the cloud-init config drive as ide2
qm set $VMID_TMPL --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID_TMPL-disk-0
qm set $VMID_TMPL --boot c --bootdisk scsi0
qm set $VMID_TMPL --ide2 $STORAGE:cloudinit

# Lock it as a template (read-only, can be cloned)
qm template $VMID_TMPL
```

Verify:

```bash
qm list | grep 9000
# should print something like:
#       9000 ubi-byoh-template    stopped    2048              2.20 0
```

**What each flag does**:
- `--name` — human-readable name.
- `--memory 2048 --cores 2` — defaults, overridden per-VM when cloning.
- `--net0 virtio,bridge=vmbr1` — one NIC on the BYOH bridge.
- `--serial0 socket --vga serial0` — so the Proxmox web console
  works. The Ubuntu cloud image expects a serial console by default.
- `--agent enabled=1` — so Proxmox's VM status shows IPs correctly
  (requires `qemu-guest-agent` to be installed in the VM, which the
  cloud image does automatically).
- `--ostype l26` — Linux 2.6+ kernel, tells Proxmox to apply
  Linux-specific optimizations.
- `qm importdisk` — converts the qcow2 cloud image into a disk image
  on your storage pool.
- `--scsihw virtio-scsi-pci --scsi0 ...` — attaches the imported
  disk as a virtio-scsi device (best performance + hot-plug support).
- `--ide2 ...:cloudinit` — Proxmox creates a small CD-ROM device
  with a cloud-init ISO. Contents are filled in per-VM at clone
  time.
- `qm template` — marks it read-only. Now any `qm clone` will
  linked-clone from it (cheap, instant).

## Step 5 — Create the control plane VM

```bash
# Paste your laptop's public SSH key path here — you'll SSH into
# the ctrl plane from your laptop to drive the bootstrap.
LAPTOP_PUBKEY="$HOME/.ssh/id_ed25519.pub"
# or generate one if you don't have one yet:
# ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# Clone the template
qm clone $VMID_TMPL $VMID_CTRL --name ubi-byoh-ctrl --full

# Configure specs + networking + cloud-init
qm set $VMID_CTRL \
    --cores 2 \
    --memory 4096 \
    --net0 virtio,bridge=$BRIDGE_BYOH \
    --net1 virtio,bridge=$BRIDGE_UPLINK \
    --ipconfig0 ip=10.98.1.10/24,gw=10.98.1.1 \
    --ipconfig1 ip=dhcp \
    --sshkeys "$LAPTOP_PUBKEY" \
    --ciuser ubuntu \
    --cipassword '' \
    --nameserver 1.1.1.1 \
    --searchdomain local

# Grow the disk from the template default (~2 GB) to 40 GB
qm resize $VMID_CTRL scsi0 +38G

# Start it
qm start $VMID_CTRL
```

Wait ~45 seconds for first boot (cloud-init runs once, applies the
SSH key and network config, reboots).

**What each flag does**:

- `qm clone ... --full` — makes a full (independent) copy of the
  template. Use `--full` rather than linked clone because the data
  plane will do a lot of writes and linked clones have COW overhead
  that compounds.
- `--cores 2 --memory 4096` — overrides the template defaults.
- `--net0 virtio,bridge=vmbr1` — primary NIC on the internal BYOH
  bridge, static IP (see `--ipconfig0`).
- `--net1 virtio,bridge=vmbr0` — second NIC on your LAN bridge,
  DHCP. Gives the ctrl plane LAN access (for apt, gem, npm) and lets
  you browse to the web UI from your laptop at its LAN IP.
- `--ipconfig0 ip=10.98.1.10/24,gw=10.98.1.1` — static config for
  the internal NIC. Note: **gateway is set to the Proxmox host's
  vmbr1 IP**, not because packets will route through it (they don't
  for internal traffic), but because cloud-init requires a gateway
  when you specify a static IP. Harmless if unused.
- `--ipconfig1 ip=dhcp` — DHCP for the LAN NIC.
- `--sshkeys` — cloud-init injects this into
  `/home/ubuntu/.ssh/authorized_keys`. This is how you SSH in on
  first boot without a password.
- `--ciuser ubuntu --cipassword ''` — default user is `ubuntu`,
  empty password. The empty password is fine because SSH password
  login is disabled — you'll only be able to log in with your key.
- `--nameserver 1.1.1.1 --searchdomain local` — DNS. Substitute
  your router's DNS if you prefer.
- `qm resize scsi0 +38G` — grows the disk. Inside the VM, cloud-init
  + cloud-initramfs-growroot will automatically grow the partition
  and filesystem on first boot. You don't have to do anything manual.

Get the ctrl plane's LAN IP (so you know where to SSH):

```bash
# Wait for cloud-init + qemu-guest-agent to settle, ~45s
sleep 45
qm guest cmd $VMID_CTRL network-get-interfaces 2>/dev/null | \
    grep -A1 'ip-address' | head -20
```

Or look at it in the Proxmox web UI: **ubi-byoh-ctrl → Summary** —
the second NIC will show the IP DHCP handed out, something like
`192.168.1.153`.

**SSH in from your laptop to verify**:

```bash
ssh ubuntu@192.168.1.153      # substitute your actual IP
# No password prompt. You should drop into a shell.
```

If the SSH hangs, check **Proxmox web UI → ubi-byoh-ctrl → Console**
and look for cloud-init errors. Most common issue: your SSH public
key wasn't exported properly. You can also use the Console directly
as an alternative — log in as `ubuntu` (no password needed — cloud
image disables that), `sudo -i`, and run the bootstrap from there.

## Step 6 — Create the data plane VM

This is the one with nested virt. Note the `--cpu host` flag — it's
mandatory.

```bash
qm clone $VMID_TMPL $VMID_DATA --name ubi-byoh-data --full

qm set $VMID_DATA \
    --cores 8 \
    --memory 24576 \
    --cpu host \
    --net0 virtio,bridge=$BRIDGE_BYOH \
    --net1 virtio,bridge=$BRIDGE_UPLINK \
    --ipconfig0 ip=10.98.1.20/24,gw=10.98.1.1 \
    --ipconfig1 ip=dhcp \
    --sshkeys "$LAPTOP_PUBKEY" \
    --ciuser ubuntu \
    --cipassword '' \
    --nameserver 1.1.1.1 \
    --searchdomain local

# Grow the disk from ~2 GB to 120 GB
qm resize $VMID_DATA scsi0 +118G

# Start it
qm start $VMID_DATA
```

**Why `--cpu host`**: this tells Proxmox to pass through **all** CPU
features to the guest, including VT-x/SVM. The default CPU type is
`kvm64`, a generic feature set that *explicitly masks* VT-x. Without
`--cpu host`, even with the modprobe flag from Step 1, the data plane
guest will not see `/dev/kvm`, and Ubicloud will fail at the final
step.

Some Proxmox docs will suggest also passing `-cpu host,+vmx` via the
`--args` field as a belt-and-suspenders measure:

```bash
qm set $VMID_DATA --args '-cpu host,+vmx'   # Intel
# or
qm set $VMID_DATA --args '-cpu host,+svm'   # AMD
```

This is usually redundant on modern Proxmox (`--cpu host` already
includes the flags), but add it if you want to be safe — it's a
no-op in the case where it's already enabled.

**Memory / core sizing**:
- 8 cores — minimum to run SPDK (which reserves some) + 1-2 VMs
  comfortably
- 24 GB — enough for the hugepages SPDK allocates + cache + 1-3 VMs
- 120 GB disk — Ubuntu image cache + room for VM disks

Wait ~45 seconds for first boot, then SSH in from your laptop to
verify (same as for ctrl, but using the data plane's DHCP IP from
`vmbr0`).

## Step 7 — First-boot verification (the nested-virt smoke test)

**Before you run the bootstrap**, make absolutely sure nested virt
is working inside the data plane. This takes 30 seconds and saves
an hour of debugging later.

SSH into the data plane (from your laptop, using its LAN-side DHCP
IP):

```bash
ssh ubuntu@<data-plane-lan-ip>
```

Run these three checks **inside the data plane VM**:

```bash
# 1. /dev/kvm must exist
ls -l /dev/kvm

# Expected:
# crw-rw---- 1 root kvm 10, 232 Apr 13 12:34 /dev/kvm
#
# If this says "No such file or directory" → nested virt is NOT
# working. Common causes: forgot --cpu host, forgot to enable
# nested on the Proxmox host, forgot to reboot host after enabling.
# Fix and re-test before continuing.


# 2. CPU virtualization flags must be visible
grep -c -E 'vmx|svm' /proc/cpuinfo

# Expected: same number as your --cores value (e.g. 8)
# If 0 → guest does not see the virt flags. Same fixes as above.


# 3. KVM module can load
sudo modprobe kvm_intel     # or kvm_amd on AMD
lsmod | grep kvm

# Expected: kvm_intel and kvm modules loaded.
# If modprobe fails with "Operation not supported" → same issue.
```

**All three checks must pass.** Do not proceed to Step 8 unless all
three succeed. If any fail:

1. Stop the data plane VM: `qm stop $VMID_DATA`
2. Verify on the Proxmox host: `cat /sys/module/kvm_intel/parameters/nested`
   should be `Y`
3. Verify the data plane VM config: `qm config $VMID_DATA | grep cpu`
   should show `cpu: host`
4. If both are right and it still doesn't work, the issue is most
   likely the Proxmox host never reloaded the kvm-intel module after
   you set `nested=Y`. Reboot the Proxmox host (`reboot`) and try
   again.
5. Start the data plane VM and re-test.

This smoke test is the single highest-leverage sanity check in the
whole guide. If nested virt is broken, **everything downstream fails
at the last possible step**, and the error messages (from inside the
Ubicloud strand) won't point you here. Catch it now.

## Step 8 — Bootstrap the control plane

SSH into the ctrl plane (from your laptop):

```bash
ssh ubuntu@<ctrl-plane-lan-ip>
```

Run the same bootstrap script as the AWS guide — the script is
platform-agnostic:

```bash
curl -sSL https://raw.githubusercontent.com/NameawaShinderu/ubicloud-byoh/byoh-driver/scripts/byoh/bootstrap-ctrl-plane.sh | bash
```

This installs Ruby 4.0.2 + Node 24 + Postgres 16 + all dependencies,
clones the Ubicloud repo, runs migrations, and starts Puma
(on port 3000) + respirate (dispatcher) in tmux sessions. The same
11 steps, with a marker file per step under `~/.ubi-bootstrap/` so
it's idempotent.

**Expected runtime**: ~10-15 minutes. Ruby compile dominates (step 3
of the script, ~3 min by itself). If the Proxmox host is on a slow
disk or you under-sized the ctrl plane RAM, add a few minutes.

**What "done" looks like** — the final lines:

```
━━━━━ 11. Start services in tmux ━━━━━
  started: puma (ctrl-plane-puma session)
  started: respirate (ctrl-plane-respirate session)

✓ Control plane bootstrap complete.

Next: run bin/register-byoh-host
```

Verify:

```bash
tmux ls
# Expected: ctrl-plane-puma and ctrl-plane-respirate sessions

curl -sI http://localhost:3000/ | head -1
# Expected: HTTP/1.1 302 Found
```

If either fails: `tmux attach -t ctrl-plane-puma` to see live Puma
logs, or `tmux attach -t ctrl-plane-respirate` for respirate logs.
Detach from tmux with `Ctrl+B` then `d`.

## Step 9 — Generate the ctrl→data SSH key

Still on the ctrl plane:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/byoh_data -N '' -C 'ubi-byoh ctrl-to-data'
cat ~/.ssh/byoh_data.pub
```

Output looks like:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIXXXXXXXXXXXXXXXXXXXXXXXXXXXXX ubi-byoh ctrl-to-data
```

**Copy that line** — you're going to paste it into the data plane's
`/root/.ssh/authorized_keys` in the next step.

## Step 10 — Install the key on the data plane

Two ways. Use whichever is more convenient.

**Way A — from the ctrl plane SSH session**, if you already SSHed
from laptop → ctrl plane with `-A` (agent forwarding) and have a key
that's already in the data plane's `ubuntu` user (i.e. your laptop
key that was injected via cloud-init):

```bash
# On ctrl plane:
PUBKEY="$(cat ~/.ssh/byoh_data.pub)"
ssh ubuntu@10.98.1.20 "sudo mkdir -p /root/.ssh && echo '$PUBKEY' | sudo tee -a /root/.ssh/authorized_keys > /dev/null && sudo chmod 600 /root/.ssh/authorized_keys"
```

**Way B — open a second SSH session from your laptop to the data
plane** directly (bypass ctrl plane):

```bash
# On your laptop, new terminal:
ssh ubuntu@<data-plane-lan-ip>

# Then inside the data plane VM:
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh
echo 'PASTE-THE-PUBLIC-KEY-LINE-HERE' | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
sudo cat /root/.ssh/authorized_keys   # verify
```

**Way C — use the Proxmox web UI Console** for the data plane
directly, paste the key there:

1. **Proxmox web UI → ubi-byoh-data → Console**
2. Log in as `ubuntu` (no password)
3. Run the same 4 commands as Way B

Pick whichever fits your workflow. **Way A is fastest** if you're
comfortable with ssh agent forwarding / nested SSH; Way B is clearest
for newcomers.

**Test the SSH from ctrl to data** — back on the ctrl plane:

```bash
ssh -i ~/.ssh/byoh_data -o StrictHostKeyChecking=no root@10.98.1.20 'hostname && uname -r && ls /dev/kvm'
```

Expected output:

```
ubi-byoh-data
6.8.0-38-generic
/dev/kvm
```

If this works, you're golden — the ctrl plane can now log into the
data plane as root and `/dev/kvm` is visible. Proceed.

If you get "Permission denied": the key wasn't installed correctly.
Go back and check `sudo cat /root/.ssh/authorized_keys` on the data
plane.

If `ls /dev/kvm` fails: go back to Step 7 — nested virt is broken
and Step 8+ will all fail. Do not proceed.

## Step 11 — Register the BYOH host

Still on the ctrl plane:

```bash
cd ~/ubicloud
export RACK_ENV=development

./bin/register-byoh-host \
    --provider generic \
    --main-ip 10.98.1.20 \
    --routed-network 10.98.1.128/32 \
    --routed-network 10.98.1.129/32 \
    --routed-network 10.98.1.130/32 \
    --ssh-key ~/.ssh/byoh_data \
    --location proxmox-homelab \
    --default-boot-image ubuntu-noble \
    --yes
```

Expected output (abbreviated):

```
Registering BYOH host...
  provider      = generic
  main_ip       = 10.98.1.20
  location      = proxmox-homelab
  routed nets   = [10.98.1.128/32, 10.98.1.129/32, 10.98.1.130/32]
  ssh key       = /home/ubuntu/.ssh/byoh_data
  boot images   = [ubuntu-noble]

Created host_provider row
Created location
Created sshable
Created vm_host
Created addresses (3 routable)
Queued Prog::Vm::HostNexus strand st-ABCD1234

Registration complete.
  vm_host ubid:  vh-XXXXX
  strand:        st-ABCD1234
```

**Write down the strand ID** (`st-ABCD1234`) — you'll use it in the
next step.

**The flag meanings** (same as AWS, but worth repeating):
- `--main-ip 10.98.1.20`: the internal-bridge IP of the data plane,
  same address you used to test SSH in Step 10.
- `--routed-network 10.98.1.12x/32`: three pool slots for VMs. You
  can add more later or use a single larger CIDR like
  `10.98.1.128/29` — the strategy object in `model/ip_allocation_strategy.rb`
  handles both forms.
- `--ssh-key ~/.ssh/byoh_data`: the **private** key you generated in
  Step 9. The ctrl plane loads this into Postgres, and respirate
  uses it for all future SSH sessions to the data plane.
- `--location proxmox-homelab`: a label. Appears in the web UI's
  location dropdown. Use anything descriptive.
- `--default-boot-image ubuntu-noble`: **critical**. Without this,
  the `boot_image` table stays empty and VM creation later will fail
  with `"no space left on any eligible host"`. Ubicloud pre-downloads
  this image onto the data plane during host setup.
- `--yes`: skip interactive confirmation.

## Step 12 — Watch the host bootstrap strand

```bash
cd ~/ubicloud
bundle exec ruby -e '
  require_relative "model"
  strand_id = ENV["ST"]
  loop do
    s = Strand[ubid: strand_id]
    puts "#{Time.now.strftime("%H:%M:%S")} label=#{s.label.inspect} exitval=#{s.exitval.inspect}"
    break if s.exitval
    sleep 5
  end
' ST=st-ABCD1234
```

Substitute your strand ID. Expected progression (~6-10 minutes
start to finish on a modern Proxmox host):

```
13:04:12 label="start"                exitval=nil
13:04:17 label="bootstrap_rhizome"    exitval=nil
13:04:32 label="install_rhizome"      exitval=nil
13:05:47 label="prep_host"            exitval=nil
13:06:52 label="learn_network"        exitval=nil
13:07:02 label="learn_storage"        exitval=nil
13:07:12 label="setup_hugepages"      exitval=nil
13:07:22 label="setup_spdk"           exitval=nil
13:09:10 label="install_vhost_backend" exitval=nil
13:09:20 label="download_boot_images" exitval=nil
13:11:40 label="wait_host_ready"      exitval=nil
13:12:10 label={"msg"=>"host ready"}  exitval={"host_id"=>"vh-XXXX"}
```

**Stage-by-stage explanation** (in case you want to know what's
happening):

1. **bootstrap_rhizome** — ctrl plane SSHes to data plane, installs
   git + ruby-bundler + basic tools.
2. **install_rhizome** — clones the Ubicloud repo to
   `/opt/rhizome-host` on the data plane and runs `bundle install`.
3. **prep_host** — installs kernel modules (vhost_vdpa), configures
   sysctls (ip_forward), installs SPDK build deps. The former
   Hetzner-specific `nvme-cli` install is now conditional so it's a
   no-op on a Proxmox VM without visible NVMe.
4. **learn_network** — discovers the data plane's IPs, interfaces,
   default route. The rewritten discovery (in the BYOH branch) is
   robust against multi-NIC setups like yours.
5. **learn_storage** — scans disks. Finds the virtual disk Proxmox
   gave you. Logs what it sees; not a failure if storage is sparse.
6. **setup_hugepages** — reserves RAM hugepages for SPDK (usually
   ~4 GB on a 24 GB host).
7. **setup_spdk** — clones SPDK, compiles it (~2-3 min), starts it
   as a systemd service. This is the longest stage.
8. **install_vhost_backend** — builds Ubicloud's vhost-user block
   backend plugin.
9. **download_boot_images** — downloads `ubuntu-noble` to
   `/var/storage/images/`. ~800 MB over the internet; duration
   depends on your pipe.
10. **wait_host_ready** — runs final sanity checks (can I ping
    myself as root, do all services respond).
11. Final entry with `exitval` set — the host is now `accepting`.

**Stuck at one label for >10 minutes?**
- `tmux attach -t ctrl-plane-respirate` on the ctrl plane to see
  live dispatcher output.
- SSH into the data plane and `journalctl -u ubi-spdk.service -f` or
  `tail -50 /var/log/ubi-rhizome/*.log` for on-host errors.
- The most common stall is `download_boot_images` on a slow
  internet connection. Just wait.

## Step 13 — Open the web UI and create your first VM

On your **laptop** (not the ctrl plane), open a browser to:

```
http://<ctrl-plane-LAN-ip>:3000/
```

Where `<ctrl-plane-LAN-ip>` is the DHCP-assigned address on `vmbr0`,
visible in **Proxmox web UI → ubi-byoh-ctrl → Summary**, or from
`ip addr` inside the VM. Something like `http://192.168.1.153:3000/`.

**First-time UI setup**:

1. You'll be redirected to `/login`. Click **Create account**.
2. Fill in email, name, password. Click **Create account**.
3. You need to verify your email, but in dev mode the verify link is
   printed to the Puma log, not emailed. SSH back into the ctrl
   plane and run:
   ```bash
   tmux attach -t ctrl-plane-puma
   ```
   Scroll back until you find a line containing `/verify/`. Copy
   the path (e.g. `/verify/abc123`). Detach from tmux with `Ctrl+B d`.
4. In your browser, navigate to
   `http://<ctrl-plane-LAN-ip>:3000/verify/abc123` (substitute the
   actual token). Click through the confirmation.
5. Log in with the email + password you set.
6. Create a project — any name, e.g. "homelab".

**Upload your laptop's SSH public key to the UI** — this is the key
that will go **inside** the VM you create, so you can SSH into the
VM from your laptop:

1. Sidebar → **SSH keys** → **Create SSH key**
2. Name: `my-laptop`
3. Public key: paste the contents of `~/.ssh/id_ed25519.pub` from
   your laptop (or `~/.ssh/id_rsa.pub`, whichever you have).
4. **Create**

**Create a VM**:

1. Sidebar → **Virtual machines** → **Create virtual machine**
2. Fields:
    - **Location**: `proxmox-homelab` (what you set in Step 11)
    - **Name**: `test-vm`
    - **Size**: `standard-2` (2 vCPU / 8 GB RAM / 20 GB disk) — the
      smallest sensible size
    - **Boot image**: `ubuntu-noble`
    - **SSH keys**: ✓ `my-laptop`
    - **Private subnet**: "Create new" is fine
3. Click **Create virtual machine**

You'll land on the VM detail page. Watch the status field transition:
`start` → `allocate_vm` → `prep` → `clone_ip` → `download` →
`start_after_host_reboot` → `wait_sshable` → `running`.

**First VM takes ~3-4 minutes** because it has to start cloud-hypervisor
and do all the first-time VM prep. Subsequent VMs (created within
the same host's lifetime) are faster (~90 seconds).

## Step 14 — SSH into your VM

Once the VM shows `running`, look at its **"Public IPv4"** field.
With Option A networking, this will be something like `10.98.1.128`.

**The IP you see here is reachable only from the data plane and
ctrl plane** (and any box where you've set up a route to
`10.98.1.0/24`). Not from your laptop out of the box.

**Simplest way to reach your VM from your laptop**: SSH from the
ctrl plane as a jump host.

```bash
# On your laptop:
ssh -J ubuntu@<ctrl-plane-lan-ip> ubi@10.98.1.128
```

The `-J` flag (ProxyJump) tells SSH to first connect to the ctrl
plane (where your laptop key is already in
`/home/ubuntu/.ssh/authorized_keys`), then from there connect to
`10.98.1.128` as the `ubi` user.

**Note**: the VM's username is **`ubi`** (not `ubuntu`, not `root`).
Ubicloud VMs use `ubi` as the default unix user. The SSH key you
uploaded in the web UI goes into `/home/ubi/.ssh/authorized_keys`
inside the VM.

**If the jump command works**: congratulations — you have a working
Ubicloud BYOH deployment on Proxmox. End of happy path.

**If you want more convenient access** from your laptop (without
always typing `-J`), add a static route on your laptop/router:

```bash
# On a Linux laptop, route 10.98.1.0/24 through the ctrl plane's
# LAN IP as a one-shot:
sudo ip route add 10.98.1.0/24 via <ctrl-plane-lan-ip>

# On macOS:
sudo route -nv add -net 10.98.1.0/24 <ctrl-plane-lan-ip>

# On Windows (admin cmd):
route add 10.98.1.0 mask 255.255.255.0 <ctrl-plane-lan-ip>
```

This doesn't persist across reboots — make it permanent via
your router's static-route feature if you use the VMs regularly,
or use Option D (Tailscale) which sidesteps all this.

---

# Part 5 — Networking deep dive

Part 4 used Option A (private lab, LAN-only). This section walks
through the other three options in detail. **Skip this section
entirely on your first run.** Come back when you have a working
Option A and want to expose VMs differently.

## Option A — Private lab, LAN-only

Already covered in Part 4. Quick recap:

- VM pool: `10.98.1.128`, `.129`, `.130` (on `vmbr1`)
- Reachable from: ctrl plane, Proxmox host, anything with a static
  route to `10.98.1.0/24`
- Ideal for: first run, learning, self-contained testing
- Drawbacks: not reachable from your laptop out of the box, not
  reachable from the internet

## Option B — Router DNAT port forwarding

You've done Option A first. Now you want to expose a specific VM on
the internet via a specific port on your existing public IP.

**Step B1 — Add a route on your home router so the router knows
how to reach `10.98.1.0/24`**:

Most home routers have a "Static routes" section somewhere in
Advanced → Network. Add:

- Destination network: `10.98.1.0`
- Netmask: `255.255.255.0`
- Gateway: `<Proxmox host's LAN IP>` (e.g. `192.168.1.50`)
- Interface: LAN

This tells the router: "packets destined for 10.98.1.x should be
forwarded to the Proxmox host, which knows what to do with them."

**Step B2 — Enable IP forwarding on the Proxmox host** (so it can
act as a router between vmbr0 and vmbr1):

```bash
# On the Proxmox host:
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-ubi-byoh.conf
```

Note: Ubuntu 24.04 already has `ip_forward=1` set on the data plane
VM (via the rhizome setup). But the **Proxmox host itself** may not,
and it needs to to act as the intermediate router.

**Step B3 — Add a port-forward rule on your home router**:

On the router's Port Forwarding page:

- External port: `2201`
- Internal IP: `10.98.1.128` (your target VM's IP)
- Internal port: `22`
- Protocol: TCP

Now `ssh -p 2201 ubi@<your-home-public-ip>` from anywhere on the
internet will land on your VM's sshd.

**Repeat** per VM per port. This gets unwieldy fast — Option B is
really only suitable for 1-2 services.

## Option C — Routed subnet from ISP

This is the "real" BYOH topology. Your ISP has routed a static
block of public IPs to your WAN address — e.g. `203.0.113.0/29`
(8 addresses, 6 usable).

**Step C1 — Confirm the routing with your ISP.** Call them if needed.
The question is: "Is my /29 statically routed to my WAN IP, or is it
a public /29 that I'm given one IP from?" For this to work, it must
be the former ("routed" or "on-route"), not the latter ("network
block with usable IPs in the same broadcast domain").

**Step C2 — Configure your router** to route the /29 to your
Proxmox host:

On a decent router (OpenWrt, pfSense, OPNsense, MikroTik):

```
ip route add 203.0.113.0/29 via <Proxmox host LAN IP> dev <LAN interface>
```

Or on consumer routers, use the static route UI similar to Option B,
but with your public /29 as the destination.

**Step C3 — Configure the Proxmox host** to forward those packets
to the data plane VM:

```bash
# On the Proxmox host:
sysctl -w net.ipv4.ip_forward=1
ip route add 203.0.113.0/29 via 10.98.1.20 dev vmbr1
# Persist:
cat >> /etc/network/interfaces.d/99-byoh-routing <<'EOF'
post-up ip route add 203.0.113.0/29 via 10.98.1.20 dev vmbr1
post-down ip route del 203.0.113.0/29 via 10.98.1.20 dev vmbr1
EOF
```

**Step C4 — Register Ubicloud with the public routed network**:

If you already registered with Option A's private IPs, undo that
(delete the host via `bin/deregister-byoh-host` or manual DB surgery)
and re-register:

```bash
./bin/register-byoh-host \
    --provider generic \
    --main-ip 10.98.1.20 \
    --routed-network 203.0.113.0/29 \
    --ssh-key ~/.ssh/byoh_data \
    --location homelab-public \
    --default-boot-image ubuntu-noble \
    --yes
```

Now when you create a VM in the web UI, it will get a real public
IP (e.g. `203.0.113.1`). SSH from anywhere:

```bash
ssh ubi@203.0.113.1
```

**Pros over Option A/B**:
- Real 1:1 public IP per VM. Web UI shows the correct IP (no AWS
  EIP-DNAT gotcha).
- No per-port router config. Every port of every VM is directly
  reachable (subject to your data plane's firewall).
- Matches the real BYOH use case — this is exactly how Hetzner,
  OVH, and Equinix customers run Ubicloud in production.

**Cons**:
- Requires an ISP that sells routed /29s. Not all do.
- Security: your VMs are now on the public internet. Make sure
  sshd is properly configured and don't run anything you wouldn't
  run on a public cloud.

## Option D — Tailscale / WireGuard overlay

You want to reach your VMs from anywhere without touching ISP
config, router config, or opening any ports.

**Easiest approach — install Tailscale on the data plane and enable
subnet routing**:

```bash
# SSH into the data plane:
ssh ubuntu@<data-plane-lan-ip>

# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale and advertise the BYOH subnet
sudo tailscale up \
    --advertise-routes=10.98.1.0/24 \
    --accept-dns=false \
    --hostname=ubi-byoh-data
```

Tailscale prints a URL on stdout — open it on your laptop to
authenticate the node.

Then in the Tailscale admin panel (https://login.tailscale.com/admin),
find the `ubi-byoh-data` machine, click **Edit route settings**,
and **enable** the 10.98.1.0/24 subnet route.

On your laptop (which also has Tailscale installed and is on the
same tailnet), `ssh ubi@10.98.1.128` now works **from anywhere on
the internet**, encrypted through WireGuard, without opening a
single port at your home router.

**Pros**: zero ISP/router config. Works behind CGNAT. Works from
anywhere. Encrypted.

**Cons**: VMs aren't "publicly" reachable (good for dev, bad if
you want to host a public website from them). Depends on Tailscale
infrastructure (the coordination server; data-plane traffic is P2P
WireGuard, not routed through Tailscale's servers).

---

# Part 6 — Operations

## Troubleshooting

### `cat /sys/module/kvm_intel/parameters/nested` returns `N`

- The `/etc/modprobe.d/kvm-intel.conf` file doesn't exist, is
  wrong, or the module wasn't reloaded after you created it.
- **Fix**:
    ```bash
    echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf
    modprobe -r kvm_intel && modprobe kvm_intel
    cat /sys/module/kvm_intel/parameters/nested   # must print Y
    ```
- If `modprobe -r` fails because VMs are running, reboot the
  Proxmox host.

### `/dev/kvm` missing inside the data plane VM

- Check the data plane's CPU type:
    ```bash
    # On Proxmox host:
    qm config $VMID_DATA | grep cpu
    ```
    Must print `cpu: host`. If it says `cpu: kvm64` or anything else,
    fix with `qm set $VMID_DATA --cpu host` and reboot the VM.
- Check nested virt is enabled on the **host** (see previous item).
- Check the CPU actually supports VT-x:
    ```bash
    grep -c -E 'vmx|svm' /proc/cpuinfo   # on Proxmox host
    ```
    Must be > 0. If 0, enable VT in BIOS.

### Cloud-init failed / VM has no network / SSH hangs on first try

- Open the Proxmox web UI **Console** for the VM and look for
  cloud-init error output. Usually the issue is an incorrect
  `--sshkeys` path (file doesn't exist or is unreadable) or a
  malformed `--ipconfig0` string.
- **Regenerate cloud-init image**: on the Proxmox host,
  ```bash
  qm set $VMID_CTRL --ide2 $STORAGE:cloudinit
  ```
  This forces Proxmox to regenerate the cloud-init ISO from current
  settings. Then restart the VM.

### `qm clone` fails with "storage not available"

- `$STORAGE` is wrong. Run `pvesm status` and substitute the correct
  storage name (e.g. `local-zfs` instead of `local-lvm`).

### Bootstrap script fails on Ruby compile

- Transient mise/ruby-build network issue. Re-run the `curl | bash`
  one-liner — it's idempotent.
- If persistently failing, `cat ~/.ubi-bootstrap/ruby-install.log`
  on the ctrl plane for the actual error.

### Bootstrap script fails on `bundle install` with a native gem error

- An apt library is missing. Most commonly `libyaml-dev` or
  `libffi-dev`. Install it:
    ```bash
    sudo apt-get install -y libyaml-dev libffi-dev libpq-dev
    ```
- Re-run the bootstrap (it'll resume).

### Host strand stuck on `setup_spdk` for >15 minutes

- SSH into the data plane and check the SPDK build log:
    ```bash
    ssh -i ~/.ssh/byoh_data root@10.98.1.20 \
        'journalctl -u ubi-spdk.service -n 100 --no-pager'
    ```
- Most common cause on Proxmox: hugepages couldn't be allocated
  because something else (Proxmox itself, another VM) has already
  consumed the host's contiguous memory. Fix by bumping the data
  plane VM's memory and rebooting it cleanly (not from a paused
  state), so the host can give contiguous hugepages at boot.

### VM creation hangs at `wait_sshable` forever

- SSH into the data plane and check that cloud-hypervisor is
  actually running:
    ```bash
    ssh -i ~/.ssh/byoh_data root@10.98.1.20 'pgrep -a cloud-hypervisor'
    ```
- If nothing returns: the VM process crashed. Check
  `/var/log/vms/<vm-ubid>/ch.log` for the failure. Most common:
  nested virt broken (somehow Step 7 test passed but something
  regressed — usually a reboot reset `nested=Y` because you put
  it in a file that isn't loaded).
- If cloud-hypervisor is running but the VM isn't reaching
  `wait_sshable`: the VM's cloud-init is running. First-boot
  cloud-init can take 90+ seconds on a cold image. Wait 5 minutes
  before escalating.

### I can SSH to the VM from the ctrl plane but not from my laptop

- You're hitting the "10.98.1.0/24 is only routable inside vmbr1"
  reality. Either:
    1. SSH via the ctrl plane as jump host:
       `ssh -J ubuntu@<ctrl-lan-ip> ubi@10.98.1.128`
    2. Add a static route on your laptop/router (see §Step 14)
    3. Switch to Option D (Tailscale) for out-of-the-box
       laptop-from-anywhere access

### Proxmox web UI shows 100% CPU on the data plane during VM boot

- Normal. SPDK pins some cores at 100% by design (poll-mode drivers).
  This is not wasted CPU — it's idling in userspace waiting for I/O.
- If you're bothered by the Proxmox graph: `qm set $VMID_DATA
  --cpulimit 8` to enforce a hard cap so it doesn't eat into ctrl
  plane CPU.

### Data plane OOM-killed during `download_boot_images`

- 16 GB is too tight if the host is also running other VMs. Bump
  data plane RAM to 24 GB minimum (that's why the guide recommends
  24).

### Running both ctrl and data on 16 GB host, can't fit both

- It's a stretch but possible. Run the ctrl plane with 2 GB RAM
  (`qm set $VMID_CTRL --memory 2048`) and the data plane with 12 GB
  (`qm set $VMID_DATA --memory 12288`). It works but bootstrap will
  be slow and you can only create 1 small VM at a time.
- **Better**: this is a sign you should run ctrl and data on two
  separate Proxmox hosts, or consolidate on a bigger machine.

---

## FAQ

### Q. Can I run the ctrl plane and data plane on different Proxmox hosts?

Yes, and it's the more realistic "production-like" setup. Create
`ubi-byoh-ctrl` on one Proxmox host and `ubi-byoh-data` on another.
The two hosts need to be able to reach each other — simplest is to
put them on the same LAN subnet and use their LAN IPs, skipping the
`vmbr1` internal bridge entirely.

In `register-byoh-host`, set `--main-ip` to the data plane VM's LAN
IP (not an internal bridge IP), and `--routed-network` to whatever
public or private range you've configured on that LAN.

### Q. Can I run the data plane on a physical Proxmox host directly (no nesting)?

You can, but you'd skip Proxmox's isolation and Ubicloud would own
the physical host. That works — it's actually the most performant
setup — but it means your Proxmox host becomes a dedicated Ubicloud
node and you can't use it for other VMs. To do this:

1. Install Ubuntu 24.04 (not Proxmox) on the physical host.
2. Register it as the data plane directly from an external ctrl
   plane (another machine).
3. Use one of the "control plane elsewhere" topologies.

This is the "Variant 2" described in the AWS SETUP.md Advanced
Variants section.

### Q. Why does the data plane need 8 cores / 24 GB when my VMs will only be 2 cores / 8 GB?

SPDK alone reserves 2-4 cores for its polling threads and 2-4 GB for
hugepages, before any VMs run. Cloud-hypervisor overhead per VM is
another ~1 GB. Ubicloud's on-host Ruby agents use another ~1 GB.
After that subtraction, you need some headroom for the nested VM's
actual workload. 24 GB host → ~14 GB usable for guests. 8 cores →
~5 usable for guests. Enough for one `standard-4` VM or two
`standard-2` VMs.

You can shrink to 4 vCPU / 12 GB for a "can I create a single
minimal VM" test, but don't go below that.

### Q. How does performance compare to real bare metal?

Short answer: **70-90% of native** for most workloads, dropping to
~30% for disk-heavy workloads unless you pass through real NVMe.

Breakdown:
- **CPU-bound code**: ~95% of native. The nested virt overhead is
  mostly exit-handling, and KVM is very good at avoiding exits for
  CPU-bound code.
- **Memory**: 100% of native. Once hugepages are set up, there's
  no translation overhead.
- **Network (virtio-net)**: ~70-85% of line rate inside nested VMs.
  Fine for anything <1 Gbps.
- **Disk**: this is the big one. Default config (qcow2 on LVM-Thin
  on ext4 on a physical disk) gives you 4-5 layers of translation
  and drops random-IO IOPS by 5-10x. If performance matters, see
  [Performance tuning](#performance-tuning--pci-passthrough-for-nvme)
  below.

### Q. Can I snapshot the whole setup and roll back?

Yes — and this is a huge advantage over AWS bare metal, which can't
snapshot at all.

```bash
# Snapshot both VMs at once
qm snapshot $VMID_CTRL before-upgrade
qm snapshot $VMID_DATA before-upgrade

# Later, roll back
qm rollback $VMID_CTRL before-upgrade
qm rollback $VMID_DATA before-upgrade
```

You can also snapshot at arbitrary strand progress points to speed
up iteration when developing on the BYOH driver. Snapshot after
bootstrap completes; every re-run of the register-and-test flow
restarts from the snapshot instead of the 10-minute bootstrap.

### Q. My Proxmox host has dynamic IP from my router — will ctrl plane LAN IP change?

The ctrl plane VM gets its `vmbr0` (LAN) IP via DHCP from your home
router. If your router hands out the same IP each time (most do, for
known MACs), it's stable. If not, use a DHCP reservation on the
router for the ctrl plane's MAC, or switch to static config:

```bash
qm set $VMID_CTRL --ipconfig1 ip=192.168.1.10/24,gw=192.168.1.1
```

(Substitute your LAN subnet and gateway.)

### Q. Can I use this with Proxmox's built-in firewall?

Yes. The default config is "firewall disabled, nothing filtered",
which is what this guide assumes. If you enable the datacenter or
node-level firewall, add allow rules for:
- Inbound TCP 3000 to the ctrl plane VM (web UI)
- Inbound TCP 22 to the ctrl plane VM (SSH from laptop)
- All traffic between `vmbr1` members (ctrl ↔ data)
- All outbound from both VMs (apt, DNS, image downloads)

### Q. What if I want HTTPS on the web UI?

Out of scope for this guide, but straightforward: install nginx or
Caddy on the ctrl plane VM, configure it as a reverse proxy to
`localhost:3000`, and set up a TLS cert (Let's Encrypt if the ctrl
plane has a public DNS name, or a self-signed cert for LAN-only).
Then open port 443 on the SG/firewall instead of 3000.

### Q. What about IPv6?

The guide sticks to IPv4 because most homelabs don't have routed
IPv6. If your ISP gives you a /56 or /64, you can configure `vmbr1`
with an IPv6 prefix and register with an IPv6 routed network. The
BYOH driver supports IPv6 — just add a second `--routed-network`
with a v6 CIDR (the first v6 /64 becomes the host's `net6`, same
as Hetzner).

---

## Performance tuning — PCI passthrough for NVMe

If you want the data plane to use a real NVMe drive directly
(bypassing Proxmox's storage stack entirely for VM disk images),
this is how.

**When to do this**: you've got Ubicloud working on Proxmox via
plain storage, you want real NVMe performance, and you have a spare
NVMe drive that Proxmox itself doesn't use (not the boot drive!).

**One-time Proxmox host setup** (IOMMU + kernel config):

```bash
# 1. Enable IOMMU in GRUB
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub
# (AMD: use 'amd_iommu=on iommu=pt' instead)
update-grub

# 2. Enable VFIO modules
cat > /etc/modules-load.d/vfio.conf <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF
update-initramfs -u -k all

# 3. Blacklist the nvme module so Proxmox doesn't claim the device
echo "blacklist nvme" >> /etc/modprobe.d/pve-blacklist.conf
update-initramfs -u -k all

reboot
```

**After reboot**, identify the NVMe and bind VFIO to it:

```bash
# Find the PCI address and PCI vendor:device ID
lspci -nn | grep -i nvme
# Example output:
# 01:00.0 Non-Volatile memory controller [0108]: Samsung ... [144d:a809]

# Bind the device to vfio-pci
echo "options vfio-pci ids=144d:a809" > /etc/modprobe.d/vfio.conf
update-initramfs -u -k all

reboot
```

**Attach to the data plane VM**:

```bash
# Stop the data plane first
qm stop $VMID_DATA

# Attach the NVMe via passthrough
qm set $VMID_DATA --hostpci0 01:00.0,pcie=1

# Start it again
qm start $VMID_DATA
```

**Inside the data plane VM**, the NVMe now appears as a real
`/dev/nvme0n1`. Delete its partition table (it'll be whatever the
previous use left), create a fresh filesystem, mount it at
`/var/storage`:

```bash
ssh root@10.98.1.20   # via the BYOH SSH key
lsblk                 # verify /dev/nvme0n1 is there

mkfs.ext4 -F /dev/nvme0n1
mkdir -p /var/storage
mount /dev/nvme0n1 /var/storage
echo '/dev/nvme0n1 /var/storage ext4 defaults 0 2' >> /etc/fstab
```

Now SPDK's vhost backend writes VM disk images to real NVMe, and
nested VMs see ~80-90% of bare-metal NVMe speed. You're within
spitting distance of what an AWS m5d.metal instance gives you.

**Caveats**:
- The passthrough device is exclusively owned by the data plane VM —
  neither Proxmox nor any other VM can see or use it while the data
  plane is running.
- If you shut down the data plane, the NVMe stays unavailable to
  the host (blacklisted). To reclaim it, reverse the blacklist +
  reboot.
- IOMMU groups: if your NVMe is grouped with other devices (check
  `find /sys/kernel/iommu_groups/ -type l`), you have to pass
  through all of them together or none. This is a hardware/BIOS
  thing, not a Proxmox thing.

---

## Cleanup — tear it all down

To destroy everything this guide created, in order:

```bash
# 1. Stop and destroy the VMs
qm stop $VMID_CTRL   --skiplock  # graceful stop can hang if Puma is running
qm stop $VMID_DATA   --skiplock
qm destroy $VMID_CTRL
qm destroy $VMID_DATA
qm destroy $VMID_TMPL

# 2. Delete the BYOH bridge
cat /etc/network/interfaces        # find the vmbr1 block
# Remove those lines manually (or edit via the web UI:
#   Datacenter → node → System → Network → select vmbr1 → Remove)
ifreload -a

# 3. (optional) Undo nested virt
rm /etc/modprobe.d/kvm-intel.conf  # or kvm-amd.conf
update-initramfs -u -k all
# takes effect on next reboot
```

**Sanity check**:

```bash
qm list | grep -i ubi-byoh         # should print nothing
ip -br a | grep vmbr1              # should print nothing
```

**Disk space recovery**: after `qm destroy`, the underlying disks
are freed from the storage pool. `pvesm status` should show the
space returned to "Available".

---

# Appendix A — Command reference for the impatient

For people who've done this before and just want a copy-pasteable
script. **Do not run this blindly** — read Part 2 / Part 3 first to
understand what's happening.

```bash
# -- on the Proxmox host, as root ----------------------------------
VMID_TMPL=9000
VMID_CTRL=101
VMID_DATA=102
STORAGE=local-lvm
BRIDGE_UPLINK=vmbr0
BRIDGE_BYOH=vmbr1
LAPTOP_PUBKEY="$HOME/.ssh/id_ed25519.pub"

# 1. Enable nested virt
echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf
modprobe -r kvm_intel && modprobe kvm_intel

# 2. Create BYOH bridge
cat >> /etc/network/interfaces <<EOF

auto $BRIDGE_BYOH
iface $BRIDGE_BYOH inet static
    address 10.98.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
ifreload -a

# 3. Download cloud image
cd /var/lib/vz/template/iso
wget -nc https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# 4. Create template
qm create $VMID_TMPL \
    --name ubi-byoh-template \
    --memory 2048 --cores 2 \
    --net0 virtio,bridge=$BRIDGE_BYOH \
    --serial0 socket --vga serial0 \
    --agent enabled=1 --ostype l26
qm importdisk $VMID_TMPL \
    /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img $STORAGE
qm set $VMID_TMPL --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID_TMPL-disk-0
qm set $VMID_TMPL --boot c --bootdisk scsi0
qm set $VMID_TMPL --ide2 $STORAGE:cloudinit
qm template $VMID_TMPL

# 5. Create ctrl plane
qm clone $VMID_TMPL $VMID_CTRL --name ubi-byoh-ctrl --full
qm set $VMID_CTRL \
    --cores 2 --memory 4096 \
    --net0 virtio,bridge=$BRIDGE_BYOH \
    --net1 virtio,bridge=$BRIDGE_UPLINK \
    --ipconfig0 ip=10.98.1.10/24,gw=10.98.1.1 \
    --ipconfig1 ip=dhcp \
    --sshkeys "$LAPTOP_PUBKEY" \
    --ciuser ubuntu --cipassword '' \
    --nameserver 1.1.1.1
qm resize $VMID_CTRL scsi0 +38G
qm start $VMID_CTRL

# 6. Create data plane (with nested virt)
qm clone $VMID_TMPL $VMID_DATA --name ubi-byoh-data --full
qm set $VMID_DATA \
    --cores 8 --memory 24576 --cpu host \
    --net0 virtio,bridge=$BRIDGE_BYOH \
    --net1 virtio,bridge=$BRIDGE_UPLINK \
    --ipconfig0 ip=10.98.1.20/24,gw=10.98.1.1 \
    --ipconfig1 ip=dhcp \
    --sshkeys "$LAPTOP_PUBKEY" \
    --ciuser ubuntu --cipassword '' \
    --nameserver 1.1.1.1
qm resize $VMID_DATA scsi0 +118G
qm start $VMID_DATA

sleep 60
echo "==> ctrl plane LAN IP:"
qm guest cmd $VMID_CTRL network-get-interfaces 2>/dev/null | grep -A1 ip-address
echo "==> data plane LAN IP:"
qm guest cmd $VMID_DATA network-get-interfaces 2>/dev/null | grep -A1 ip-address
echo "==> Next: SSH to the ctrl plane LAN IP and run the bootstrap."
```

After the above finishes, SSH to the ctrl plane LAN IP and run:

```bash
# -- on ubi-byoh-ctrl ---------------------------------------------
curl -sSL https://raw.githubusercontent.com/NameawaShinderu/ubicloud-byoh/byoh-driver/scripts/byoh/bootstrap-ctrl-plane.sh | bash

ssh-keygen -t ed25519 -f ~/.ssh/byoh_data -N ''
cat ~/.ssh/byoh_data.pub   # copy this to the data plane

PUBKEY="$(cat ~/.ssh/byoh_data.pub)"
ssh ubuntu@10.98.1.20 "sudo mkdir -p /root/.ssh && echo '$PUBKEY' | sudo tee -a /root/.ssh/authorized_keys > /dev/null && sudo chmod 600 /root/.ssh/authorized_keys"

cd ~/ubicloud
export RACK_ENV=development
./bin/register-byoh-host \
    --provider generic \
    --main-ip 10.98.1.20 \
    --routed-network 10.98.1.128/32 \
    --routed-network 10.98.1.129/32 \
    --routed-network 10.98.1.130/32 \
    --ssh-key ~/.ssh/byoh_data \
    --location proxmox-homelab \
    --default-boot-image ubuntu-noble \
    --yes
```

Wait 10 minutes, then open the web UI at `http://<ctrl-lan-ip>:3000/`.

---

# Appendix B — What's in the rhizome agent, and why it matters

Optional background reading for people who want to understand what
Ubicloud actually does to your data plane host.

**`rhizome`** is Ubicloud's on-host agent — the code that runs on
the data plane (pushed there by the ctrl plane at registration
time). It lives under `/opt/rhizome-host/` and has three
responsibilities:

1. **Expose a small RPC surface over SSH** — the ctrl plane doesn't
   talk to rhizome via HTTP/gRPC. It literally `ssh root@data-plane
   'ruby /opt/rhizome-host/bin/execute.rb <command>'` for every
   operation. All state transitions are shell commands wrapped in
   Ruby.
2. **Manage the VM lifecycle** — cloud-hypervisor processes, tap
   devices, per-VM network namespaces, nftables rules for firewall,
   SPDK bdev definitions for disks.
3. **Enforce isolation** — each VM gets its own network namespace,
   its own filesystem (via SPDK vhost-user-blk), its own cgroup for
   CPU/memory limits.

The reason the BYOH registration process is slow (5-8 minutes of
strand progress) is that rhizome has to do all of this on a fresh
host:

- **Install kernel modules** (vhost_vdpa, vhost_net)
- **Configure sysctls** for routing and forwarding
- **Compile and install SPDK** (the userspace storage system) from
  source
- **Allocate hugepages** (SPDK requires them)
- **Build and start systemd services** for SPDK, the vhost backend,
  and the per-VM management hooks
- **Download the boot images** (Ubuntu 24.04 cloud image)
- **Verify everything is running** via a final health check

Once this is done, the host is in the `accepting` state and the
dispatcher can start VM creation work on it. VM creation itself is
much faster because all the heavy lifting is pre-baked.

**Why does this matter for you?**

- If a strand is stuck, you can SSH to the data plane yourself and
  run the same commands rhizome would. The logs are in
  `/var/log/ubi-rhizome/*.log` and the services are standard
  systemd units (`systemctl status ubi-spdk.service` etc.).
- If you want to customize the data plane (different SPDK version,
  different cloud-hypervisor, etc.), you patch the rhizome scripts
  in the Ubicloud repo and re-register the host.
- There is nothing magical about Ubicloud's on-host setup — it's
  all shell commands in Ruby scripts. You can read every single
  one of them. If something breaks, you can fix it.

---

This is a working doc. If you run into something that isn't here,
open an issue at
https://github.com/NameawaShinderu/ubicloud-byoh/issues with:
- `pveversion` output from your Proxmox host
- `qm config <id>` for the affected VM
- Relevant strand output (`ctrl-plane-respirate` tmux log)
- `journalctl` from the data plane for the failed service

— and it'll probably get added to the FAQ/troubleshooting section.
