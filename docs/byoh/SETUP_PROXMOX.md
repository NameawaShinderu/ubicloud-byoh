# BYOH on Proxmox VE: a Proxmox VM as the data plane

This runbook turns a VM on a Proxmox VE node into a BYOH data plane, with the M2 network model: a real BYOH location, a `pools.yaml`, and IPv4 egress through the host NAT.

> **UNVERIFIED on Proxmox.** Nothing on this page has been run on Proxmox in this project. The same flow, with the same code, was validated only on AWS (ap-south-1, 2026-10-11 and 2026-10-13; see [VERIFY.md](VERIFY.md) §5). Every Proxmox-specific setting below is derived from the code and from [NETWORKING.md](NETWORKING.md) §9.2 and [PLATFORMS.md](PLATFORMS.md). Record what you find in VERIFY.md §5.

The driver code is the same on every platform. What differs on Proxmox is only the site work: the VM settings, the bridge, the router, and the shape of the pools.

**Superseded material.** The previous version of this page, `SETUP_PROXMOX_LOWTIER.md` and `docs/byoh/deploy-scripts/` predate M2. They pass `--provider` (which aborts), create no BYOH location, dual-home the data plane, and declare /32 pools that M2 treats as `routed`/`internal`. Do not use them.

---

## 0. Safety rules

Read these before you touch the node.

1. **Never run Ubicloud scripts on the Proxmox node itself.** Do not run `bootstrap-data-plane.sh` there, and never register the node as a host. Registration logs in as root and then:
   - deletes and recreates the `rhizome` user;
   - rewrites the sshd config;
   - allocates 1G hugepages;
   - flushes the nftables ruleset on every VM create and destroy (NH-6);
   - **reboots the machine**.

   The data plane is always a guest VM of its own.
2. **Never give the data plane a shared disk.** Do not pass through or attach SAN LUNs, Ceph RBD images used by anything else, ZFS zvols of other guests, or the node's own disks. Give it only its own virtual disks.
   - Storing the data plane's own virtual disk on Ceph or a SAN storage pool is fine; Proxmox manages that disk.
   - Rhizome keeps VM disks as files under `/var/storage` on the data plane's root filesystem. It does not format disks for generic hosts (`install_os` is false), but you must not mount anything shared there.
   - **Never mount a new disk over `/var/storage` after registration** (OPS-9).
3. **A company or shared Proxmox needs its owner's approval** before you change node settings, such as the nested virtualization module option or the firewall. Those changes affect every guest on the node.
4. **One data-plane VM per site at first.** Add more only after the gate (§9) passes.

---

## 1. What you build

```
            internet
               |
           [pfSense]  10.80.0.1        (any router works; pfSense is the example)
               |
   ----------- vmbr1  10.80.0.0/24 ------------------------------
      |                       |                      |
 data plane VM          control plane           office / VPN
 10.80.0.20 (ens18)     anywhere (§4)           clients
 pool 10.80.0.200/29    (needs SSH to 10.80.0.20)
   VMs answer through proxy_arp on ens18
```

| Piece | Where | Notes |
|---|---|---|
| Data plane | Proxmox VM, Ubuntu 24.04, nested KVM | One NIC on the LAN bridge |
| Control plane | Any Ubuntu 24.04 machine | On the LAN, or anywhere with a routed path to the data plane (C0, NETWORKING §4.5) |
| VM addresses | A pool on the LAN segment (`delivery: onlink`) | The data plane answers ARP for them with proxy_arp |
| VM exposure | `internal` (variant A) or `nat` through pfSense 1:1 NAT (variant B) | NETWORKING §9.2 |

The example values below come from NETWORKING §9.2: bridge `vmbr1`, LAN `10.80.0.0/24`, pfSense at `10.80.0.1`, data plane at `10.80.0.20`. Replace them with yours.

---

## 2. Proxmox node checks (read-only)

Run these as root on the Proxmox node. They change nothing.

```bash
pveversion
grep -cE 'vmx|svm' /proc/cpuinfo                 # > 0: VT-x or AMD-V present
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || cat /sys/module/kvm_amd/parameters/nested
                                                 # Y or 1: nested virtualization on
grep -m1 'model name' /proc/cpuinfo              # see the hybrid CPU note below
free -g; pvesm status                            # memory and storage headroom
```

- **Nested virtualization off.** Ask the node's owner to enable it: `options kvm-intel nested=Y` (or `options kvm-amd nested=1`) in `/etc/modprobe.d/`, then a node reboot. This affects every guest on the node.
- **Hybrid CPUs.** Intel 12th-14th gen and Core Ultra parts with P and E cores fail every VM with `BUG` (PLATFORMS.md HW-6/VR-3). Disable E-cores in the BIOS, or use another node.
- **SMT off (`nosmt`)** is not supported (PLATFORMS.md HW-7).

---

## 3. Create the data-plane VM

### 3.1 Settings

| Setting | Value | Why |
|---|---|---|
| CPU type | `host` | Passes `vmx`/`svm` and `pdpe1gb` (1G pages) to the guest. Without it there is no `/dev/kvm` and no 1G hugepages. |
| Cores | 8 recommended, 4 minimum (UNVERIFIED) | Rhizome reserves cores for the host. On AWS, 8 vCPU gave 4 usable cores and room for 2-3 `standard-2` VMs. |
| Memory | A **multiple of 1024 MiB**, 32768 recommended, 16384 minimum (UNVERIFIED) | Other sizes crash LearnMemory with "unexpected dmidecode unit" (OPS-16) on builds without a0259a997, which includes the published `byoh-driver`; `m2-network` rounds them down ([platforms/README.md](platforms/README.md) §3). Most of the memory becomes 1G hugepages for VMs; `verify_hugepages` needs MemAvailable of at least 2 GiB after that. On AWS, 32 GiB gave 26 hugepages. |
| Ballooning | Off (`balloon: 0`) | The guest's memory is pinned as 1G hugepages; a balloon would take it back. UNVERIFIED. |
| Disk | One `scsi0` disk on a `virtio-scsi-single` controller, on the VM's own storage, 200 GB or more | VM disks and boot images live on the root filesystem under `/var/storage`. Virtio and SCSI disks have no by-id links; IO limits fall back to the path [FIXED], but `bin/monitor` health checks do not (§4.3). |
| NIC | **One** NIC, `virtio`, on the LAN bridge, with **`firewall=0`** | Two NICs (vmbr0 DHCP plus a BYOH bridge, as the old docs had) give asymmetric egress, and G5 flags the second address. With the Proxmox firewall on, `ipfilter` or `macfilter` can drop proxy-ARP replies and VM-sourced packets (the default is UNVERIFIED). |
| Machine / BIOS | Defaults (i440fx or q35, SeaBIOS or OVMF) | Nothing in rhizome depends on them. UNVERIFIED for OVMF. The NIC is `ens18` on i440fx and `enp6s18` on q35; this page writes `ens18`. |
| OS | Ubuntu 24.04 LTS server or cloud image | Upstream accepts only 24.04 for slices (`accepts_slices`). |
| Network config | Static IP `10.80.0.20/24`, gateway `10.80.0.1`, set by cloud-init `ipconfig0` or the installer | Never put pool addresses on the NIC or in netplan (contract C5). |

### 3.2 Example commands

Run these on the Proxmox node as root. `9100` is a free VMID; `local-lvm` is your storage. They create only this VM.

- `import-from` needs Proxmox VE 7.2 or later. It works on every storage type (LVM-thin, ZFS, directory, NFS, Ceph), unlike a fixed volume name such as `$STORAGE:vm-$VMID-disk-0`, which exists only on block storage.
- `--sshkeys` installs the key you will log in with as `ubuntu`. If the control plane already has a key, you may put its public key here as well; §5 needs one of them.

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
qm set $VMID --ipconfig0 ip=10.80.0.20/24,gw=10.80.0.1 --nameserver 10.80.0.1 \
  --ciuser ubuntu --sshkeys ~/your_admin_key.pub
qm start $VMID
```

The node's own firewall settings stay as they are. `firewall=0` applies only to this NIC.

### 3.3 Check inside the VM

```bash
ssh ubuntu@10.80.0.20
ls -l /dev/kvm                                  # must exist
grep -c pdpe1gb /proc/cpuinfo                   # > 0
sudo dmidecode -t memory | grep -E '^\s+Size:'   # sizes in GB; MB means the memory is not a GiB multiple
ip -br -4 addr                                  # only lo and 10.80.0.20/24 on the NIC (ens18 or enp6s18)
curl -sI https://cloud-images.ubuntu.com >/dev/null && echo egress ok
```

---

## 4. Control plane

### 4.1 Where it runs

The control plane can run anywhere: a second VM on the same LAN, a VPS, or the existing AWS control plane. It needs:

| Need | Why |
|---|---|
| SSH (TCP 22) to the data plane's main IP | All host work goes over SSH as root (contract C0). If the control plane is off-site, the site must provide a routed path, such as a site-to-site VPN or WireGuard to pfSense. Ubicloud does not build that path yet (NETWORKING §4.5, OPEN). |
| HTTPS from users to port 3000 or a reverse proxy | Web UI and API |

Choose the location's `cp_reach` from where it runs:

| Control plane | `--cp-reach` | Effect |
|---|---|---|
| On the site LAN, or routed into it | `onhost` | `wait_sshable` dials each VM's pool address. |
| Elsewhere (only the host's management IP is routed to it) | `public` | Internet VMs are dialed at their external IP. `internal` VMs and VMs without IPv4 are probed from inside their namespace on the host instead (`byoh netns probe ok` in the respirate log). |

### 4.2 Bootstrap

This is the development bootstrap. For a packaged control plane use `scripts/byoh/install.sh` ([INSTALL.md](INSTALL.md)) and run the `bin/...` tools below as `sudo ubicloud-admin run <tool>` ([SETUP.md](SETUP.md) §4.3).

On a fresh Ubuntu 24.04 machine, as a sudo user (not root):

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
export PATH=$HOME/.local/bin:$HOME/.local/share/mise/installs/ruby/4.0.7/bin:$PATH
```

- The script writes `.env.rb` with `BILLING_RATES_EXTRA_DIR` pointing at `~/ubicloud-billing-rates.d`, and `BASE_URL` set to `http://<first address of hostname -I>:3000`. Account emails link to `BASE_URL`; the upstream default `http://localhost:9292` is unusable from a browser. If users open another URL (a DNS name, a reverse proxy), run the script with `UBI_BASE_URL=<that URL>`, or edit `.env.rb` afterwards. An older `.env.rb` is kept; add the lines by hand if the script warns.
- `~/.local/bin` (mise) must be on PATH for `bundle install`, or bundler fails with "No such file or directory - mise" (seen in the live AWS window).
- It starts `puma` and `respirate` in tmux. Logs go to `/tmp/{puma,respirate}.{log,err}`.

### 4.3 Do not start `bin/monitor` yet

Virtio and SCSI disks in a Proxmox guest have no `wwn-`/`nvme-eui` by-id links and no SMART, so upstream health checks misjudge the host and may mark it `unavailable` (PLATFORMS.md F5). Keep `UBI_START_MONITOR=0` (the default) and run the gate with `GATE_EXPECT_MONITOR=0`.

---

## 5. Data-plane bootstrap and SSH key

On the data plane:

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
```

It enables root public-key login (`PermitRootLogin prohibit-password`), and installs `ruby-bundler` and `netcat-openbsd`. It changes no network settings.

On the control plane, create the key the control plane will use:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/byoh_data
```

Install its public half as root on the data plane. The `ubuntu` login needs the private key that matches `--sshkeys` in §3.2, which is usually on your workstation, not on the control plane. So run this **on your workstation**, after copying `byoh_data.pub` there from the control plane:

```bash
ssh ubuntu@10.80.0.20 "sudo tee -a /root/.ssh/authorized_keys" < byoh_data.pub
```

If you put a control-plane key in `--sshkeys`, you can run the same command on the control plane instead. Then check from the control plane:

```bash
ssh -i ~/.ssh/byoh_data root@10.80.0.20 true && echo root ssh ok
```

Proxmox does not distribute this key for you (OPS-11). `--ssh-key` must be an unencrypted OpenSSH Ed25519 key.

---

## 6. Site network: pick a variant

These are NETWORKING §9.2 variants A and B. Both use `delivery: onlink`: the pool addresses sit on the LAN, and the data plane answers ARP for them through `proxy_arp`, which prep sets.

`uplink` in `pools.yaml` is the data plane's NIC name: `ens18` on i440fx, `enp6s18` on q35 (check with `ip -br link`). It is informational: it is stored and shown, and nothing configures the NIC from it.

> The `onlink` data path has not been run on any platform yet (UNVERIFIED). Code-wise it is the same path as `routed` and `fabric` (NETWORKING §3.1).

### 6.1 Common pfSense (or router) work

1. **Free a pool range.** Shrink the DHCP range so the pool is outside it, for example `10.80.0.200`-`10.80.0.239`. A pool address handed out by DHCP is stolen by another machine (NETWORKING §3.4).
2. **Outbound NAT.** pfSense's automatic outbound NAT already masquerades `10.80.0.0/24`, and the pool is inside it.
3. **LAN rules.** Allow traffic from the pool addresses, as for any LAN host.
4. **No other route for the pool range.** No static route, VPN route or WireGuard route may cover addresses on this LAN. With `proxy_arp` on, the host would answer ARP for them (NETWORKING §3.4).

### 6.2 Variant A: no public block, `onlink` + `internal`

Customers get an **Internal IPv4** that the office and VPN can reach. There is no internet ingress. Outbound IPv4 goes through the host NAT. This is a complete internal cloud, not a degraded public one.

`pools.yaml`:

```yaml
version: 2
uplink: ens18
routed_networks:
  - cidr: 10.80.0.200/29
    delivery: onlink
    exposure: internal
    segment: 10.80.0.0/24
    gateway: 10.80.0.1
```

All 8 addresses are usable. `usable: auto` reserves only the segment's network (`.0`), broadcast (`.255`) and gateway (`.1`), and none of them is inside this block.

### 6.3 Variant B: extra public IPs, `onlink` + `nat` (pfSense 1:1 NAT)

Customers get a **Public IPv4** (the external IP E) that reaches their VM at its pool address P.

On pfSense, for each pair:
1. **Firewall → Virtual IPs:** add E (type IP Alias or Proxy ARP) on WAN.
2. **Firewall → NAT → 1:1:** interface WAN, external E, internal P.
3. **Firewall → Rules → WAN:** pass any protocol to P. The customer's Ubicloud firewall is the filter (C3).
4. **NAT reflection off** for these entries (C2). VMs and office clients at the site then cannot reach E. The Ubicloud hairpin that fixes this for VMs is PLANNED (NETWORKING §4.6); office clients need split-horizon DNS.

`pools.yaml`, with your public IPs in place of the placeholders (documentation ranges such as `203.0.113.0/24` are refused):

```yaml
version: 2
uplink: ens18
routed_networks:
  - cidr: 10.80.0.200/29
    delivery: onlink
    exposure: internal
    segment: 10.80.0.0/24
    gateway: 10.80.0.1
  - cidr: 10.80.0.208/30
    delivery: onlink
    exposure: nat
    segment: 10.80.0.0/24
    gateway: 10.80.0.1
    external:
      10.80.0.208: <public IP 1>
      10.80.0.209: <public IP 2>
      10.80.0.210: <public IP 3>
      10.80.0.211: <public IP 4>
```

Each usable address of a `nat` pool needs a unique, globally routable external IP. An address you have no public IP for goes in `reserve: [...]`. You can also add the external IPs later with `bin/byoh-pool annotate`, or with `export --external-map map.yaml` ([POOL_OPERATIONS.md](POOL_OPERATIONS.md) §2.1).

### 6.4 Other shapes

| Shape | When | Declare |
|---|---|---|
| Variant C: `routed` + `public` | The ISP routes a block to pfSense's WAN. pfSense routes it to `10.80.0.20` (the data-plane VM, **not** the Proxmox node), with a "Do not NAT" outbound rule for the block. | `cidr: <block>`, `delivery: routed`, `exposure: public` |
| Variant D | One WAN IP, but internet ingress is needed | The tunnel recipe, NETWORKING §9.4 (PLANNED) |
| IPv6 | pfSense gets a prefix by DHCPv6-PD | An IPv6 route needs an IPv6 next hop. Give the data-plane VM a static IPv6 on the LAN (`qm set $VMID --ipconfig0 ip=10.80.0.20/24,gw=10.80.0.1,ip6=<LAN /64>::20/64,gw6=<pfSense LAN IPv6>`), route a **second** /64 from the delegated prefix to that address, and add `cidr: <the second /64>` (`gua`). For a /64 that is on-link on the LAN instead, add it with `ndp: true`. UNVERIFIED on Proxmox. Without either, IPv6 is `ula` and needs nothing. |

Port forwarding on a shared WAN IP, Tailscale on the host, and `cloudflared` on the host are lab helpers, not product modes (NETWORKING §3.3).

---

## 7. Location and registration

Run everything on the control plane, from `~/ubicloud`.

### 7.1 Create the BYOH location (once per site)

```bash
bundle exec bin/byoh-location create --name byoh-pve-office \
  --ui-name "Office Proxmox (BYOH)" \
  --underlay 10.80.0.0/24 \
  --overlay 172.20.0.0/14 \
  --cp-reach onhost \
  --cp-source <control plane IP as the site sees it>/32 \
  --mgmt-allow 10.80.0.0/24 \
  --rates-from hetzner-fsn1
```

- `--underlay`: the site LAN, plus any office or VPN ranges. VMs may not open connections to these (they go into the host NAT's deny list), but office clients can still connect to `internal` VMs.
- `--overlay`: where customer private subnets are drawn from. It must be RFC 1918 and not overlap the underlay or office ranges.
- `--cp-reach`: `onhost` or `public`; see §4.1.
- `--ula48` is generated at random. Pass one only to fit an existing host's `net6`.
- `--rates-from hetzner-fsn1` copies upstream prices into `$BILLING_RATES_EXTRA_DIR`; use `--multiplier` to change them.

The command (and gate step G2) may print two **warnings**. Neither is a failure, and neither stops anything:

- `cp_source_cidrs <ip>/32 is not in CONTROL_PLANE_OUTBOUND_CIDRS`. To silence it, add `ENV["CONTROL_PLANE_OUTBOUND_CIDRS"] ||= "<control plane IP>/32"` to `.env.rb` (comma-separated for several).
- `BASE_URL is http://localhost:9292`. This appears only with an `.env.rb` from an older bootstrap; set `BASE_URL` as in §4.2.

Then restart `puma` and `respirate` so they load the rates. They are tmux sessions; the bootstrap restarts them and skips every finished step:

```bash
tmux kill-session -t puma; tmux kill-session -t respirate
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
bundle exec bin/byoh-location show --location byoh-pve-office
```

The location is hidden. After you create your account (§8), give your project access. The project ubid (`pj…`) is in the UI's address bar on any project page (`/project/pj…`):

```bash
bundle exec bin/byoh-location grant --location byoh-pve-office --project pj...
```

### 7.2 Register the host

Copy your `pools.yaml` (§6) to the control plane, then:

```bash
bundle exec bin/register-byoh-host \
  --location byoh-pve-office \
  --main-ip 10.80.0.20 \
  --pool-file pools.yaml \
  --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble \
  --yes
```

- There is no `--provider` flag. Passing one aborts with InvalidOption.
- `--main-ip` must not be inside any pool.
- Pool entries can also be given inline, with `--routed-network 10.80.0.200/29,delivery=onlink,exposure=internal,segment=10.80.0.0/24,gateway=10.80.0.1`.
- Keep `RACK_ENV=development` (the default). With `production`, boot images come from R2/MinIO, which BYOH does not have.

The command prints `VmHost UBID:  vh…`. Keep it: §7.3, §9 and the pool and host CLIs take it as `--host`.

Bring-up took about 4 minutes on an AWS nested-virtualization VM. It is UNVERIFIED on Proxmox; allow 15-25 minutes. It **reboots the data-plane VM once**. Watch it:

```bash
tail -f /tmp/respirate.log
psql -U clover -d clover_test -c "SELECT allocation_state, os_version, total_cores, total_hugepages_1g FROM vm_host"
```

The host is ready when `allocation_state` is `accepting`.

### 7.3 Check the pools and the egress table

```bash
bundle exec bin/byoh-pool list   --host vh...
bundle exec bin/byoh-pool verify --host vh...       # exit 0, no FAIL lines (see below)
ssh -i ~/.ssh/byoh_data root@10.80.0.20 nft list table inet byoh_egress   # the host NAT table is loaded
ssh -i ~/.ssh/byoh_data root@10.80.0.20 ip -br -4 addr                    # still only 10.80.0.20 (C5)
```

On a variant A host, `verify` always prints `warn: no free public or nat IPv4 address: no internet VM with IPv4 can be placed on this host; internal VMs and VMs without IPv4 can`. That is expected: the host has no internet pool.

If the egress table is missing, install it with `bundle exec bin/byoh-host setup-egress-nat --host vh...`.

---

## 8. Create VMs

Create an account at `http://<control plane>:3000/create-account`. The verification email goes to `/tmp/puma.log`; its link uses `BASE_URL` (§4.2). If the link starts with `http://localhost:9292`, replace that part with `http://<control plane>:3000`. Then grant the project (§7.1) and add an SSH key.

**CLI setup.** The `ubi` CLI (and `bin/ubi` in the repo) needs a token, and by default it talks to Ubicloud's hosted service, not to your control plane. The API also answers only on a host name that starts with `api.` (the host routing in `clover.rb`). UNVERIFIED: the CLI path has not been run against a BYOH control plane.

1. In the UI, open the project's **Personal Access Tokens** page (`/project/pj…/token`) and create a token.
2. On the machine where you run `ubi`, give the control plane an `api.` name, for example `echo "<control plane IP> api.byoh.internal" | sudo tee -a /etc/hosts`.
3. `export UBI_TOKEN=pat-... UBI_URL=http://api.byoh.internal:3000/cli`

| Variant | VM | UI | CLI |
|---|---|---|---|
| A | internal | Location "Office Proxmox (BYOH)", enable IPv4, **IPv4 Exposure: internal** | `ubi vm byoh-pve-office/vm1 create -e internal -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"` |
| B | internet (nat) | IPv4 on, IPv4 Exposure **internet** | `ubi vm byoh-pve-office/vm2 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"` |
| any | no IPv4 | IPv4 off | `ubi vm byoh-pve-office/vm3 create -6 -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"` |

- An **internet** VM with IPv4 places only on a host with a free `public` or `nat` address. On a variant A host it waits for capacity. Pick **internal**, or leave IPv4 off.
- A VM without IPv4 needs no pool at all. Its outbound IPv4 goes through the host NAT.
- The CLI path uses the location's display name (`--display-name`, default `--name`).
- The VM user is `ubi`. Internal VMs are reached from the LAN or VPN at their pool address: `ssh ubi@10.80.0.20x`.
- `ubuntu-noble` is the default image. Download `ubuntu-jammy` too (`--default-boot-image ubuntu-jammy`) only if customers will pick it.

---

## 9. Gate (UNVERIFIED on Proxmox)

`scripts/byoh/verify/m2-gate.sh` reaches each VM through its namespace on the host: `ssh root@<host> ip netns exec <inhost> nc <private ipv4> 22`. That works with ULA hosts and needs no route from the control plane to the VM. [VERIFY.md](VERIFY.md) §1.4 lists every setting.

```bash
export GATE_LOCATION=byoh-pve-office GATE_HOST=vh... GATE_MAIN_IP=10.80.0.20
export GATE_HOST_KEY=~/.ssh/byoh_data GATE_VM_KEY=~/.ssh/id_ed25519
export GATE_EXPECT_MONITOR=0                 # §4.3
export GATE_VM_B=vm...                       # created with -6
export GATE_VM_C=vm...                       # created with -e internal
export GATE_CTRL_PRIV=<control plane LAN IP> GATE_UNDERLAY_PROBE=<another LAN host with SSH open>
export GATE_SMTP_PROBE=<an internet host that accepts TCP 25>

# Variant A (no internet pools):
scripts/byoh/verify/m2-gate.sh g1 g2 g3 g4 g5 g7 g8 g9 g9b
# Variant B adds the nat VM. Its SSH to the external IP E must start outside
# the site, because NAT reflection is off (§6.3):
GATE_VM_A=vm... GATE_EXTERNAL_SSH_VIA=<user@host outside the site> scripts/byoh/verify/m2-gate.sh g6
```

Without `GATE_EXTERNAL_SSH_VIA`, G6 dials E from the control plane. With the control plane on the LAN and reflection off, that one line FAILs by design; test `ssh ubi@<E>` from an outside machine by hand instead. `GATE_EXTERNAL_SSH_VIA` makes G6 jump through the outside host with `ssh -J`, so that host needs only SSH access and TCP forwarding (UNVERIFIED: never run).

To reach a VM by hand the same way:

```bash
bundle exec scripts/byoh/verify/m2-checks info --vm vm...      # prints private_ip4= and inhost=
ssh -o "ProxyCommand=ssh -i ~/.ssh/byoh_data root@10.80.0.20 ip netns exec <inhost> nc %h %p" ubi@<private_ip4>
```

Do not jump to the VM's IPv6 through the host. On a `ula` host it fails with "No route to host": the VM's namespace routes only `2000::/3` back to the host (CLAUDE.md §10 #7, verified on AWS).

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Strand stuck at `bootstrap_rhizome` | Root SSH from the control plane fails: key not in `/root/.ssh/authorized_keys`, or no route to `10.80.0.20` (C0). Test with `ssh -i ~/.ssh/byoh_data root@10.80.0.20 true`. |
| PrepHost fails | No outbound internet from the data plane (cloud-hypervisor and other downloads). |
| LearnMemory "unexpected dmidecode unit" | Memory is not a multiple of 1024 MiB. Fix it with `qm set <id> --memory 32768` and restart the VM from Proxmox (`qm shutdown` then `qm start`; a guest reboot does not apply the change). Do not re-register: respirate retries the failed step on its own. To re-register anyway, destroy the old VmHost first (§11). |
| `verify_hugepages` fails | Not enough memory for 1G hugepages, or `cpu` is not `host` (no `pdpe1gb`). |
| No `/dev/kvm` in the data plane | Nested virtualization is off on the node, or the CPU type is not `host`. |
| VM waits for capacity ("No capacity left") | An internet VM on a host with only `internal` pools (use `-e internal`); no free address of the right exposure (`bin/byoh-pool list`); boot image not downloaded; too few cores or hugepages. On a low-core host, the slices setting may not match. Scope the fix to the one host: `DB[:vm_host].where(id: …).update(accepts_slices: false)`. Never run it unscoped, as `deploy-scripts/04` did. |
| An internal VM is unreachable from the LAN | The pool range is inside the DHCP range or used elsewhere (`arping -I <iface> 10.80.0.20x` from another LAN host shows two MACs); the Proxmox NIC firewall or ipfilter is on; a route or VPN overlaps the LAN (§6.1). |
| VM stuck at `wait_sshable` | With `cp_reach: onhost`, the control plane cannot reach the pool address. Put it on the LAN, or switch the location to `--cp-reach public` (§4.1). |
| A nat VM is unreachable at E from the internet | Missing pfSense 1:1 entry or WAN pass rule. From inside the site, this is expected while reflection is off (§6.3). |
| VM has no DNS | Guest dnsmasq forwards to public resolvers (8.8.8.8 and public IPv6). The site firewall must allow outbound DNS from the data plane. Site resolvers (`dns_servers`) are PLANNED. |
| VM cannot reach a LAN host | By design: the underlay is in the VM egress deny list. There is no exception list yet: `--egress-allow` is stored but not enforced (PLANNED P2). |
| Host marked `unavailable` | `bin/monitor` is running with health checks that do not fit virtio disks (§4.3). |

---

## 11. Removing a host

1. Destroy its VMs, and wait until the host has none.
2. In `bin/pry`: `VmHost["vh..."].incr_destroy`. Dependents are destroyed when the strand finishes. There is no Proxmox or BMC cleanup.
3. Never delete `location` rows by hand. Delete an empty BYOH location with `bin/byoh-location delete --location <name>`.
4. To re-register the same VM, destroy the old VmHost first. `sshable.host`, `address.cidr` and `vm_host.net6` are unique.
