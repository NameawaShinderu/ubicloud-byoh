# Recipe: a homelab or office machine as a BYOH host

> **UNVERIFIED.** No homelab host has been registered in this project.
> The checks named here are tested on fixtures and containers only.

A desktop, mini PC or tower behind a home or office router becomes a
BYOH host. This recipe gives the machine and a `pools.yaml`, then the
three commands of [README.md](README.md). The full guide, with firmware
settings, router recipes, power and the colo and CGNAT shapes, is
[platforms/own-hardware.md](../platforms/own-hardware.md).

## 1. The machine

- Ubuntu 24.04 server, installed on its own disk, with a **static** LAN
  address (or a DHCP reservation that never changes), say `192.168.1.20/24`
  with the router at `192.168.1.1`. Wired uplink; Wi-Fi is UNVERIFIED.
- VT-x/AMD-V **on** in the firmware (own-hardware.md §2.2). Without it
  there is no `/dev/kvm` and preflight fails PF3, which cannot be
  accepted.
- 16 GiB of memory or more, 2 CPUs or more, `/var/storage` on ext4 or xfs
  (the Ubuntu installer default). ZFS is refused (`PF10-zfs`); btrfs fails
  `PF10-btrfs` unless you accept it, and VM storage on btrfs is
  UNVERIFIED.
- A user with passwordless sudo and your SSH key, for `host add --ssh`:

  ```bash
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-ubicloud-admin
  ```

  Remove the file once the host is added, if you want.
- The machine does nothing else. Bring-up deletes and recreates the
  `rhizome` user, reboots the machine, and takes over its firewall (§3).

## 2. CPU: hybrid parts

Intel 12th-14th gen and Core Ultra desktop CPUs mix performance and
efficiency cores, and some Arm boards do the same (big.LITTLE). Host
preflight fails such a CPU as `PF8-hybrid`, and says so.

The choices:

- **Turn E-cores off** in the firmware if the board allows it. Then the
  check passes.
- **Accept it**: `host add ... --accept-check PF8-hybrid`. Since M4 a BYOH
  host counts every CPU as a core when cores have different thread
  counts, so VMs boot (the old `BUG` in `write_params_json` came from
  that mismatch). But placement does not tell P-cores from E-cores yet
  (M5), so a VM may get a mix and run at uneven speed. Tested on lscpu
  fixtures, not on hybrid hardware (UNVERIFIED).

SMT should stay on. Offline CPUs are left out since M4 (PF8 warns), and
at least 2 must be online (`PF-min-cpu`).

## 3. Firewall: Docker, ufw, Tailscale, k3s, libvirt

Bring-up writes the host's nftables ruleset, and Ubuntu's
`/etc/nftables.conf` starts with `flush ruleset`. Every time it is
reloaded (on every VM create and destroy), it **wipes the rules of every
other firewall manager on the machine**: Docker's port publishing and
container NAT, ufw's rules, Tailscale's, k3s's and libvirt's
(PLATFORMS.md NH-6; a fix, `host_guard`, is planned for M7).

So host preflight fails each active one: `PF16-docker`, `PF16-ufw`
(judged by `ENABLED=yes` in `/etc/ufw/ufw.conf`), `PF16-tailscaled`,
`PF16-k3s`, `PF16-libvirtd`. Best is to stop and disable them on this
machine. If you must keep one, `--accept-check PF16-docker` (and so on)
lets `host add` go on, knowing its rules will be flushed again and again
and that it may in turn drop VM traffic.

## 4. SSH: password logins end

Bring-up sets `AuthenticationMethods publickey` for sshd, which turns off
password SSH logins **for every user** on the machine, not only root.
Make sure your own login works with a key before you run `host add`; its
confirmation lists this change. `host add` installs its own root key on a
tagged line in `/root/.ssh/authorized_keys` and allows root key login
(`PermitRootLogin prohibit-password`) only if sshd does not already.

## 5. Addresses for VMs

A home router has no public block, so VMs get LAN addresses or none.

**LAN pool, `onlink` + `internal`** (simplest). Shrink the router's DHCP
range so the pool is outside it. The machine answers ARP for the pool
(proxy_arp); nothing else on the router.

```yaml
version: 2
uplink: enp3s0               # your NIC (ip -br link); informational
routed_networks:
  - cidr: 192.168.1.200/29
    delivery: onlink
    exposure: internal
    segment: 192.168.1.0/24
    gateway: 192.168.1.1
```

**Static route, `routed` + `internal`**, if the router can route a block
to a LAN host (most can: "static routes"). Route `10.66.0.0/28` to
`192.168.1.20`; then:

```yaml
version: 2
uplink: enp3s0
routed_networks:
  - cidr: 10.66.0.0/28
    delivery: routed
    exposure: internal
```

LAN clients reach the VMs through the router. A client on the same LAN
may need the same route if the router does not send ICMP redirects
(UNVERIFIED).

VMs without IPv4 need no pool at all: they reach the internet through the
host NAT. Internet **ingress** to a homelab VM needs public addresses
(a router 1:1 NAT, `onlink` + `nat`) or a tunnel (own-hardware.md §3.5
T1, PLANNED).

## 6. The three commands

On the control plane (any Ubuntu 24.04 machine that reaches
`192.168.1.20:22`; another box on the LAN is simplest):

```bash
sudo ubicloud-admin site add home --display "Home lab (BYOH)" \
  --underlay 192.168.1.0/24 --overlay 172.20.0.0/14 --cp-reach onhost \
  --cp-source <control plane LAN IP>/32 --mgmt-allow 192.168.1.0/24 \
  --rates-from hetzner-fsn1

sudo ubicloud-admin host add --site home --ssh <you>@192.168.1.20 \
  --ssh-key ~/.ssh/id_ed25519 --pool-file pools.yaml \
  [--accept-check PF8-hybrid] [--accept-check PF16-docker]
```

`host add` prints the checks, the changes (§3, §4, the reboot) and the
host key fingerprints, and asks for a typed `yes`. Compare the
fingerprints with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on
the machine itself. It exits 0 once the machine accepts VMs, after one
reboot.

Underlay rule: VMs cannot open connections into `--underlay`,
`--cp-source` or `--mgmt-allow` (they are in the host NAT's deny list),
so a VM cannot reach your NAS or router admin page. LAN clients can still
connect to `internal` VMs.
