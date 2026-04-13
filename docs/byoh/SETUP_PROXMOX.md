# Ubicloud BYOH — Proxmox VE Setup (homelab edition)

**Audience**: you have a Proxmox VE host running on your own hardware,
a web browser, and an SSH client (or the Proxmox web console). You
don't need AWS, Terraform, Kubernetes, a cloud account, or money.

**Time**: ~60–90 minutes end to end. The long tail is the ctrl plane
bootstrap (~10 min) and the nested-KVM cold start for your first VM.

**Cost**: $0. Your electric bill.

**End state**: you have a fully functional Ubicloud control plane in
a VM on your Proxmox host, a fully functional Ubicloud data plane in
*another* VM on the same host, and you can log into the web UI from
your laptop, create a VM through the UI, and SSH into that VM from
your laptop. Everything on hardware you own.

This guide is a sibling of [`SETUP.md`](SETUP.md) (the AWS Console
path). Use this one if you have physical hardware; use `SETUP.md` if
you want to run it on AWS. Both reach the same end state.

---

## A note on the markers used in this doc

Every shell command in this guide is prefixed with a banner telling
you **where to run it** and **as which user**. There are 4 places
you'll switch between, and confusing them is the #1 source of "why
isn't this working":

```bash
# === RUN ON: Proxmox host, as root ===
# This block runs on the physical Proxmox machine, in its shell.

# === RUN ON: ubi-byoh-ctrl (10.98.1.10), as ubuntu ===
# This block runs inside the control plane VM.

# === RUN ON: ubi-byoh-data (10.98.1.20), as root ===
# This block runs inside the data plane VM.

# === RUN ON: your laptop ===
# This block runs on your own machine, where your browser is.
```

When you copy a block, copy the whole thing including the banner —
they're bash comments, harmless to paste, and they make it easy to
double-check you're in the right shell before pressing enter.

---

## Table of contents

- [Part 1 — Background](#part-1--background)
    1. [What Ubicloud is, in one page](#1-what-ubicloud-is-in-one-page)
    2. [What "BYOH" means](#2-what-byoh-means)
    3. [What you're building on Proxmox](#3-what-youre-building-on-proxmox)
    4. [Why Proxmox is a better fit than AWS](#4-why-proxmox-is-a-better-fit-than-aws)
- [Part 2 — Pre-flight: inspect your Proxmox host](#part-2--pre-flight-inspect-your-proxmox-host)
    - [Step 0.1 — Confirm Proxmox version](#step-01--confirm-proxmox-version)
    - [Step 0.2 — Check CPU virt extensions](#step-02--check-cpu-virt-extensions)
    - [Step 0.3 — Check nested virt status](#step-03--check-nested-virt-status)
    - [Step 0.4 — Audit free RAM, disk, CPU](#step-04--audit-free-ram-disk-cpu)
    - [Step 0.5 — List your storage pools](#step-05--list-your-storage-pools)
    - [Step 0.6 — Map your network layout](#step-06--map-your-network-layout)
    - [Step 0.7 — Internet reachability](#step-07--internet-reachability)
    - [Step 0.8 — Pick free VMIDs](#step-08--pick-free-vmids)
    - [Step 0.9 — (Optional) NVMe devices for passthrough](#step-09--optional-nvme-devices-for-passthrough)
- [Part 3 — Plan before you click](#part-3--plan-before-you-click)
    - [The 4 planes you'll work in](#the-4-planes-youll-work-in)
    - [How to enter each plane](#how-to-enter-each-plane)
    - [The big networking decision](#the-big-networking-decision)
    - [IP address plan](#ip-address-plan)
    - [VM spec plan](#vm-spec-plan)
- [Part 4 — Build it (Steps 1-14)](#part-4--build-it-steps-1-14)
    - [Step 1 — Enable nested virt on the Proxmox host](#step-1--enable-nested-virt-on-the-proxmox-host)
    - [Step 2 — Create a BYOH bridge](#step-2--create-a-byoh-bridge)
    - [Step 3 — Download the Ubuntu cloud image](#step-3--download-the-ubuntu-cloud-image)
    - [Step 4 — Create the VM template](#step-4--create-the-vm-template)
    - [Step 5 — Create the control plane VM](#step-5--create-the-control-plane-vm)
    - [Step 6 — Create the data plane VM](#step-6--create-the-data-plane-vm)
    - [Step 7 — First-boot smoke test (nested-KVM check)](#step-7--first-boot-smoke-test-nested-kvm-check)
    - [Step 8 — Bootstrap the control plane](#step-8--bootstrap-the-control-plane)
        - [Step 8a — What the bootstrap script actually does (transparency)](#step-8a--what-the-bootstrap-script-actually-does-transparency)
        - [Step 8b — Manual install path (if you don't want curl pipe bash)](#step-8b--manual-install-path-if-you-dont-want-curl-pipe-bash)
    - [Step 8.5 — Tour the Ubicloud repo on the ctrl plane](#step-85--tour-the-ubicloud-repo-on-the-ctrl-plane)
    - [Step 9 — Generate the ctrl→data SSH key](#step-9--generate-the-ctrldata-ssh-key)
    - [Step 10 — Install the key on the data plane](#step-10--install-the-key-on-the-data-plane)
    - [Step 11 — Register the BYOH host](#step-11--register-the-byoh-host)
    - [Step 12 — Watch the host bootstrap strand](#step-12--watch-the-host-bootstrap-strand)
    - [Step 13 — Open the web UI and create your first VM](#step-13--open-the-web-ui-and-create-your-first-vm)
    - [Step 14 — SSH into your VM](#step-14--ssh-into-your-vm)
- [Part 5 — Networking deep dive (4 options)](#part-5--networking-deep-dive-4-options)
- [Part 6 — Operations](#part-6--operations)
    - [Reference card: how to check things on each plane](#reference-card-how-to-check-things-on-each-plane)
    - [Troubleshooting](#troubleshooting)
    - [FAQ](#faq)
    - [Performance tuning — PCI passthrough for NVMe](#performance-tuning--pci-passthrough-for-nvme)
    - [Cleanup — tear it all down](#cleanup--tear-it-all-down)
- [Appendix A — Command reference for the impatient](#appendix-a--command-reference-for-the-impatient)
- [Appendix B — What the rhizome agent does on the data plane](#appendix-b--what-the-rhizome-agent-does-on-the-data-plane)

---

# Part 1 — Background

## 1. What Ubicloud is, in one page

Ubicloud is an open-source "cloud platform you run yourself." Think:
the parts of AWS (EC2, VPC, block storage, private networks) you
most commonly use, re-implemented as software you run on your own
bare-metal servers. You download it, point it at one or more Linux
machines you control, and it turns them into a cloud — web UI, REST
API, ability to create VMs, attach them to private networks, give
them public IPs, and SSH into them — without any cloud provider in
the middle.

**How it's built**:

- **Control plane** (Ruby): Postgres + a Roda/Puma web UI on port
  3000 + a state-machine dispatcher called `respirate`. Users talk
  to it. It does not run VMs itself.
- **Data plane**: any Linux box running Ubicloud's on-host agent,
  `rhizome`. The control plane SSHes into it and drives everything
  via shell commands. The data plane runs the actual VMs using
  `cloud-hypervisor` (Rust VMM) + `SPDK` (userspace storage) +
  per-VM Linux network namespaces + nftables for firewalling.
- **Overlay networking**: IPsec + VXLAN tunnels between data plane
  hosts so VMs on different physical machines share private subnets
  as if they were on the same L2.

## 2. What "BYOH" means

Until recently, Ubicloud assumed you bought machines from **Hetzner**
via their REST API. The provisioning code in
`lib/hosting/hetzner_apis.rb` calls Hetzner endpoints to list
servers, reimage them, hardware-reset them, and pull the routed IP
blocks Hetzner assigned. If you wanted to run on anything else (OVH,
Equinix, your own hardware), the code refused.

**BYOH** ("Bring Your Own Hardware") generic provider is a new
driver that removes this assumption. Instead of calling a provider
API, it takes the SSH endpoint, routed IP range, and optional BMC
credentials as static configuration **you supply at registration
time**. Zero provider API calls. Ubicloud can now run on **any**
Linux box you can SSH into, as long as:

- It's Ubuntu 24.04 LTS (rhizome expects apt + systemd + Ubuntu
  paths).
- The CPU exposes hardware virt extensions (VT-x or SVM) to its
  kernel.
- It has enough disk for the image cache + VM disks.
- The control plane can reach it on TCP/22.

It does **not** need to be physical hardware — a VM with nested virt
is fine. Which brings us to Proxmox.

## 3. What you're building on Proxmox

```
  +-------------------- Proxmox host (your hardware) -------------------+
  |                                                                     |
  |   physical NIC --- vmbr0 (existing LAN uplink) --- 192.168.1.50    |
  |                                                                     |
  |   vmbr1 (new, BYOH-internal bridge) --------- 10.98.1.1/24          |
  |     |                                                               |
  |     +-- ubi-byoh-ctrl  VM  (2 vCPU / 4 GB / 40 GB)                  |
  |     |     - Ubicloud control plane (Puma :3000 + Postgres + respirate)
  |     |     - 2 NICs:  10.98.1.10 (vmbr1)   <-- internal               |
  |     |                DHCP on vmbr0          <-- LAN-facing            |
  |     |                                                               |
  |     +-- ubi-byoh-data  VM  (8 vCPU / 24 GB / 120 GB)                |
  |           - cpu=host + nested KVM enabled                           |
  |           - rhizome agent installed by ctrl plane via SSH           |
  |           - SPDK + cloud-hypervisor                                 |
  |           - 2 NICs:  10.98.1.20 (vmbr1)   <-- internal               |
  |                      DHCP on vmbr0          <-- LAN-facing            |
  |           - inside it: your Ubicloud VMs                            |
  |                                                                     |
  +---------------------------------------------------------------------+
```

The ctrl plane is a normal Ubuntu VM — no special flags. The data
plane is also a normal Ubuntu VM, but with `cpu: host` + nested virt
enabled on the Proxmox host. That single combination gives the data
plane its own `/dev/kvm` so cloud-hypervisor can run more VMs on top.
Those nested VMs are your Ubicloud workloads.

## 4. Why Proxmox is a better fit than AWS

| Property                | AWS ([SETUP.md](SETUP.md))    | Proxmox (this doc)               |
|-------------------------|-------------------------------|----------------------------------|
| Data plane hardware     | `m5d.metal` (~$3,900/mo)      | a VM on your homelab box ($0)    |
| Spin-up time            | ~8 min (AWS races to rack)    | ~60 seconds (`qm clone && start`)|
| Teardown time           | 10–20 minutes                 | 2 seconds                        |
| Snapshots               | None (bare metal)             | Yes                              |
| Iterate quickly         | Expensive                     | Trivially                        |
| Public IP for VMs       | EIP-DNAT gotcha               | Your choice (Option A/B/C/D below)|
| Storage backing         | EBS, nested                   | Real local disks; NVMe passthrough optional |

The only thing AWS has going for it is "I already have an AWS
account and I don't want to buy hardware." For anyone who already
has a Proxmox box, this path wins on every other axis.

---

# Part 2 — Pre-flight: inspect your Proxmox host

Spend 5 minutes understanding what your Proxmox host currently
looks like. The answers here decide which networking option you
pick and whether you need to reboot the host to enable nested virt.

**All commands in Part 2 are read-only.** They inspect state, they
don't change anything.

## Step 0.1 — Confirm Proxmox version

```bash
# === RUN ON: Proxmox host, as root ===
pveversion
```

Expected:

```
pve-manager/8.2.4/eeaa0e7a7c0bc0b8 (running kernel: 6.8.8-4-pve)
```

**What you want**: Proxmox VE **8.0 or newer**. This guide is
written against 8.x. It works on 7.x with minor UI differences, but
upgrade to 8.x first if you have the option — it ships kernel 6.x
which has much better nested KVM and a newer cloud-init.

**If you get "command not found"**: you're not on a Proxmox host.
This guide is Proxmox-specific.

## Step 0.2 — Check CPU virt extensions

```bash
# === RUN ON: Proxmox host, as root ===
lscpu | grep Virtualization
grep -E 'vmx|svm' /proc/cpuinfo | head -1
```

Expected:

```
Virtualization:                  VT-x          # Intel
# or
Virtualization:                  AMD-V         # AMD
```

**If empty or "Not supported"**: enable VT-x / SVM in BIOS. This is
the #1 cause of first-time failures — the CPU supports it but it's
disabled in firmware. Reboot, enter BIOS, find "Intel Virtualization
Technology" or "AMD SVM Mode" under CPU Configuration, enable it,
boot back into Proxmox, re-run.

Verify the KVM kernel module is loaded:

```bash
# === RUN ON: Proxmox host, as root ===
lsmod | grep kvm
```

Expected:

```
kvm_intel             495616  0
kvm                  1355776  1 kvm_intel
# or kvm_amd on AMD
```

## Step 0.3 — Check nested virt status

The single most important check in the whole doc.

```bash
# === RUN ON: Proxmox host, as root ===
# Intel:
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null
# AMD:
cat /sys/module/kvm_amd/parameters/nested 2>/dev/null
```

**Want**: `Y` or `1`. If you see `N` or `0`, nested virt is off —
you'll enable it in Step 1 of Part 4. Note the result and move on.

## Step 0.4 — Audit free RAM, disk, CPU

```bash
# === RUN ON: Proxmox host, as root ===
echo '--- memory ---'
free -h
echo '--- disk usage on PVE storage paths ---'
df -h /var/lib/vz /var/lib/pve 2>/dev/null
echo '--- logical CPUs ---'
nproc
echo '--- existing VMs ---'
qm list 2>/dev/null
```

**You need (minimum / recommended)**:

| Resource          | Minimum | Recommended | Why                                 |
|-------------------|---------|-------------|-------------------------------------|
| Free RAM          | 12 GB   | **32 GB**   | 4 GB ctrl + 24 GB data + headroom   |
| Free disk         | 160 GB  | **250 GB**  | 40 GB ctrl + 120 GB data + image cache |
| Free logical CPUs | 4       | **10**      | 2 ctrl + 8 data                     |

If you're tight on RAM, the data plane is the eater — shrink it to
16 GB if you must (the guide assumes 24). Don't go below 12 — SPDK
needs hugepages and will fail.

## Step 0.5 — List your storage pools

```bash
# === RUN ON: Proxmox host, as root ===
pvesm status
```

Expected:

```
Name             Type     Status           Total            Used        Available    %
local             dir     active        98304000        12582912        80789504  12%
local-lvm     lvmthin     active       800000000       100000000       700000000  12%
```

**Pick one** to use for the Ubicloud VMs. The guide's examples use
`local-lvm` — substitute `local-zfs`, `local`, etc. as needed. Note
the name; you'll need it.

**Avoid** for the data plane: NFS, CIFS, Ceph (network-backed
storage chokes SPDK + nested-VM I/O). Keep it local.

## Step 0.6 — Map your network layout

```bash
# === RUN ON: Proxmox host, as root ===
ip -brief addr show
echo '---'
cat /etc/network/interfaces
echo '---'
ip route
```

Example output (trimmed):

```
lo               UNKNOWN        127.0.0.1/8 ::1/128
eno1             UP             
vmbr0            UP             192.168.1.50/24

default via 192.168.1.1 dev vmbr0
192.168.1.0/24 dev vmbr0 proto kernel scope link src 192.168.1.50
```

**Write down**:
- Proxmox host's LAN IP (e.g. `192.168.1.50`)
- LAN subnet (e.g. `192.168.1.0/24`)
- Default gateway (e.g. `192.168.1.1` — your home router)

You need a free non-overlapping subnet for the BYOH bridge. If your
LAN is `192.168.1.0/24`, the guide's `10.98.1.0/24` BYOH bridge is
fine. If your LAN is already `10.98.x.x` for some reason, substitute
`10.77.0.0/24` or any other free RFC1918 range.

## Step 0.7 — Internet reachability

```bash
# === RUN ON: Proxmox host, as root ===
ping -c 2 8.8.8.8
curl -sI https://cloud-images.ubuntu.com | head -1
curl -sI https://github.com | head -1
```

**Want**: all three succeed. If ping fails, fix your gateway/DNS
first (`cat /etc/resolv.conf`). Nothing in this guide works without
internet on the Proxmox host.

## Step 0.8 — Pick free VMIDs

```bash
# === RUN ON: Proxmox host, as root ===
qm list
```

**Pick 3 free VMIDs** for the template, ctrl plane, and data plane.
The guide uses `9000` / `101` / `102` — substitute whatever fits
your numbering.

## Step 0.9 — (Optional) NVMe devices for passthrough

```bash
# === RUN ON: Proxmox host, as root ===
lspci -nn | grep -iE 'nvme|non-volatile'
```

If you have a spare NVMe (not the Proxmox boot drive!), note its
PCI BDF (`01:00.0` style). You'll use it in the
[Performance Tuning](#performance-tuning--pci-passthrough-for-nvme)
section. **Skip this on first run** — get Ubicloud working without
passthrough first.

---

# Part 3 — Plan before you click

## The 4 planes you'll work in

This guide moves between **four different shells** (places you run
commands from). Confusing them is the #1 source of "wait, this
isn't working":

```
                    +-------------------------------+
                    |       1. YOUR LAPTOP          |
                    |  - browser to web UI          |
                    |  - SSH client (ssh, scp)      |
                    |  - copy/paste keys            |
                    +---------------+---------------+
                                    |
                                    | SSH or browser
                                    v
                    +-------------------------------+
                    |    2. PROXMOX HOST            |
                    |  - root shell                 |
                    |  - qm / pvesm / ip commands   |
                    |  - "outside" both VMs         |
                    +---------------+---------------+
                                    |
                                    | qm start / qm clone / vmbr1
                                    v
       +----------------------------+----------------------------+
       |                                                         |
       v                                                         v
+-------------------+                                  +--------------------+
| 3. ubi-byoh-ctrl  |  ----  SSH (10.98.1.20) ---->    |  4. ubi-byoh-data  |
|  (control plane)  |         using byoh_data key      |   (data plane)     |
|                   |                                  |                    |
| - ubuntu user     |                                  | - ubuntu user      |
|   for Ubicloud    |                                  |   for first SSH    |
|   stack           |                                  | - root user        |
| - runs Puma,      |                                  |   for rhizome,     |
|   Postgres,       |                                  |   SPDK, KVM        |
|   respirate       |                                  | - cloud-hypervisor |
| - the repo lives  |                                  |   runs your VMs    |
|   at ~/ubicloud   |                                  |                    |
+-------------------+                                  +--------------------+
```

You'll be jumping between these 4 places throughout Part 4. Every
single shell command in Part 4 starts with a banner like:

```bash
# === RUN ON: ubi-byoh-ctrl (10.98.1.10), as ubuntu ===
```

so you can tell at a glance which shell to be in. **Always check
the banner before pressing enter.**

## How to enter each plane

**Plane 1 — Your laptop** (no work needed, it's the machine you're
sitting at). Use whatever terminal app is normal for you (Terminal
on macOS, gnome-terminal/konsole on Linux, Windows Terminal or
WSL on Windows).

**Plane 2 — The Proxmox host**, two ways:

```bash
# === RUN ON: your laptop ===
# Way A: SSH directly (substitute your Proxmox host's LAN IP)
ssh root@192.168.1.50
```

Or use the web UI's built-in shell — open
`https://192.168.1.50:8006/` in your browser, log in, click your
node in the left sidebar, then click **Shell**. A root shell opens
inside the browser. This is the easiest way for newcomers.

**Plane 3 — The control plane VM** (`ubi-byoh-ctrl`). After it's
created in Step 5, three options:

```bash
# === RUN ON: your laptop ===
# Way A: SSH from your laptop using the ctrl plane's LAN IP
ssh ubuntu@<ctrl-plane-LAN-ip>
```

```bash
# === RUN ON: Proxmox host, as root ===
# Way B: SSH from the Proxmox host using the ctrl plane's internal IP
ssh ubuntu@10.98.1.10
```

Or **Way C**: Proxmox web UI → `ubi-byoh-ctrl` → **Console**. A
browser-based terminal opens via noVNC. Log in as `ubuntu` (no
password — disabled in the cloud image; you'll only get this Console
"in" because the noVNC bypasses sshd). Useful when SSH isn't working
yet.

**Plane 4 — The data plane VM** (`ubi-byoh-data`). After it's
created in Step 6, the same three ways:

```bash
# === RUN ON: your laptop ===
# Way A: SSH from your laptop using the data plane's LAN IP
ssh ubuntu@<data-plane-LAN-ip>
```

```bash
# === RUN ON: ubi-byoh-ctrl (10.98.1.10), as ubuntu ===
# Way B: SSH from ctrl plane to data plane on the internal bridge
ssh -i ~/.ssh/byoh_data root@10.98.1.20    # after Step 10
```

```bash
# === RUN ON: Proxmox host, as root ===
# Way C: SSH from the Proxmox host
ssh ubuntu@10.98.1.20
```

Plus Proxmox web UI → `ubi-byoh-data` → Console, same as Plane 3.

**Quick-reference table**:

| Plane | Hostname        | Internal IP (`vmbr1`) | LAN IP (`vmbr0`)    | Default user           |
|-------|-----------------|-----------------------|---------------------|------------------------|
| 1     | your laptop     | -                     | -                   | you                    |
| 2     | Proxmox host    | 10.98.1.1             | 192.168.1.50 (yours)| `root`                 |
| 3     | ubi-byoh-ctrl   | 10.98.1.10            | DHCP                | `ubuntu`               |
| 4     | ubi-byoh-data   | 10.98.1.20            | DHCP                | `ubuntu` then `root`   |

Print this table or have it open in another tab — you'll reference
it constantly.

## The big networking decision

Ubicloud VMs need IPs from a "routed network" — a CIDR you give to
`register-byoh-host`. How those IPs become reachable depends on
where they're routed.

**Pick one of four options** (full walkthroughs in Part 5):

- **Option A — Private lab, LAN-only** (recommended for first run).
  VMs get `10.98.1.128`, `.129`, `.130`. Reachable from the ctrl
  plane and any machine you add a route on. **Choose this.**
- **Option B — Router DNAT port forwarding**. Same private IPs +
  router forwards specific ports to specific VM IPs. Best for 1-2
  exposed services on top of your existing public IP.
- **Option C — Routed subnet from ISP**. Real public IPs (e.g.
  `203.0.113.0/29`) routed to your home. Best if your ISP supports
  it. Mirror of how Hetzner/OVH/Equinix bare metal works.
- **Option D — Tailscale/WireGuard overlay**. Reach VMs from
  anywhere via Tailscale, no ISP/router config.

**The rest of Part 4 assumes Option A.** Get that working first,
switch later if needed.

## IP address plan

| Role                          | IP             | Notes                         |
|-------------------------------|----------------|-------------------------------|
| BYOH bridge gateway (Proxmox) | `10.98.1.1/24` | Proxmox host on `vmbr1`       |
| ctrl plane — `vmbr1`          | `10.98.1.10`   | internal-facing, static       |
| ctrl plane — `vmbr0`          | `dhcp`         | LAN-facing, for web UI access |
| data plane — `vmbr1`          | `10.98.1.20`   | internal-facing, **main_ip**  |
| data plane — `vmbr0`          | `dhcp`         | LAN-facing, for internet      |
| VM pool slot 0                | `10.98.1.128`  | first BYOH VM                 |
| VM pool slot 1                | `10.98.1.129`  | second BYOH VM                |
| VM pool slot 2                | `10.98.1.130`  | third BYOH VM                 |

Write these down. You'll reference the data plane internal IP
(`10.98.1.20`) as `--main-ip` to `register-byoh-host`, and the VM
pool IPs as `--routed-network` flags.

## VM spec plan

| VM                  | vCPU  | RAM     | Disk    | CPU type | Nested virt | Notes                  |
|---------------------|-------|---------|---------|----------|-------------|------------------------|
| `ubi-byoh-template` | 2     | 2 GB    | ~2 GB   | default  | no          | template only, never run |
| `ubi-byoh-ctrl`     | 2     | 4 GB    | 40 GB   | default  | no          | user-space only        |
| `ubi-byoh-data`     | **8** | **24 GB**| **120 GB** | **host** | **yes**   | runs nested VMs        |

You can shrink the data plane to `4 vCPU / 16 GB / 80 GB` for a
1-VM test. Don't go below that.

---

# Part 4 — Build it (Steps 1-14)

Set these variables in your Proxmox host shell. All `qm` commands
below reference them:

```bash
# === RUN ON: Proxmox host, as root ===
VMID_TMPL=9000
VMID_CTRL=101
VMID_DATA=102
STORAGE=local-lvm                 # from Step 0.5
BRIDGE_UPLINK=vmbr0               # your existing LAN bridge
BRIDGE_BYOH=vmbr1                 # the new internal bridge
LAPTOP_PUBKEY="$HOME/.ssh/id_ed25519.pub"   # your laptop's key, copy
                                            # to /root/.ssh on Proxmox first
                                            # if it isn't already there
```

Verify the variables stuck:

```bash
# === RUN ON: Proxmox host, as root ===
echo "TMPL=$VMID_TMPL CTRL=$VMID_CTRL DATA=$VMID_DATA STORAGE=$STORAGE"
ls -la "$LAPTOP_PUBKEY"
```

If `$LAPTOP_PUBKEY` doesn't exist on the Proxmox host yet, copy it
there from your laptop first:

```bash
# === RUN ON: your laptop ===
scp ~/.ssh/id_ed25519.pub root@192.168.1.50:/root/.ssh/laptop_pub.pub
```

Then on the Proxmox host:

```bash
# === RUN ON: Proxmox host, as root ===
LAPTOP_PUBKEY="/root/.ssh/laptop_pub.pub"
```

**(If you don't have an SSH keypair on your laptop yet, generate
one first**:

```bash
# === RUN ON: your laptop ===
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
```

This is the "SSH key to log into VMs from your laptop" that you'll
re-use throughout the whole guide.)

## Step 1 — Enable nested virt on the Proxmox host

You already checked the current state in Step 0.3.

**If it printed `Y` or `1` already**: skip ahead to Step 2.

**If it printed `N` or `0`**: enable it now.

```bash
# === RUN ON: Proxmox host, as root ===
# On Intel:
echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf

# On AMD:
echo "options kvm-amd nested=1" > /etc/modprobe.d/kvm-amd.conf

# Rebuild initramfs so the option survives reboots
update-initramfs -u -k all
```

Then either reboot, or hot-reload the module **if no VMs are
currently running**:

```bash
# === RUN ON: Proxmox host, as root ===
modprobe -r kvm_intel       # or kvm_amd
modprobe kvm_intel
```

Verify:

```bash
# === RUN ON: Proxmox host, as root ===
cat /sys/module/kvm_intel/parameters/nested
```

Must print `Y`. If you can't reload (running VMs blocking it),
just `reboot` — the modprobe option will take effect on next boot.

## Step 2 — Create a BYOH bridge

```bash
# === RUN ON: Proxmox host, as root ===
cat >> /etc/network/interfaces <<EOF

auto vmbr1
iface vmbr1 inet static
    address 10.98.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Ubicloud BYOH internal bridge
EOF

ifreload -a
```

Verify the bridge is up:

```bash
# === RUN ON: Proxmox host, as root ===
ip -brief addr show vmbr1
```

Expected:

```
vmbr1            UP             10.98.1.1/24
```

If it says `DOWN` or doesn't exist, run `systemctl restart networking`
or, if that fails, edit via the web UI: **Datacenter → node →
System → Network → Create → Linux Bridge**, then click **Apply
Configuration** at the top.

## Step 3 — Download the Ubuntu cloud image

```bash
# === RUN ON: Proxmox host, as root ===
cd /var/lib/vz/template/iso
wget -nc https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
ls -lh noble-server-cloudimg-amd64.img
```

Expected: ~660 MB qcow2 file.

**What this is**: the official Ubuntu 24.04 cloud image — already
installed, cloud-init enabled, ready to be cloned and configured at
boot. Same image AWS uses for its Ubuntu AMIs.

## Step 4 — Create the VM template

```bash
# === RUN ON: Proxmox host, as root ===
qm create $VMID_TMPL \
    --name ubi-byoh-template \
    --memory 2048 --cores 2 --sockets 1 \
    --net0 virtio,bridge=$BRIDGE_BYOH \
    --serial0 socket --vga serial0 \
    --agent enabled=1 --ostype l26

qm importdisk $VMID_TMPL \
    /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
    $STORAGE

qm set $VMID_TMPL --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID_TMPL-disk-0
qm set $VMID_TMPL --boot c --bootdisk scsi0
qm set $VMID_TMPL --ide2 $STORAGE:cloudinit
qm template $VMID_TMPL
```

Verify:

```bash
# === RUN ON: Proxmox host, as root ===
qm list | grep $VMID_TMPL
qm config $VMID_TMPL | grep -E '^(name|cores|memory|cpu|net0|scsi0|ide2|template)'
```

Expected: VMID 9000 listed, status `stopped`, marked as a template.

## Step 5 — Create the control plane VM

```bash
# === RUN ON: Proxmox host, as root ===
qm clone $VMID_TMPL $VMID_CTRL --name ubi-byoh-ctrl --full

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

qm resize $VMID_CTRL scsi0 +38G
qm start $VMID_CTRL
```

Wait ~45 seconds for first boot (cloud-init applies the SSH key,
network config, then reboots).

**Verify the VM came up correctly:**

```bash
# === RUN ON: Proxmox host, as root ===
sleep 60
qm status $VMID_CTRL
qm guest cmd $VMID_CTRL network-get-interfaces 2>/dev/null | grep -A1 'ip-address' | head -20
```

The second command should print 2 IPs (besides 127.0.0.1):
- `10.98.1.10` (the static internal-bridge IP)
- something like `192.168.1.153` (the LAN DHCP IP)

**Write down the LAN DHCP IP** — that's where you'll SSH from your
laptop in Step 8.

**Verify SSH from your laptop**:

```bash
# === RUN ON: your laptop ===
ssh ubuntu@192.168.1.153    # substitute your actual LAN DHCP IP
hostname
exit
```

Expected: drops you into a shell as `ubuntu`, `hostname` prints
`ubi-byoh-ctrl`, then exit returns you to your laptop.

If SSH hangs or refuses: open the Proxmox web UI **ubi-byoh-ctrl →
Console**, log in as `ubuntu`, look for cloud-init errors via
`sudo cat /var/log/cloud-init-output.log | tail -50`. Most common
issue: `--sshkeys` path didn't exist or was unreadable when you ran
`qm set`. Re-run `qm set ... --sshkeys ...` with a correct path,
then `qm reboot $VMID_CTRL`.

## Step 6 — Create the data plane VM

```bash
# === RUN ON: Proxmox host, as root ===
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

qm resize $VMID_DATA scsi0 +118G
qm start $VMID_DATA
```

The **`--cpu host`** flag is the critical one. It tells Proxmox to
pass through all CPU features (including VT-x/SVM) to this guest.
Without it, even with the host's `nested=Y` flag, the data plane
will not see `/dev/kvm`.

Verify the data plane came up and got an IP:

```bash
# === RUN ON: Proxmox host, as root ===
sleep 60
qm status $VMID_DATA
qm config $VMID_DATA | grep '^cpu:'
qm guest cmd $VMID_DATA network-get-interfaces 2>/dev/null | grep -A1 'ip-address' | head -20
```

Expected:
- `qm status` → `status: running`
- `qm config | grep '^cpu:'` → `cpu: host` (must say "host")
- `qm guest cmd` → 2 IPs: `10.98.1.20` and a LAN DHCP IP

**Write down the LAN DHCP IP** for the data plane.

## Step 7 — First-boot smoke test (nested-KVM check)

**Do not skip this step.** It's the single highest-leverage sanity
check in the whole doc. If nested virt is broken, every subsequent
step appears to succeed but the final VM creation fails with a
confusing error 90 minutes from now.

SSH into the data plane from your laptop:

```bash
# === RUN ON: your laptop ===
ssh ubuntu@<data-plane-LAN-ip>
```

Now you're inside the data plane VM. Run all 3 of these checks:

```bash
# === RUN ON: ubi-byoh-data, as ubuntu ===

# Check 1: /dev/kvm must exist
ls -l /dev/kvm
# Expected: crw-rw---- 1 root kvm 10, 232 ... /dev/kvm
# If "No such file": nested virt is NOT working. STOP. See below.

# Check 2: CPU virt flags must be visible to the guest kernel
grep -c -E 'vmx|svm' /proc/cpuinfo
# Expected: same as your --cores (e.g. 8)
# If 0: same problem.

# Check 3: KVM kernel module loads cleanly
sudo modprobe kvm_intel    # or kvm_amd
lsmod | grep kvm
# Expected: kvm_intel and kvm modules listed, no errors
```

**If any check fails**: stop here, fix it, re-test. Likely causes:

1. `--cpu host` not set on the data plane VM. Verify with
   `qm config $VMID_DATA | grep '^cpu:'` from the Proxmox host. Fix:
   `qm stop $VMID_DATA && qm set $VMID_DATA --cpu host && qm start $VMID_DATA`.
2. `nested=Y` not active on the Proxmox host. Re-do Step 1 and reboot
   the host.
3. CPU doesn't actually support nested virt (rare on hardware made
   after 2014). Check `grep -E 'vmx|svm' /proc/cpuinfo` on the
   Proxmox host.

When all 3 checks pass, exit the data plane SSH and continue:

```bash
# === RUN ON: ubi-byoh-data, as ubuntu ===
exit
# (back on your laptop)
```

## Step 8 — Bootstrap the control plane

This installs Ruby + Node + Postgres + clones the Ubicloud repo +
runs migrations + starts Puma and respirate. Run from inside the
ctrl plane VM.

```bash
# === RUN ON: your laptop ===
ssh ubuntu@<ctrl-plane-LAN-ip>
```

Now you're inside the ctrl plane VM. Run:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
curl -sSL https://raw.githubusercontent.com/NameawaShinderu/ubicloud-byoh/byoh-driver/scripts/byoh/bootstrap-ctrl-plane.sh | bash
```

This kicks off the same script the AWS path uses. Expected
runtime: **8-15 minutes**. The Ruby compile step dominates.

You'll see progress for 11 numbered phases. Each phase touches a
marker file in `~/.ubi-bootstrap/` so the script is idempotent — if
it fails partway through, fix the cause and re-run the same
`curl | bash` and it picks up where it left off.

**What "done" looks like** — final lines:

```
━━━━━ 11. Start services in tmux ━━━━━
  started: puma (ctrl-plane-puma session)
  started: respirate (ctrl-plane-respirate session)

✓ Control plane bootstrap complete.

Next: run bin/register-byoh-host
```

**Verify it worked** (the most important checks):

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===

# 1. The repo was cloned
ls -la ~/ubicloud
# Expected: a directory full of Ruby/Roda code. Should see
# bin/, lib/, model/, prog/, rhizome/, scripts/, etc.

# 2. The branch is correct
cd ~/ubicloud
git branch
# Expected: * byoh-driver

# 3. Ruby is installed and working
ruby --version
# Expected: ruby 4.0.2 ...
which ruby
# Expected: /home/ubuntu/.local/share/mise/installs/ruby/4.0.2/bin/ruby

# 4. Postgres is running and the DB exists
sudo -u postgres psql -l | grep clover_test
# Expected: clover_test row

# 5. Migrations have run (check that some tables exist)
sudo -u postgres psql clover_test -c "\dt" | head
# Expected: lots of tables (account, project, vm, etc.)

# 6. Both background services are running in tmux
tmux ls
# Expected:
#   ctrl-plane-puma:      1 windows ...
#   ctrl-plane-respirate: 1 windows ...

# 7. Puma is responding on port 3000
curl -sI http://localhost:3000/ | head -1
# Expected: HTTP/1.1 302 Found

# 8. The web UI is reachable from your laptop's LAN IP too
curl -sI http://10.98.1.10:3000/ | head -1
# Expected: HTTP/1.1 302 Found
```

If any check fails, the bootstrap didn't complete. The most common
issue is a single phase failing; re-run the bootstrap and look at
which phase errors.

### Step 8a — What the bootstrap script actually does (transparency)

If you don't trust `curl pipe bash` (and you shouldn't blindly), here
is exactly what the script does, broken into the 11 phases. Reading
this is enough to understand it; you don't have to run any of it.

```bash
# Phase 1: install Ubuntu apt packages
sudo apt-get update
sudo apt-get install -y \
    git build-essential curl tmux jq \
    libpq-dev libyaml-dev libssl-dev libffi-dev libreadline-dev \
    zlib1g-dev libncurses-dev libedit-dev libxml2-dev libxslt1-dev \
    pkg-config \
    postgresql-16 postgresql-client-16 postgresql-contrib-16

# Phase 2: install mise (a polyglot version manager) into ~/.local
curl -fsSL https://mise.run | sh

# Phase 3: install Ruby 4.0.2 (compiles from source, takes ~3 min)
~/.local/bin/mise install ruby@4.0.2
~/.local/bin/mise use --global ruby@4.0.2

# Phase 4: install Node.js 24
~/.local/bin/mise install node@24.12.0
~/.local/bin/mise use --global node@24.12.0

# Phase 5: clone the Ubicloud repo (THE EXPLICIT GIT CLONE!)
cd ~
git clone https://github.com/NameawaShinderu/ubicloud-byoh.git ubicloud
cd ubicloud
git checkout byoh-driver

# Phase 6: configure Postgres
sudo -u postgres psql -c "CREATE ROLE ubuntu WITH LOGIN SUPERUSER;"
sudo -u postgres createdb -O ubuntu clover_test
# (also patches /etc/postgresql/16/main/pg_hba.conf to use 'trust' for local)
sudo systemctl restart postgresql

# Phase 7: install Ruby gems
cd ~/ubicloud
bundle install

# Phase 8: build web UI assets
npm install
npm run prod

# Phase 9: write .env.rb with a dev secret
cat > ~/ubicloud/.env.rb <<'EOF'
ENV["CLOVER_SESSION_SECRET"] = "dev-secret-not-for-prod-..."
ENV["RACK_ENV"] = "development"
EOF

# Phase 10: run database migrations
cd ~/ubicloud
bundle exec rake db:migrate

# Phase 11: start Puma + respirate in tmux
tmux new-session -d -s ctrl-plane-puma  "cd ~/ubicloud && bundle exec puma -p 3000"
tmux new-session -d -s ctrl-plane-respirate  "cd ~/ubicloud && bundle exec ruby bin/respirate"
```

That's the entire bootstrap. The script you `curl | bash`'d does
each phase with idempotency markers and slightly more error handling,
but the substance is exactly the above. **Phase 5 is where the
Ubicloud repo gets cloned to `~/ubicloud` on the ctrl plane VM.**

### Step 8b — Manual install path (if you don't want curl pipe bash)

If you'd rather paste the steps yourself instead of running a script
you don't trust:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===

# 1. Apt packages
sudo apt-get update
sudo apt-get install -y \
    git build-essential curl tmux jq \
    libpq-dev libyaml-dev libssl-dev libffi-dev libreadline-dev \
    zlib1g-dev libncurses-dev libedit-dev libxml2-dev libxslt1-dev \
    pkg-config \
    postgresql-16 postgresql-client-16 postgresql-contrib-16

# 2. Install mise
curl -fsSL https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc

# 3. Install Ruby + Node via mise
mise install ruby@4.0.2 node@24.12.0
mise use --global ruby@4.0.2 node@24.12.0

# 4. Clone the Ubicloud repo
cd ~
git clone https://github.com/NameawaShinderu/ubicloud-byoh.git ubicloud
cd ubicloud
git checkout byoh-driver
git log --oneline -3       # sanity check: see recent commits

# 5. Configure Postgres
sudo -u postgres psql -c "CREATE ROLE ubuntu WITH LOGIN SUPERUSER;"
sudo -u postgres createdb -O ubuntu clover_test
sudo sed -i 's|local   all             all                                     peer|local   all             all                                     trust|' \
    /etc/postgresql/16/main/pg_hba.conf
sudo sed -i 's|host    all             all             127.0.0.1/32            scram-sha-256|host    all             all             127.0.0.1/32            trust|' \
    /etc/postgresql/16/main/pg_hba.conf
sudo systemctl restart postgresql

# 6. Install Ruby + JS deps
cd ~/ubicloud
bundle install
npm install
npm run prod

# 7. Generate .env.rb
cat > ~/ubicloud/.env.rb <<'EOF'
ENV["CLOVER_SESSION_SECRET"] = "$(openssl rand -hex 32)"
ENV["RACK_ENV"] = "development"
EOF

# 8. Run DB migrations
cd ~/ubicloud
bundle exec rake db:migrate

# 9. Start services in tmux
tmux new-session -d -s ctrl-plane-puma 'cd ~/ubicloud && bundle exec puma -p 3000'
tmux new-session -d -s ctrl-plane-respirate 'cd ~/ubicloud && bundle exec ruby bin/respirate'

# 10. Verify
curl -sI http://localhost:3000/ | head -1   # HTTP/1.1 302 Found
tmux ls                                      # both sessions running
```

This is functionally identical to the curl|bash path; the script
just adds idempotency markers under `~/.ubi-bootstrap/` so partial
failures resume cleanly.

## Step 8.5 — Tour the Ubicloud repo on the ctrl plane

Now that the repo is cloned, get oriented. **Skim this section**, you
don't have to run anything — it's a guided tour of what's on disk so
you know where to look later.

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
cd ~/ubicloud
ls
```

Top-level directories of interest:

| Directory       | What's in it                                                                      |
|-----------------|------------------------------------------------------------------------------------|
| `bin/`          | CLI entry points, including `register-byoh-host` (Step 11) and `respirate` (the dispatcher) |
| `lib/hosting/`  | Provider drivers — `hetzner_apis.rb`, `generic_apis.rb` (BYOH), `base.rb`, `apis.rb` factory |
| `lib/byoh_registration.rb` | The Ruby class `register-byoh-host` calls into                          |
| `model/`        | Sequel ORM models — `host_provider.rb`, `vm_host.rb`, `address.rb`, `location.rb`, etc. |
| `prog/`         | State machine programs ("strands") — `prog/vm/host_nexus.rb` is the host-bringup state machine that runs in Step 12 |
| `rhizome/`      | The on-host agent that gets shipped to the data plane during host bootstrap. Pure Ruby + shell. |
| `migrate/`      | Sequel database migrations                                                        |
| `scripts/byoh/` | The bootstrap scripts (`bootstrap-ctrl-plane.sh`, `bootstrap-data-plane.sh`)      |
| `terraform/aws-byoh/` | The Terraform module for the AWS-Console doc                              |
| `docs/byoh/`    | This doc + the AWS doc                                                            |
| `spec/`         | RSpec tests                                                                       |
| `config.rb`     | Top-level config (DB URL, secrets, port)                                          |
| `clover.rb`     | Roda routing entry point for the web UI                                           |

**Key files to know about** (you may need to read or modify these
later):

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===

# The BYOH driver itself — implements pull_ips, ssh_credentials, etc.
less ~/ubicloud/lib/hosting/generic_apis.rb

# The state machine that runs during host bringup (Step 12)
less ~/ubicloud/prog/vm/host_nexus.rb

# The CLI you'll run in Step 11
less ~/ubicloud/bin/register-byoh-host

# The .env.rb generated by the bootstrap
cat ~/ubicloud/.env.rb
```

You don't need to understand all of this. It's a map for when
something breaks and the troubleshooting section says "look at file
X" — you'll know where to find it.

## Step 9 — Generate the ctrl→data SSH key

Inside the ctrl plane, generate a new SSH keypair. This key will be
used by the Ubicloud control plane (specifically `respirate`) to
SSH into the data plane as `root` for all provisioning operations.
**It lives only on the ctrl plane.** Your laptop never sees it.

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
ssh-keygen -t ed25519 -f ~/.ssh/byoh_data -N '' -C 'ubi-byoh ctrl-to-data'
ls -la ~/.ssh/byoh_data ~/.ssh/byoh_data.pub
cat ~/.ssh/byoh_data.pub
```

Expected: a single line of output ending with the comment
`ubi-byoh ctrl-to-data`, like:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIXXXXXXXXXXXXX ubi-byoh ctrl-to-data
```

**Select that entire line and copy it** — you'll paste it into the
data plane's `/root/.ssh/authorized_keys` in the next step.

## Step 10 — Install the key on the data plane

The public key from Step 9 needs to land in `/root/.ssh/authorized_keys`
on the data plane VM. Three ways — pick whichever fits.

### Way A — From the ctrl plane shell (cleanest)

You're already SSHed into the ctrl plane. The cloud-init in Step 6
installed your laptop's public key into the data plane's
`ubuntu` user, so the ctrl plane can SSH to the data plane as
`ubuntu` if it has your laptop's key in agent forwarding... but
that's fragile. Easier: do it from the ctrl plane VM directly via
the data plane's `ubuntu` user, but the data plane's `ubuntu`
user only trusts your laptop's key, not the ctrl plane's local
keys. So **Way A only works if you forwarded your SSH agent**
when you SSHed from laptop → ctrl plane.

If you did `ssh -A ubuntu@<ctrl-LAN-ip>` from your laptop:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
PUBKEY="$(cat ~/.ssh/byoh_data.pub)"
ssh -o StrictHostKeyChecking=no ubuntu@10.98.1.20 \
    "sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh && \
     echo '$PUBKEY' | sudo tee -a /root/.ssh/authorized_keys >/dev/null && \
     sudo chmod 600 /root/.ssh/authorized_keys"
```

If it works, skip to "Test the SSH" below.

### Way B — From a separate SSH session to the data plane

Open a **new terminal** on your laptop (keep the ctrl plane SSH
session in the first terminal):

```bash
# === RUN ON: your laptop (NEW terminal) ===
ssh ubuntu@<data-plane-LAN-ip>
```

You're now in the data plane VM. Paste the public key:

```bash
# === RUN ON: ubi-byoh-data, as ubuntu ===
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh

# Replace the line below with the actual key from Step 9
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIXXXX...XXXX ubi-byoh ctrl-to-data' \
    | sudo tee -a /root/.ssh/authorized_keys >/dev/null

sudo chmod 600 /root/.ssh/authorized_keys
sudo cat /root/.ssh/authorized_keys      # verify the key is there
```

You can leave this terminal open or `exit` — you won't need it
again until Step 12 if you need to debug.

### Way C — Via the Proxmox web UI Console

If you don't want to use SSH at all for this:

1. Open Proxmox web UI → `ubi-byoh-data` → **Console**
2. Log in as `ubuntu` (no password — it's empty in cloud images
   and only key login works for SSH; the console bypasses that)
3. Run the same commands as Way B inside the noVNC console

### Test the SSH from ctrl to data

Back on the ctrl plane (the original SSH session), test the new key:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
ssh -i ~/.ssh/byoh_data -o StrictHostKeyChecking=no \
    root@10.98.1.20 'hostname && uname -r && ls /dev/kvm'
```

Expected output:

```
ubi-byoh-data
6.8.0-38-generic
/dev/kvm
```

If you get this, you're golden:
- The ctrl plane can SSH to the data plane as root using `byoh_data`.
- Nested KVM is still working (Step 7 wasn't a fluke).

If you get "Permission denied (publickey)": the key in
`authorized_keys` doesn't match. Run `sudo cat
/root/.ssh/authorized_keys` on the data plane and compare it to
`cat ~/.ssh/byoh_data.pub` on the ctrl plane — they must match
character for character. Common error: extra whitespace, line break
in the middle, or you accidentally pasted the **private** key
(starts with `-----BEGIN OPENSSH PRIVATE KEY-----`).

If `ls /dev/kvm` fails: Step 7 regressed somehow. Stop, fix nested
virt, retry. Don't proceed to Step 11 without `/dev/kvm` working.

## Step 11 — Register the BYOH host

This is the moment Ubicloud actually learns about your Proxmox-hosted
data plane. It writes rows to the `host_provider`, `location`,
`sshable`, `vm_host`, and `address` tables, and queues a strand
(state machine instance) on the `respirate` dispatcher.

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
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
Queued Prog::Vm::HostNexus strand st-ABCD1234EFGH

Registration complete.
  vm_host ubid:  vh-XXXXX
  strand:        st-ABCD1234EFGH
```

**Write down the strand ID** (`st-ABCD1234EFGH`).

**Verify the registration via Postgres** (this is exactly what the
CLI did under the hood):

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
cd ~/ubicloud
bundle exec ruby -e '
  require_relative "model"
  puts "host_providers:"
  HostProvider.each { |hp| puts "  #{hp.provider_name} #{hp.server_identifier}" }
  puts
  puts "vm_hosts:"
  VmHost.each { |vh| puts "  #{vh.ubid} #{vh.location.name} sshable=#{vh.sshable.host}" }
  puts
  puts "queued strands:"
  Strand.where(prog: "Vm::HostNexus").each { |s| puts "  #{s.ubid} label=#{s.label}" }
'
```

Expected: 1 host_provider, 1 vm_host, 1 strand for HostNexus.

## Step 12 — Watch the host bootstrap strand

The strand from Step 11 is now being driven forward by `respirate`,
which is running in the `ctrl-plane-respirate` tmux session. It will
SSH into the data plane (using the `byoh_data` key from Step 10),
install rhizome, prep the host, build SPDK, download Ubuntu cloud
images, and finally mark the host as `accepting`.

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
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
' ST=st-ABCD1234EFGH
```

Substitute your strand ID. Expected progression (~6-10 minutes):

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

**While it's running, you can watch what it's doing on the data
plane in real time** in another terminal:

```bash
# === RUN ON: your laptop (separate terminal) ===
ssh ubuntu@<data-plane-LAN-ip>
```

```bash
# === RUN ON: ubi-byoh-data, as ubuntu ===
# Watch rhizome install itself
sudo tail -f /var/log/ubi-rhizome/*.log 2>/dev/null

# Or watch SPDK come up
sudo journalctl -u ubi-spdk.service -f
```

Detach from tail with Ctrl+C.

**Verify final state when it finishes:**

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
cd ~/ubicloud
bundle exec ruby -e '
  require_relative "model"
  vh = VmHost.first
  puts "vm_host:"
  puts "  ubid:               #{vh.ubid}"
  puts "  allocation_state:   #{vh.allocation_state}"
  puts "  total_cores:        #{vh.total_cores}"
  puts "  total_hugepages:    #{vh.total_hugepages_1g}"
  puts "  net6:               #{vh.net6}"
'
```

Expected:
- `allocation_state: accepting` ← **this is the magic word**. If you
  see it, the host is fully ready to receive VM workloads.
- `total_cores`, `total_hugepages_1g` populated with non-zero numbers
- `net6` set to whatever the data plane learned from `learn_network`

If `allocation_state` is still `unprepared`, the strand is either
still running or it errored out. Look at it:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
tmux attach -t ctrl-plane-respirate
# Look for stack traces or error messages in the live output
# Detach with Ctrl+B then d
```

## Step 13 — Open the web UI and create your first VM

```bash
# === RUN ON: your laptop ===
# Open in your browser:
open http://<ctrl-plane-LAN-ip>:3000/
# (or just paste the URL into the browser's address bar)
```

Where `<ctrl-plane-LAN-ip>` is the DHCP-assigned IP of the ctrl
plane (from Step 5 verification).

**First-time setup**:

1. You'll be redirected to `/login`. Click **Create account**.
2. Fill in email, name, password. Click **Create account**.
3. The verification link is printed to the Puma log (dev mode).
   Find it:
   ```bash
   # === RUN ON: ubi-byoh-ctrl, as ubuntu ===
   tmux attach -t ctrl-plane-puma
   # Use Ctrl+B then [ to enter scrollback mode, Ctrl+S to search
   # for "/verify/", note the URL, then Ctrl+B then d to detach
   ```
4. In your browser, navigate to
   `http://<ctrl-plane-LAN-ip>:3000/verify/abc123` (substitute the
   actual token). Click confirm.
5. Log in with the email + password you set.
6. Create a project (any name, e.g. "homelab").

**Upload your laptop's SSH public key to the UI** (this goes inside
the VM you're about to create, so you can SSH into it):

1. Sidebar → **SSH keys** → **Create SSH key**
2. Name: `my-laptop`
3. Public key: paste the contents of `~/.ssh/id_ed25519.pub` from
   your laptop
4. **Create**

**Create a VM**:

1. Sidebar → **Virtual machines** → **Create virtual machine**
2. Fields:
    - **Location**: `proxmox-homelab` (from Step 11)
    - **Name**: `test-vm`
    - **Size**: `standard-2`
    - **Boot image**: `ubuntu-noble`
    - **SSH keys**: ✓ `my-laptop`
    - **Private subnet**: "Create new"
3. Click **Create virtual machine**

You'll land on the VM detail page. Watch it transition through
states: `start` → `allocate_vm` → `prep` → `clone_ip` → `download` →
`start_after_host_reboot` → `wait_sshable` → `running`.

**First VM takes ~3-4 minutes**. Subsequent VMs are faster.

**Verify VM is alive on the data plane**:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
ssh -i ~/.ssh/byoh_data root@10.98.1.20 'pgrep -a cloud-hypervisor'
```

Expected: a process named `cloud-hypervisor` with the VM's UBID in
its arguments.

## Step 14 — SSH into your VM

The VM detail page shows its **"Public IPv4"** field. With Option A
networking it's something like `10.98.1.128`.

This IP is on the `vmbr1` internal bridge — reachable from the ctrl
plane and the Proxmox host directly, but **not reachable from your
laptop** without one of these workarounds:

### Way A — Jump host through the ctrl plane (no router config)

```bash
# === RUN ON: your laptop ===
ssh -J ubuntu@<ctrl-plane-LAN-ip> ubi@10.98.1.128
```

The `-J` (ProxyJump) flag tells SSH to first connect to the ctrl
plane (where your laptop key is in the `ubuntu` user's
`authorized_keys`), then from there hop to `10.98.1.128` as the
**`ubi`** user. Note the username: it's `ubi`, not `ubuntu` and not
`root`. Ubicloud VMs use `ubi` as the default unix user.

### Way B — Add a static route on your laptop

Permanent fix for "I want `ssh ubi@10.98.1.128` to just work from
my laptop":

```bash
# === RUN ON: your laptop (Linux) ===
sudo ip route add 10.98.1.0/24 via <ctrl-plane-LAN-ip>
```

```bash
# === RUN ON: your laptop (macOS) ===
sudo route -nv add -net 10.98.1.0/24 <ctrl-plane-LAN-ip>
```

```cmd
# === RUN ON: your laptop (Windows admin cmd) ===
route add 10.98.1.0 mask 255.255.255.0 <ctrl-plane-LAN-ip>
```

These don't survive reboots. To make them permanent, add the route
to your home router's static-route page instead.

### Way C — Use Tailscale (the cleanest answer)

See [Part 5 → Option D](#option-d--tailscale--wireguard-overlay).

**Once connected**:

```bash
# === RUN ON: a Ubicloud VM (10.98.1.128), as ubi ===
hostname
uname -a
sudo -i
# you have a working VM in your homelab cloud. Run anything.
```

End of happy path. **Congratulations — you have a fully functional
Ubicloud BYOH deployment on Proxmox.**

---

# Part 5 — Networking deep dive (4 options)

You did Option A in Part 4. This section covers the others. Skip
on first run.

## Option A — Private lab, LAN-only

Already done in Part 4. VMs at `10.98.1.128/.129/.130`, reachable
from ctrl plane and any machine with a route. No external setup.

## Option B — Router DNAT port forwarding

Same private VM IPs as Option A, plus your home router DNATs
specific external ports to specific VM IPs.

**Step B1** — Add a static route on your **home router** so it
knows how to reach `10.98.1.0/24`:
- Destination: `10.98.1.0`
- Netmask: `255.255.255.0`
- Gateway: `<Proxmox host LAN IP>`

**Step B2** — Enable IP forwarding on the **Proxmox host**:

```bash
# === RUN ON: Proxmox host, as root ===
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-byoh.conf
```

**Step B3** — Add a port-forward on your **home router** (e.g. for
SSH to one VM):
- External port: `2201` → Internal IP `10.98.1.128` port `22` TCP

Now `ssh -p 2201 ubi@<home-public-ip>` from anywhere lands on that
VM's sshd. Repeat per VM/port.

## Option C — Routed subnet from ISP

Your ISP statically routes a public /29 (e.g. `203.0.113.0/29`) to
your WAN IP. Each VM gets a real public IP, the web UI shows the
real IP (no NAT confusion), matches Hetzner/OVH/Equinix.

**Step C1** — Confirm with your ISP that the /29 is **routed**, not
broadcast-domain.

**Step C2** — Configure your **router** to forward the /29 to your
Proxmox host's LAN IP.

**Step C3** — Configure the **Proxmox host** to forward those
packets to the data plane VM:

```bash
# === RUN ON: Proxmox host, as root ===
sysctl -w net.ipv4.ip_forward=1
ip route add 203.0.113.0/29 via 10.98.1.20 dev vmbr1
# Make persistent:
cat >> /etc/network/interfaces.d/99-byoh-routing <<'EOF'
post-up ip route add 203.0.113.0/29 via 10.98.1.20 dev vmbr1
post-down ip route del 203.0.113.0/29 via 10.98.1.20 dev vmbr1
EOF
```

**Step C4** — De-register and re-register the host with the public
range:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
cd ~/ubicloud
# (delete the existing host first via DB or scripts/byoh-ops/)
./bin/register-byoh-host \
    --provider generic \
    --main-ip 10.98.1.20 \
    --routed-network 203.0.113.0/29 \
    --ssh-key ~/.ssh/byoh_data \
    --location homelab-public \
    --default-boot-image ubuntu-noble \
    --yes
```

Now created VMs have real public IPs. SSH from anywhere:
`ssh ubi@203.0.113.1`.

## Option D — Tailscale / WireGuard overlay

The simplest "I want to reach my VMs from anywhere" answer.

**Step D1** — Install Tailscale on the data plane:

```bash
# === RUN ON: ubi-byoh-data, as ubuntu ===
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up \
    --advertise-routes=10.98.1.0/24 \
    --accept-dns=false \
    --hostname=ubi-byoh-data
```

The command prints a URL — open it on your laptop to authenticate.

**Step D2** — In the Tailscale admin panel
(https://login.tailscale.com/admin), find the `ubi-byoh-data`
machine, **Edit route settings**, and **enable** the `10.98.1.0/24`
subnet route.

**Step D3** — Install Tailscale on your laptop too. Now from your
laptop:

```bash
# === RUN ON: your laptop ===
ssh ubi@10.98.1.128
```

This works **from anywhere on the internet**, encrypted via
WireGuard, no router config. The "10.98.1.x" IPs are private but
Tailscale subnet routing makes them reachable on your tailnet.

---

# Part 6 — Operations

## Reference card: how to check things on each plane

When something's broken, you need to know where to look. This is
the "what to check, where" card.

### On the Proxmox host

```bash
# === RUN ON: Proxmox host, as root ===

# All VMs and their state
qm list

# Full config for a VM
qm config $VMID_DATA

# Live status (memory, CPU, disk, network)
qm monitor $VMID_DATA info status

# Network bridges
ip -brief addr show
brctl show

# Storage pool usage
pvesm status

# Nested virt status
cat /sys/module/kvm_intel/parameters/nested

# All running KVM processes
ps -ef | grep kvm | grep -v grep
```

### On the ctrl plane VM

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===

# Both background services
tmux ls

# Live Puma logs (web UI access logs, errors)
tmux attach -t ctrl-plane-puma
# detach: Ctrl+B then d

# Live respirate logs (state machine progress)
tmux attach -t ctrl-plane-respirate
# detach: Ctrl+B then d

# Postgres health
sudo systemctl status postgresql
sudo -u postgres psql clover_test -c "SELECT count(*) FROM strand;"

# The Ubicloud repo
cd ~/ubicloud
git status
git log --oneline -5

# Web UI from the ctrl plane itself
curl -sI http://localhost:3000/

# Query DB state of all hosts
bundle exec ruby -e '
  require_relative "model"
  VmHost.each { |h|
    puts "vh=#{h.ubid} state=#{h.allocation_state} cores=#{h.total_cores}"
  }
'

# Watch a strand
bundle exec ruby -e '
  require_relative "model"
  Strand.where(prog: "Vm::HostNexus").each { |s|
    puts "#{s.ubid} label=#{s.label} exitval=#{s.exitval}"
  }
'

# Test SSH from ctrl to data
ssh -i ~/.ssh/byoh_data root@10.98.1.20 'hostname'
```

### On the data plane VM

```bash
# === RUN ON: ubi-byoh-data, as root (or ubuntu + sudo) ===

# rhizome agent files
ls /opt/rhizome-host
sudo cat /var/log/ubi-rhizome/*.log

# SPDK service
sudo systemctl status ubi-spdk.service
sudo journalctl -u ubi-spdk.service -n 50 --no-pager

# vhost backend service
sudo systemctl status ubi-vhost-backend.service

# Hugepages
cat /proc/meminfo | grep Huge
ls /sys/kernel/mm/hugepages/

# Active VMs (cloud-hypervisor processes)
sudo pgrep -a cloud-hypervisor

# Per-VM directories (logs, sockets, configs)
ls /var/storage/vms/ 2>/dev/null

# Per-VM netns
sudo ip netns list

# /dev/kvm sanity
ls -l /dev/kvm
sudo modprobe kvm_intel && lsmod | grep kvm

# Boot images downloaded by Ubicloud
ls /var/storage/images/

# Disk usage on /var/storage
df -h /var/storage 2>/dev/null || df -h /
```

### From your laptop

```bash
# === RUN ON: your laptop ===

# Web UI (replace with your ctrl plane LAN IP)
curl -sI http://192.168.1.153:3000/
open http://192.168.1.153:3000/

# SSH to ctrl plane
ssh ubuntu@192.168.1.153

# SSH to data plane (LAN-side)
ssh ubuntu@192.168.1.154

# SSH to a created VM via ctrl plane jump host
ssh -J ubuntu@192.168.1.153 ubi@10.98.1.128

# Or with a static route in place
ssh ubi@10.98.1.128
```

---

## Troubleshooting

### `cat /sys/module/kvm_intel/parameters/nested` returns `N`

The modprobe option file isn't loaded yet, or doesn't exist.

```bash
# === RUN ON: Proxmox host, as root ===
ls /etc/modprobe.d/kvm-intel.conf 2>/dev/null   # should exist
cat /etc/modprobe.d/kvm-intel.conf              # should contain: options kvm-intel nested=Y
modprobe -r kvm_intel && modprobe kvm_intel    # may fail if VMs running
cat /sys/module/kvm_intel/parameters/nested     # must print Y now
```

If `modprobe -r` fails because of running VMs: `qm stop` them all
first, or just reboot the Proxmox host.

### `/dev/kvm` missing inside the data plane

```bash
# === RUN ON: Proxmox host, as root ===
qm config $VMID_DATA | grep '^cpu:'
# Must print: cpu: host
# If it says kvm64 or anything else, fix:
qm stop $VMID_DATA
qm set $VMID_DATA --cpu host
qm start $VMID_DATA
```

Then re-run the Step 7 smoke test inside the data plane.

### Cloud-init failed / VM has no network / SSH hangs first time

Open the Proxmox web UI **Console** for the VM. Look for cloud-init
errors. Most common causes:
- `--sshkeys` path didn't exist / wasn't readable when you ran `qm set`
- `--ipconfig0` had a typo (e.g. wrong gateway)

Fix and regenerate the cloud-init drive:

```bash
# === RUN ON: Proxmox host, as root ===
qm set $VMID_CTRL --ide2 $STORAGE:cloudinit
qm reboot $VMID_CTRL
```

### Bootstrap script fails on `bundle install`

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
cd ~/ubicloud
bundle install   # see the actual error

# Most common: missing native dep
sudo apt-get install -y libyaml-dev libffi-dev libpq-dev
bundle install
```

Then re-run the bootstrap script — it'll resume.

### Bootstrap script fails on Puma start

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
cd ~/ubicloud
bundle exec puma -p 3000     # run in foreground to see the error
# Common: missing .env.rb, port already in use, db migration not run
```

### Host strand stuck on `prep_host` for >10 minutes

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
ssh -i ~/.ssh/byoh_data root@10.98.1.20 'tail -100 /var/log/ubi-rhizome/*.log'
```

Most common: apt-get hitting a slow Ubuntu mirror. Wait it out
or restart the strand by deleting the marker and `respirate`
restarts it.

### Host strand stuck on `setup_spdk` for >15 minutes

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
ssh -i ~/.ssh/byoh_data root@10.98.1.20 \
    'sudo journalctl -u ubi-spdk.service -n 100 --no-pager'
```

Most common on Proxmox: hugepages couldn't be allocated. Bump the
data plane VM's memory and reboot.

### VM creation hangs at `wait_sshable`

```bash
# === RUN ON: ubi-byoh-data, as root (via ctrl plane) ===
sudo pgrep -a cloud-hypervisor      # is the VM process running?
ls /var/storage/vms/                # is the VM directory there?
sudo cat /var/storage/vms/<vm-ubid>/ch.log    # what's the VMM saying?
```

If `cloud-hypervisor` is missing: it crashed at start. Most likely
nested KVM is broken (regressed since Step 7 — usually because the
Proxmox host rebooted and `nested=Y` didn't persist).

### Web UI loads but login says "Email not verified"

In dev mode, verify links are printed to the Puma log:

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
tmux attach -t ctrl-plane-puma
# Ctrl+B then [, Ctrl+S, type "verify/", enter
# Copy the URL, navigate to it in your browser
```

### "Permission denied" SSHing from ctrl to data

```bash
# === RUN ON: ubi-byoh-data, as ubuntu (use the laptop key) ===
sudo cat /root/.ssh/authorized_keys
# Compare to the public key from ctrl plane:
```

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu ===
cat ~/.ssh/byoh_data.pub
# These two outputs must match character-for-character
```

If they don't: re-paste, watch for line breaks introduced by the
terminal/browser. Common error: pasting only a fragment.

---

## FAQ

### Q. Can I run ctrl and data on different Proxmox hosts?

Yes, and it's the more realistic production setup. Create
`ubi-byoh-ctrl` on host A and `ubi-byoh-data` on host B. The two
need to be able to reach each other — easiest is to put them on the
same LAN subnet and use LAN IPs as the `--main-ip`. Skip `vmbr1`
entirely.

### Q. Can I run the data plane on a physical Proxmox host directly (no nesting)?

Yes — and it's the most performant setup. But it means that physical
host becomes a dedicated Ubicloud node and you can't use it for
other VMs. Install Ubuntu 24.04 (not Proxmox) on the physical host
and register it directly from a separate ctrl plane.

### Q. Why does the data plane need 8 cores / 24 GB if my VMs are 2c/8g?

SPDK reserves 2-4 cores for polling threads + 2-4 GB for hugepages
before any VMs run. cloud-hypervisor overhead is ~1 GB per VM.
Ubicloud's Ruby agents take another ~1 GB. After all that, you have
~14 GB and ~5 cores left for actual VM workloads. Enough for 1
`standard-4` or 2 `standard-2`.

### Q. Performance vs real bare metal?

CPU: ~95% native. Memory: 100% native (after hugepage setup).
Network: 70-85% of line rate. Disk: 30-90% depending on storage
backing. Plain qcow2 on LVM-Thin is the slowest; PCI passthrough
NVMe (see below) is the fastest.

### Q. Can I snapshot the VMs and roll back?

Yes — unlike AWS bare metal:

```bash
# === RUN ON: Proxmox host, as root ===
qm snapshot $VMID_CTRL clean-bootstrap
qm snapshot $VMID_DATA clean-bootstrap

# Later:
qm rollback $VMID_CTRL clean-bootstrap
qm rollback $VMID_DATA clean-bootstrap
```

This is **the** killer feature for iterating on the BYOH driver
itself — snapshot after Step 8 finishes, every retest restarts from
the snapshot instead of waiting 15 min for bootstrap.

### Q. What username on the created VMs?

`ubi`. Not `ubuntu`, not `root`. Ubicloud uses `ubi` as the default
unix user inside guests.

### Q. Can I use the Proxmox firewall?

Yes. The default is "off". If you turn it on, allow:
- Inbound TCP 3000 to ctrl plane
- Inbound TCP 22 to ctrl plane (from your LAN, for SSH)
- All traffic between vmbr1 members
- All outbound from both VMs

---

## Performance tuning — PCI passthrough for NVMe

If you have a spare NVMe to dedicate to the data plane, this gives
you near-native disk performance.

**Step P1 — One-time host setup**:

```bash
# === RUN ON: Proxmox host, as root ===

# Enable IOMMU
sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT="quiet"|GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"|' /etc/default/grub
# (AMD: replace intel_iommu=on with amd_iommu=on)
update-grub

# Load VFIO modules at boot
cat > /etc/modules-load.d/vfio.conf <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF
update-initramfs -u -k all

# Blacklist nvme so Proxmox doesn't claim it
echo "blacklist nvme" >> /etc/modprobe.d/pve-blacklist.conf
update-initramfs -u -k all

reboot
```

**Step P2 — Bind VFIO to the device** (after reboot):

```bash
# === RUN ON: Proxmox host, as root ===
lspci -nn | grep -i nvme
# Note the BDF (e.g. 01:00.0) and the [vendor:device] (e.g. [144d:a809])

echo "options vfio-pci ids=144d:a809" > /etc/modprobe.d/vfio.conf
update-initramfs -u -k all
reboot
```

**Step P3 — Attach to the data plane**:

```bash
# === RUN ON: Proxmox host, as root ===
qm stop $VMID_DATA
qm set $VMID_DATA --hostpci0 01:00.0,pcie=1
qm start $VMID_DATA
```

**Step P4 — Inside the data plane, mount it**:

```bash
# === RUN ON: ubi-byoh-data, as root ===
lsblk
mkfs.ext4 -F /dev/nvme0n1
mkdir -p /var/storage
mount /dev/nvme0n1 /var/storage
echo '/dev/nvme0n1 /var/storage ext4 defaults 0 2' >> /etc/fstab
```

Now SPDK writes VM disks to real NVMe and nested VMs see ~80-90%
of bare-metal speed.

---

## Cleanup — tear it all down

```bash
# === RUN ON: Proxmox host, as root ===
qm stop $VMID_CTRL --skiplock
qm stop $VMID_DATA --skiplock
qm destroy $VMID_CTRL
qm destroy $VMID_DATA
qm destroy $VMID_TMPL

# Delete the BYOH bridge (edit /etc/network/interfaces and remove
# the vmbr1 stanza, or use the web UI: System → Network → vmbr1 → Remove)
ifreload -a

# (Optional) undo nested virt
rm /etc/modprobe.d/kvm-intel.conf
update-initramfs -u -k all
```

Verify:

```bash
# === RUN ON: Proxmox host, as root ===
qm list | grep -i ubi-byoh        # should print nothing
ip -br a | grep vmbr1             # should print nothing
```

---

# Appendix A — Command reference for the impatient

For people who've done this before. **Don't run blind** — read
Parts 2-3 first.

```bash
# === RUN ON: Proxmox host, as root ===
VMID_TMPL=9000
VMID_CTRL=101
VMID_DATA=102
STORAGE=local-lvm
BRIDGE_UPLINK=vmbr0
BRIDGE_BYOH=vmbr1
LAPTOP_PUBKEY="$HOME/.ssh/laptop_pub.pub"

# 1. Nested virt
echo "options kvm-intel nested=Y" > /etc/modprobe.d/kvm-intel.conf
modprobe -r kvm_intel && modprobe kvm_intel

# 2. BYOH bridge
cat >> /etc/network/interfaces <<EOF

auto $BRIDGE_BYOH
iface $BRIDGE_BYOH inet static
    address 10.98.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
ifreload -a

# 3. Cloud image
cd /var/lib/vz/template/iso
wget -nc https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# 4. Template
qm create $VMID_TMPL --name ubi-byoh-template --memory 2048 --cores 2 \
    --net0 virtio,bridge=$BRIDGE_BYOH --serial0 socket --vga serial0 \
    --agent enabled=1 --ostype l26
qm importdisk $VMID_TMPL /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img $STORAGE
qm set $VMID_TMPL --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID_TMPL-disk-0
qm set $VMID_TMPL --boot c --bootdisk scsi0 --ide2 $STORAGE:cloudinit
qm template $VMID_TMPL

# 5. Ctrl plane
qm clone $VMID_TMPL $VMID_CTRL --name ubi-byoh-ctrl --full
qm set $VMID_CTRL --cores 2 --memory 4096 \
    --net0 virtio,bridge=$BRIDGE_BYOH --net1 virtio,bridge=$BRIDGE_UPLINK \
    --ipconfig0 ip=10.98.1.10/24,gw=10.98.1.1 --ipconfig1 ip=dhcp \
    --sshkeys "$LAPTOP_PUBKEY" --ciuser ubuntu --cipassword '' --nameserver 1.1.1.1
qm resize $VMID_CTRL scsi0 +38G
qm start $VMID_CTRL

# 6. Data plane (with nested virt)
qm clone $VMID_TMPL $VMID_DATA --name ubi-byoh-data --full
qm set $VMID_DATA --cores 8 --memory 24576 --cpu host \
    --net0 virtio,bridge=$BRIDGE_BYOH --net1 virtio,bridge=$BRIDGE_UPLINK \
    --ipconfig0 ip=10.98.1.20/24,gw=10.98.1.1 --ipconfig1 ip=dhcp \
    --sshkeys "$LAPTOP_PUBKEY" --ciuser ubuntu --cipassword '' --nameserver 1.1.1.1
qm resize $VMID_DATA scsi0 +118G
qm start $VMID_DATA

# Wait, then print LAN IPs
sleep 60
qm guest cmd $VMID_CTRL network-get-interfaces 2>/dev/null | grep -A1 ip-address
qm guest cmd $VMID_DATA network-get-interfaces 2>/dev/null | grep -A1 ip-address
```

```bash
# === RUN ON: ubi-byoh-ctrl, as ubuntu (SSH in from your laptop first) ===

# 8. Bootstrap
curl -sSL https://raw.githubusercontent.com/NameawaShinderu/ubicloud-byoh/byoh-driver/scripts/byoh/bootstrap-ctrl-plane.sh | bash

# 9. Generate ctrl→data SSH key
ssh-keygen -t ed25519 -f ~/.ssh/byoh_data -N ''
PUBKEY="$(cat ~/.ssh/byoh_data.pub)"
echo "$PUBKEY"   # copy this for next step

# 10. Install on data plane (assumes laptop key is in ubuntu user already)
ssh ubuntu@10.98.1.20 "sudo mkdir -p /root/.ssh && \
  echo '$PUBKEY' | sudo tee -a /root/.ssh/authorized_keys >/dev/null && \
  sudo chmod 600 /root/.ssh/authorized_keys"

# 11. Verify
ssh -i ~/.ssh/byoh_data root@10.98.1.20 'hostname && ls /dev/kvm'

# 12. Register
cd ~/ubicloud
export RACK_ENV=development
./bin/register-byoh-host --provider generic --main-ip 10.98.1.20 \
    --routed-network 10.98.1.128/32 --routed-network 10.98.1.129/32 --routed-network 10.98.1.130/32 \
    --ssh-key ~/.ssh/byoh_data --location proxmox-homelab \
    --default-boot-image ubuntu-noble --yes
```

Then visit `http://<ctrl-LAN-ip>:3000/` in your browser.

---

# Appendix B — What the rhizome agent does on the data plane

Optional background reading for people who want to understand what
Ubicloud actually does to your data plane host.

`rhizome` is Ubicloud's on-host agent — the code that runs on the
data plane after the ctrl plane pushes it there. It lives at
`/opt/rhizome-host/` and has three jobs:

1. **Expose a small RPC surface over SSH** — the ctrl plane doesn't
   talk to rhizome via HTTP/gRPC. It literally runs
   `ssh root@10.98.1.20 'ruby /opt/rhizome-host/bin/execute.rb <command>'`
   for every operation. All state transitions are shell commands
   wrapped in Ruby.

2. **Manage the VM lifecycle** — cloud-hypervisor processes, tap
   devices, per-VM netns, nftables rules, SPDK bdev definitions for
   each VM disk.

3. **Enforce isolation** — each VM gets its own network namespace,
   filesystem, cgroup.

The reason the host bootstrap strand (Step 12) is slow is that
rhizome has to do all of this on a fresh host:
- Install kernel modules (vhost_vdpa, vhost_net)
- Configure sysctls (ip_forward, etc.)
- Compile and install SPDK from source
- Allocate hugepages
- Build & start systemd services
- Download Ubuntu boot images
- Final health check

Once done, the host is `accepting`. VM creation itself (Step 13) is
much faster because all the heavy setup is pre-baked.

**Why this matters**: if a strand stalls, you can SSH to the data
plane and run the same commands rhizome would. Logs are at
`/var/log/ubi-rhizome/*.log`, services are systemd units like
`ubi-spdk.service`. There's no magic — it's all shell commands in
Ruby scripts. Read them, debug them, fix them.

---

If you hit anything not covered here, open an issue at
https://github.com/NameawaShinderu/ubicloud-byoh/issues with:
- `pveversion` from the Proxmox host
- `qm config $VMID_DATA` for the data plane
- The ctrl-plane-respirate tmux log
- Relevant journalctl/log output from the data plane
