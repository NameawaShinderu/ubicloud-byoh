# Generic / BYOH provider

> Bring-your-own-hardware driver. Lets Ubicloud run on any SSH-reachable
> Linux server — colocated servers, homelab rigs, hosters not on the
> supported-provider list, even KVM guests during development. No provider
> ordering API required.

## When to use it

Use `generic` when:

- You own the hardware and manage it yourself (colocated, homelab, on-prem).
- You're running on a bare-metal host at a provider Ubicloud doesn't have
  a driver for (e.g., OVH, Vultr, Cherry Servers, PhoenixNAP, self-hosted VPS).
- You're developing locally against libvirt guests.

Do **not** use `generic` when:

- You're on Hetzner. Use the `hetzner` driver — it knows how to call the
  Robot API for IP pulling, reimage, server rename, etc.
- You need automated OS reinstall. BYOH hosts don't get automated reimage;
  the operator reinstalls the OS out-of-band. See [Capabilities](#capabilities).

## Host prerequisites

The BYOH host must have:

1. **Ubuntu 24.04 LTS**. Ubicloud's rhizome agent + `prep_host.rb` are hard-coded
   to `apt-get` package names (`nvme-cli`, `smartmontools`, `qemu-utils`,
   `mtools`, `acl`, `ruby-bundler`, `systemd-coredump`). Debian 12 will probably
   work; Rocky/Alma/Fedora will not without porting.
2. **NVMe storage strongly recommended.** SPDK is Ubicloud's block backend.
   It binds to NVMe devices via VFIO. Hosts without NVMe can register but
   SPDK setup will fail during bootstrap — the host will never reach
   `accepting`. SATA/HDD-only hosts are not supported in v1.
3. **A management IPv4 address** that the control plane can SSH to (22/tcp).
4. **`/root/.ssh/authorized_keys`** containing the control plane's SSH public
   key. The `bin/register-byoh-host` CLI will print the exact key to install.
5. **Optionally: a Redfish-capable BMC** reachable from the control plane
   for `hardware_reset` support. Any 2018+ Dell iDRAC, HP iLO, Supermicro,
   or AMI MegaRAC BMC will work. IPMI-only BMCs are not supported in v1.

## Networking model

For a BYOH host the operator must declare up-front which IP blocks are
routable to the host. The control plane trusts this declaration — it does
not call any provider API.

You declare networks at registration time. Each declared `routed_network`
becomes an `Address` row and (for IPv4) gets expanded into `ipv4_address`
rows that Ubicloud will assign to VMs. The operator's router is responsible
for actually routing traffic for those CIDRs to the BYOH host's management
NIC (typically via a static route).

### Making declared `routed_networks` actually reachable per environment

**This is the single most important operator-side step, and it's
environment-specific.** The BYOH driver does not touch your upstream
routing — it assumes packets for the declared blocks are already being
delivered to your host. What "already being delivered" means varies:

| Environment | What the operator does BEFORE registration | Routing is handled by |
|---|---|---|
| **Hetzner dedicated** | Order an additional `/29` or `/28` IP block via Robot; Hetzner asks which server it should be routed to; pick your box | Hetzner's core routers (automatic after order) |
| **OVH / OVHcloud** | Order IP block via OVH Manager → "route to server X"; wait for delivery email | OVH core (automatic after order) |
| **Equinix Metal** | Order "Public IPv4 Subnet" → assigned to a specific project & server | Equinix fabric (automatic) |
| **Cherry Servers / Latitude.sh / PhoenixNAP** | Same pattern: order subnet via provider panel, route to your server | Provider's core (automatic) |
| **Leaseweb** | Order additional IPs; Leaseweb configures the routing | Leaseweb core (automatic) |
| **Your own colocation** | Your upstream transit/peering announces your prefix; you already have `ip route add` on your edge router to your server | Your own edge router |
| **Homelab behind a consumer router** | Add a **static route** on your router UI: `10.99.100.0/29 → <byoh-host-LAN-IP>`. Every DD-WRT, OpenWRT, pfSense, OPNsense, Mikrotik, Unifi, and most consumer routers support this | Your home router |
| **Proxmox host as a router** | Add the route to the Proxmox host itself: `ip route add 10.99.100.0/29 via <proxmox-IP>`; enable `net.ipv4.ip_forward=1` | Proxmox host (you) |
| **Cloud VPC (AWS / GCP / Azure)** | Add a custom VPC route `routed_cidr → byoh-instance-ENI` AND disable source/dest check (AWS) / enable IP forwarding (GCP/Azure) | Your VPC route table |
| **Single IP, no block** (NAT-only) | Declare one `/32` for the host's management IP; VMs get RFC1918 from a LOCAL block, SNAT out via host | No routing — VMs are NAT'd out through the host's single IP |

**The BYOH driver itself does NOT install any of these routes.** If packets
for a declared CIDR can't reach the host, VMs allocated IPs from that
block will be unreachable from outside the host — but they'll still boot
and run, and the control plane can drive them via the host (which acts
as a bastion).

### The cloud-VPC case, concretely (AWS example from our test setup)

When we validated the BYOH driver on an `m5d.metal` instance in an
AWS VPC, the VM allocator assigned `10.99.100.6` to the first VM. But
AWS's VPC route table only knew about `10.99.1.0/24` (the VPC subnet);
packets for `10.99.100.0/29` had no path to the m5d.metal. We fixed it
with two one-time AWS operations at **host registration time**:

```bash
# 1. Disable source/dest check so the instance can forward packets
#    destined for IPs it doesn't own
aws ec2 modify-instance-attribute \
  --instance-id i-0d358c50020234aac \
  --source-dest-check "{\"Value\": false}"

# 2. Add a VPC route pointing the declared BYOH CIDR to the instance ENI
aws ec2 create-route \
  --route-table-id rtb-0230a5b29f9c6ecf9 \
  --destination-cidr-block 10.99.100.0/29 \
  --network-interface-id eni-0b9513c06b838d7c1
```

From that moment, any instance in the same VPC that sends a packet to
`10.99.100.6` has it routed to the m5d.metal ENI. The ENI delivers it
to the Linux kernel, which forwards to the VM's tap via `proxy_arp` +
nftables rules that Ubicloud set up during the VM's `run_nftables`
label.

**For a multi-host BYOH cluster on AWS**, you'd either:
- Allocate a different `routed_network` CIDR per host (e.g. host A
  gets `10.99.100.0/29`, host B gets `10.99.100.8/29`) and add one
  VPC route per host, **or**
- Run one host as the "router" that owns all the CIDRs and have it
  overlay-forward to the other hosts via IPSec+VXLAN (which Ubicloud's
  `prog/vnet/metal/*` already does automatically between hosts).

**Important caveat: IPv6 routes** cannot point at a primary ENI in AWS
VPC unless IPv6 is configured on the VPC itself — AWS will reject the
`create-route --destination-ipv6-cidr-block`. If you need in-VPC IPv6
reachability to BYOH VMs on AWS, you need to enable IPv6 on the VPC
first and allocate from AWS's IPv6 pool. For the homelab and Hetzner
cases, ULA `fd00::/8` blocks are fine because IPv6 overlay traffic
stays within the host anyway.

### Known limitation: storage device discovery on multi-NVMe hosts

On a fresh BYOH host, `Prog::LearnStorage` scans the host via
`lsblk`/`smartctl` and registers what it finds as `storage_device`
rows. In our AWS m5d.metal validation we observed that only **the
root EBS disk** got registered as `DEFAULT` — the four 838 GB NVMe
instance-store devices (`nvme0n1`-`nvme3n1`) were not picked up, so
SPDK served VM disks from a file on the 80 GB root ext4 instead of
binding raw NVMe via VFIO.

Symptom: second VM creation fails with
`no space left on any eligible host` even though the instance has
3.2 TB of fast local NVMe sitting idle.

Workarounds until this is properly patched upstream:

1. **Bigger root EBS disk** — set `data_root_size_gb = 500` in
   `terraform/aws-byoh/terraform.tfvars` before `terraform apply`.
   SPDK serves VM disks from the (now-huge) root disk. Simple; wastes
   the fast instance-store NVMe but gives you enough capacity for
   5-10 concurrent VMs.
2. **Manually register the instance-store NVMes** as additional
   `storage_device` rows after host registration (via a Ruby script
   that calls `SpdkSetup.prep` + `StorageDevice.create` for each
   NVMe). A proper patch would extend `LearnStorage` to enumerate
   all NVMe controllers, not just the root.
3. **Skip AWS**: on Hetzner/OVH/Equinix + most homelab hosts the
   single-disk model is the common case and this limitation doesn't
   bite — one disk, one storage_device, all good.

The fix is a Phase 8 item. None of the BYOH code changes that got
us this far depend on it.

### Out-of-scope (and why)

The BYOH driver does NOT:
- Call provider APIs to add routes
- SSH into your edge router to add `ip route` entries
- Update BGP announcements
- Configure proxy_arp / proxy_ndp on the host (those come from the
  rhizome agent's standard prep, which is environment-agnostic)

These are all **operator responsibilities**, and they have to happen
**before** registering the host. Ubicloud can't know your network
topology and shouldn't try — that's what makes the driver "generic."

### Three supported topologies

**(A) Colocated server with a routed subnet.** ISP routes a `/29` (8 IPs)
to the server's main IP. Declare the subnet as a `routed_network`. VMs get
public IPs from the block (minus the management IP, which is auto-reserved).

```
--routed-network 203.0.113.40/29
--routed-network 2001:db8:dead::/64
```

**(B) Homelab with a statically-routed private block.** Your router is
configured with a static route: `ip route add 10.99.0.0/24 via 192.168.1.10`.
Declare the `/24` (or smaller) as a `routed_network`. VMs get RFC1918 IPs
reachable from your LAN.

```
--routed-network 10.99.0.0/24
--routed-network fd00:feed::/64
```

**(C) Single management IP, no additional block.** Only the management
IP is declared. VMs share it via NAT (not yet implemented in v1 — for now,
register with at least one declared block).

### IPv6

BYOH hosts **must** have an IPv6 `/64`. The Ubicloud allocator hardcodes
`ephemeral_net6 = vm_host.ip6_random_vm_network.to_s` and crashes if net6
is nil. If you don't have a globally-routed `/64`, use a **ULA**:

```
--routed-network fd00:feed::/64
```

(Any `fdXX:XXXX:XXXX::/64` pattern works. Keep it unique across your hosts.)

The CLI auto-generates a random ULA `/64` if you omit IPv6 entirely, so
this is opt-out, not opt-in.

## Registering a host

```sh
export HOMELAB_BMC_PASS='<your-bmc-password>'

bundle exec bin/register-byoh-host \
  --main-ip 192.168.1.10 \
  --routed-network 10.99.0.0/29 \
  --routed-network fd00:feed::/64 \
  --location homelab-rack-A \
  --bmc-endpoint https://192.168.1.11 \
  --bmc-user admin \
  --bmc-pass-env HOMELAB_BMC_PASS \
  --bmc-system-id 1
```

The CLI will:

1. Generate a fresh Ed25519 keypair (or use `--ssh-key PATH` to reuse an
   existing one).
2. Print the **public key** and instructions for installing it in
   `/root/.ssh/authorized_keys` on the BYOH host.
3. Wait for you to press ENTER (use `--yes` to skip).
4. Create `Sshable`, `VmHost`, `HostProvider`, `Address`, `ipv4_address`,
   `assigned_host_address`, and `Strand` rows in one transaction.
5. Print the `VmHost` UBID and `Strand` UBID.

From there, the `respirate` dispatcher picks up the strand and drives the
host through bootstrap (SSH key setup → rhizome install → `apt-get install`
packages → SPDK setup → hugepages → download boot images → reboot →
verification → `accepting` state). This takes **20-40 minutes** on first
run depending on network speed.

## BMC credentials

`host_provider.config` stores a **symbolic reference** to the BMC password,
not the password itself. Use `--bmc-pass-env VAR_NAME`; the control plane
must have `VAR_NAME` set in its environment at runtime for power operations
to work. Inline `--bmc-password` exists for dev/test convenience but should
never be used in production — the DB then holds the secret.

The BMC config stored on each `HostProvider` row looks like:

```json
{
  "bmc": {
    "protocol": "redfish",
    "endpoint": "https://192.168.1.11",
    "username": "admin",
    "password_env": "HOMELAB_BMC_PASS",
    "verify_ssl": false,
    "system_id": "1",
    "reset_type": "ForceRestart"
  }
}
```

## Capabilities

| Capability | Generic driver | Notes |
|---|---|---|
| `ip_pull` | always | Returns operator-declared blocks + auto-prepended mgmt `/32` |
| `hw_reset` | with BMC | Power-cycles the host via Redfish `ComputerSystem.Reset` |
| `reimage` | **never** | Ubicloud doesn't run a PXE/iPXE server for BYOH hosts. Reinstall Ubuntu out-of-band and re-register. |
| `set_server_name` | no-op | The operator names their own hosts |
| `rdns` | never | Configure reverse DNS via your own DNS provider |

## Troubleshooting

### `net6 is already taken` during registration

The DB has a UNIQUE index on `vm_host.net6`. You have a leftover vm_host
with the same `/64`. Either pick a different ULA or delete the stale row.

### `setup_ssh_keys` completes but `bootstrap_rhizome` never progresses

The control plane can't SSH into the host. Verify:

1. The public key the CLI printed is actually in `/root/.ssh/authorized_keys`
   on the BYOH host (`sudo cat /root/.ssh/authorized_keys`).
2. The BYOH host accepts root SSH (`PermitRootLogin prohibit-password` in
   `/etc/ssh/sshd_config`).
3. The control plane can reach `sshable.host` on port 22 (`nc -z <ip> 22`).
4. No firewall (ufw, iptables, cloud security group) is blocking.

### `prep_host` fails on `apt-get install nvme-cli`

The BYOH host has no NVMe device. `nvme-cli` installs fine, but SPDK setup
later will fail anyway because SPDK binds to NVMe via VFIO. **NVMe is
effectively required.**

### `Hosting::CapabilityMissing: ... does not support automated reimage`

Expected. Reinstall the OS out-of-band (PXE / USB installer / remote KVM)
and re-run `bin/register-byoh-host` with the same `--main-ip` — this
registers a new `HostProvider` row. Delete the old one via the admin
console or SQL.

### BMC `Excon::Error::Unauthorized` on `hardware_reset`

Wrong username/password, or `password_env` references an unset env var on
the control plane. Verify with `curl -ksu admin:$HOMELAB_BMC_PASS
https://<bmc-ip>/redfish/v1/Systems`.

### BMC returns `Error connecting to libvirt URI "qemu:///system"`

You're talking to a stock `sushy-tools` container without libvirt mounted.
Either mount `/var/run/libvirt` from a KVM host, or configure sushy-tools
with a static driver. For dev testing, use the Excon stub tests in
`spec/lib/hosting/redfish_client_spec.rb` rather than a real sushy-tools
container.

## Validating end-to-end

See [TESTING.md](./TESTING.md) for Tier A/B/C setup — libvirt dev loop on
your laptop, short-lived cloud bare-metal for CI, and homelab validation.
