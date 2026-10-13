# Generic / BYOH provider

> The bring-your-own-hardware driver. It lets Ubicloud run on any Ubuntu 24.04 machine the control plane can SSH into as root: rented bare metal, colo servers, homelab machines, Proxmox guests, or cloud instances with nested virtualization. It needs no provider API.

Setup runbooks: [docs/byoh/SETUP.md](../byoh/SETUP.md) for any platform, [SETUP_PROXMOX.md](../byoh/SETUP_PROXMOX.md) for Proxmox, and [QUICKSTART.md](../byoh/QUICKSTART.md). The network design is in [NETWORKING.md](../byoh/NETWORKING.md); the platform matrix is in [PLATFORMS.md](../byoh/PLATFORMS.md).

## When to use it

Use `generic` when nothing orders, reinstalls or routes the machine for Ubicloud: you manage the hardware and its network yourself.

Use the `hetzner` driver for Hetzner Robot servers if you want automated reimage, IP pulls and server names from the Robot API.

## Host prerequisites

The full list is in SETUP.md §2. In short:

1. **Ubuntu 24.04 LTS** on x86_64. Rhizome uses apt package names.
2. **KVM and 1G hugepages.** On a guest, that means nested virtualization and the host CPU model.
3. **Memory in whole GiB.** LearnMemory reads `dmidecode`.
4. **Outbound internet**, for cloud-hypervisor and boot image downloads.
5. **Any local disk.** The storage backend is vhost-block-backend, with VM disks as files under `/var/storage`. Neither SPDK nor NVMe is required.
6. **A management IPv4** the control plane can SSH to as root. Put the control plane's public key in `/root/.ssh/authorized_keys` first.
7. **Optionally, a Redfish BMC** reachable from the control plane, for hardware reset and power on.

## Networking model

The operator declares the address pools of each host. The control plane trusts the declaration and calls no provider API. Each IPv4 pool has:

- a `delivery`: how packets reach the host, which is `routed`, `onlink` or `fabric`;
- an `exposure`: what the internet sees, which is `public`, `nat` (1:1 to an external IP) or `internal`.

The code path is the same for all of them (NETWORKING §3).

**The driver never configures upstream routing.** Before registration, the operator makes the pool addresses reach the host:

| Environment | Operator pre-work | Pool shape |
|---|---|---|
| Hetzner, OVH (routed mode), Leaseweb | Order a block routed to the server's main IP | `routed` + `public` |
| Colo | Static route or BGP of the block to the host | `routed` + `public` |
| Proxmox / LAN, no public block | Pool range outside DHCP; one NIC on the bridge; Proxmox NIC firewall off | `onlink` + `internal` |
| Proxmox behind pfSense with extra IPs | pfSense 1:1 NAT from each external IP to a pool IP, reflection off | `onlink` + `nat` |
| Router-routed block (pfSense, home router) | Static route `<block> → <data-plane IP>`. On Proxmox, that is the **data-plane VM's** IP, not the Proxmox node's. | `routed` + `public` (or `internal` for RFC 1918) |
| AWS | ENI secondary IPs with EIPs, from `terraform/aws-byoh` | `fabric` + `nat` |

Never configure pool addresses on the host's NIC or in netplan (contract C5).

**No pool at all** is valid. VMs without IPv4 still place, and their outbound IPv4 goes through the host NAT (`/etc/nftables.d/1-byoh-egress.conf`). Only VMs that ask for IPv4 need a free pool address of the matching exposure.

**IPv6.** Declare a routed /64 for `gua` mode. Without one, the host gets a ULA /64 from its location's `ula48`. In `ula` mode, the host cannot reach a VM over IPv6, because the VM's namespace routes only `2000::/3` back. Reach VMs through their namespace instead (VERIFY.md §1.4).

Retired methods, do not use:
- AWS VPC route-table routes for a CIDR inside the VPC. They are not routable.
- `scripts/byoh/providers/aws-routed-network-setup.sh`.

## Registering a host

Create the site's BYOH location once, then register:

```sh
bundle exec bin/byoh-location create --name byoh-lab --underlay 192.168.1.0/24 \
  --overlay 172.20.0.0/14 --cp-reach onhost --cp-source 192.168.1.5/32 --rates-from hetzner-fsn1

export LAB_BMC_PASS='<your-bmc-password>'
bundle exec bin/register-byoh-host \
  --location byoh-lab \
  --main-ip 192.168.1.10 \
  --pool-file pools.yaml \
  --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble \
  --bmc-endpoint https://192.168.1.11 --bmc-user admin --bmc-pass-env LAB_BMC_PASS --bmc-system-id 1 \
  --yes
```

- `--location` is required and must be a BYOH location.
- There is no `--provider` flag.
- Pools come from `--pool-file` (POOL_OPERATIONS.md §1), or inline with `--routed-network CIDR[,key=value...]`.

In one transaction, registration creates the `Sshable`, `VmHost`, `HostProvider`, `Address`, `ipv4_address`, `assigned_host_address` and `Strand` rows, plus an audit row in `byoh_operator_action`. `respirate` then drives the host to `accepting`. That takes about 4 minutes on a nested-virtualization VM and 15-25 minutes on bare metal, and **the host reboots once**.

## BMC credentials

Prefer `--bmc-pass-env VAR`. The config then stores only the variable's name, and every process that runs power operations (respirate) must have `VAR` set. `--bmc-password` stores the password in plaintext in `host_provider.config`.

```json
{
  "bmc": {
    "protocol": "redfish",
    "endpoint": "https://192.168.1.11",
    "username": "admin",
    "password_env": "LAB_BMC_PASS",
    "verify_ssl": false,
    "system_id": "1",
    "reset_type": "ForceRestart"
  }
}
```

## Capabilities

| Capability | Generic driver | Notes |
|---|---|---|
| Pool addresses | always | The declared pools, plus the management /32 as the host's own address |
| Hardware reset, power on, power status | with a BMC | Redfish `ComputerSystem.Reset`. Without a BMC, admin "Hardware Reset" wedges the host strand (CapabilityMissing is retried); do not use it. |
| Reimage | never | Reinstall the OS out of band, destroy the old VmHost, and register again. Host keys are pinned on first connect. |
| Server name, rDNS, data center | not set | Operator-owned |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `register-byoh-host` aborts with InvalidOption | A `--provider` flag; remove it |
| "net6 is already taken", "Address taken" | A leftover VmHost with the same `net6`, main IP or pool. Destroy it with `incr_destroy` first; never delete rows by hand. |
| `bootstrap_rhizome` never progresses | Root SSH fails. Check the key in `/root/.ssh/authorized_keys`, `PermitRootLogin prohibit-password`, and `nc -z <main ip> 22` from the control plane. |
| PrepHost fails | No outbound internet |
| `Hosting::CapabilityMissing ... reimage` | Expected; see Capabilities |
| BMC `Excon::Error::Unauthorized` | Wrong credentials, or the `--bmc-pass-env` variable is missing from respirate's environment. Test with `curl -ksu admin:$LAB_BMC_PASS https://<bmc>/redfish/v1/Systems`. |
| VM waits for capacity | No free pool address of the requested exposure; boot image missing; too few cores or hugepages. More in SETUP.md §11. |

Testing the driver: the specs in `spec/lib/hosting/generic_apis_spec.rb`, `spec/lib/hosting/redfish_client_spec.rb` and `spec/lib/byoh_registration*_spec.rb` stub Redfish with Excon. Running them is described in CLAUDE.md §7.
