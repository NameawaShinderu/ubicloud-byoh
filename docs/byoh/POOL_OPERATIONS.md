# BYOH pool operations

This page covers the address pools of a registered BYOH host: how to declare them, and how to change them with `bin/byoh-pool` without re-registering the host. The design is in [NETWORKING.md](NETWORKING.md) §3, §5 and §10. The canary and live runbooks are in [VERIFY.md](VERIFY.md).

Run every command on the control plane, from the repository root, with a working `.env.rb`:

```bash
bundle exec bin/byoh-pool COMMAND --host vh... [options]
```

Every command that changes something does so in one transaction, holding the host's row lock, and writes a `byoh-pool <command>` row to `byoh_operator_action`. Changing commands refuse a host that is not a BYOH host, meaning a generic host in a BYOH location. Move a host into its location first with `bin/byoh-host move-location`.

---

## 1. Declaring pools

### 1.1 pools.yaml (version 2)

```yaml
version: 2
uplink: ens5                       # informational; stored in the host config
ipv6_mode: ula                     # optional; derived from the IPv6 entry when absent
routed_networks:
  - cidr: 10.98.1.128/32
    delivery: fabric               # routed | onlink | fabric
    exposure: nat                  # public | nat | internal
    external:
      10.98.1.128: 43.204.120.21   # required for every usable address of a nat pool
  - cidr: 10.98.1.200/29
    delivery: onlink
    exposure: internal
    segment: 10.98.1.0/24          # onlink only: the uplink segment
    gateway: 10.98.1.1             # onlink only: inside the segment
    reserve: [10.98.1.201]         # never allocated
    # usable: all                  # onlink default "auto" reserves the segment's network, broadcast and gateway
  - cidr: 2a01:db8:1:2::/64        # at most one IPv6 entry; absent means ipv6_mode ula
    ndp: true                      # on-link /64: the host answers NDP for the VMs
```

The file is plain YAML and does not depend on any platform. Write it by hand, or let a tool produce it. `terraform/aws-byoh` writes one to `.generated/<workspace>/pools.yaml`: one `fabric`/`nat` entry per EIP-backed secondary IP, and one `fabric`/`internal` entry per `byoh_internal_private_ips` address.

A hand-written file for a LAN site, such as a Proxmox VM data plane behind pfSense ([SETUP_PROXMOX.md](SETUP_PROXMOX.md), NETWORKING §9.2). The LAN is 10.80.0.0/24 with the gateway at 10.80.0.1, and the pool addresses are outside the DHCP range:

```yaml
version: 2
uplink: ens18
routed_networks:
  # Variant A: reachable from the site only
  - cidr: 10.80.0.200/29
    delivery: onlink
    exposure: internal
    segment: 10.80.0.0/24
    gateway: 10.80.0.1
  # Variant B: pfSense 1:1 NATs each address to one of your public IPs
  - cidr: 10.80.0.208/30
    delivery: onlink
    exposure: nat
    segment: 10.80.0.0/24
    gateway: 10.80.0.1
    external:
      10.80.0.208: <public IP 1>   # replace; documentation ranges such as 203.0.113.0/24 are refused
      10.80.0.209: <public IP 2>
      10.80.0.210: <public IP 3>
      10.80.0.211: <public IP 4>
```

A routed block on rented bare metal or in a colo is a single entry: `cidr: <block>`, `delivery: routed`, `exposure: public`.

### 1.2 Inline form

`bin/register-byoh-host --routed-network` and `bin/byoh-pool --pool` take the same entries inline: `CIDR[,key=value...]`. `reserve=` and `external=P:E` may repeat, and a bare `ndp` means `ndp=true`.

```bash
--routed-network 10.98.1.128/32,delivery=fabric,exposure=nat,external=10.98.1.128:43.204.120.21
--routed-network 2a01:db8:1:2::/64,ndp
```

### 1.3 Rules

These are checked for every newly declared entry, by registration and by `add`, `annotate` and `ipv6 set`:

- CIDRs need an explicit prefix and no host bits. IPv4 pools are /24 or longer; `Address#validate` caps a block at 256 addresses. IPv6 is exactly one /64.
- The main IP is never in a pool. A block that contains it is refused. Only `<main-ip>/32` itself is accepted, as the host's own address.
- Pools may not overlap each other, any other registered address, another host's `net6`, the location's `overlay_ipv4_cidrs`, or a private subnet in the location.
- `public` must be globally routable.
- `nat` needs a globally routable, unique external IP for every usable address. The external IP may not be inside any pool or already be mapped elsewhere. `external_cidr: <block>` maps a whole block by offset instead.
- `onlink` needs a `segment` that contains the pool and a `gateway` inside the segment.
- `ipv6_mode: gua` is refused for a ULA, and when there is no IPv6 entry.

**Default exposure (C15).** A newly declared entry with no `exposure` becomes `public` when it is globally routable and `internal` otherwise, and the command prints a note. Entries stored before M2 are never re-validated against the `public` and `nat` rules: a stored bare CIDR keeps `routed`/`public`. `verify` warns about a stored `public` pool on special-use space. **Run `annotate` before relying on a pool's exposure.**

**Network and broadcast addresses.** `routed` and `fabric` pools use every address, because each VM address is a /32 route. `onlink` pools reserve the segment's network, broadcast and gateway when they fall inside the pool (`usable: auto`).

### 1.4 `uplink` (an interface) and `--uplink-ip` (an address)

Two different things, both about the host's uplink:

| | `uplink:` in pools.yaml | `--uplink-ip` of `host add` / `register-byoh-host` |
|---|---|---|
| What | The uplink **interface name** (`ens5`, `ens18`) | The uplink **IPv4 address**: the source address of the default route |
| Default | none | detected by host preflight from `ip route show default` |
| Stored | in the host's provider config | `provider_config["uplink_ip"]` |
| Used for | Nothing is configured from it. Since M4 host preflight warns (`PF17-uplink`) when it is not an interface of the host or not the one the default route leaves by | PF17 (contract C5): no pool may contain the uplink IP, the main IP or the default gateway, a failure that cannot be accepted. Give it only for a host with more than one default route, where preflight cannot tell (`PF17-route`) |

The main IP (`--main-ip`, the address the control plane logs in to) is usually the uplink IP. They differ behind NAT, for example a host reached at a public address its router forwards. `GenericApis#pull_ips` still skips only the main IP when it builds the host's own address (until M8).

---

## 2. Commands

| Command | What it does |
|---|---|
| `list --host H` | Pools with delivery and exposure; every address with its external IP, exposure and state (VM, reserved or free) |
| `export --host H [--set delivery=D,exposure=E] [--external-map FILE]` | Prints pools.yaml v2 built from the registered pools, so a /29 stays a /29 and /32s stay /32s. The output is valid input for `annotate`. |
| `add --host H (--pool ... \| --pool-file F)` | Registers new IPv4 pools. No VM is touched. Refuses IPv6 and CIDRs that are already registered. |
| `remove --host H --pool CIDR [--drain [--drain-timeout S]]` | Removes an IPv4 pool. Refuses while VMs use it, unless `--drain` |
| `remap --host H --ip P --external E` | Gives one address of a `nat` pool a new external IP |
| `annotate --host H (--pool ... \| --pool-file F)` | Changes delivery, exposure, reserve and external IPs of registered pools in place |
| `ipv6 set --host H --cidr V6/64[,ndp] [--mode gua\|ula]` | Replaces the host's IPv6 network. Empty host only. |
| `verify --host H` | Database-only checks. Exits 1 on any failure. |
| `trace IP` | Finds a pool IP or external IP: pool, host, VM, or reserved/free. For a VM it prints the netns `nft` and `conntrack` commands to run on the host. |

### 2.1 export and `--external-map`

`--external-map FILE` takes either a YAML map `{pool IP: external IP}` or the raw JSON of `aws ec2 describe-addresses`. The YAML map is the platform-neutral form; write it from your 1:1 NAT table (pfSense, a cloud console, or a provider panel):

```yaml
# map.yaml
10.80.0.208: <public IP 1>
10.80.0.209: <public IP 2>
```

```bash
bundle exec bin/byoh-pool export --host vh... --set exposure=nat --external-map map.yaml > pools-nat.yaml
bundle exec bin/byoh-pool annotate --host vh... --pool-file pools-nat.yaml
```

`--set` applies to every pool of the host. When only some pools change, edit the exported file before `annotate`.

**AWS only (optional).** The JSON is recognised by its `Addresses` key; each address maps `PrivateIpAddress` to `PublicIp`, and addresses without a private IP are skipped.

```bash
aws ec2 describe-addresses --output json > eips.json        # on the operator workstation
bundle exec bin/byoh-pool export --host vh... --set delivery=fabric,exposure=nat \
  --external-map eips.json > live-pools.yaml
bundle exec bin/byoh-pool annotate --host vh... --pool-file live-pools.yaml
```

Under `nat`, an address without an external IP becomes `reserve` in a block, and turns a /32 into `exposure: internal`. Each such change is printed as a note. Review the file before `annotate`.

Use `describe-addresses`, not terraform output, for a live host: terraform state may not match the live EIPs.

### 2.2 remove --drain

`--drain` reserves every address of the pool, destroys only that pool's VMs, and polls every 5 seconds until they are gone (default 600 seconds). On timeout it stops and the addresses stay reserved; run it again later. It refuses up front when a VM in the pool belongs to a service that destroys its own VMs (Postgres, runners, Kubernetes, MinIO, VictoriaMetrics, inference, Parseable) or has `prevent_destroy` set.

### 2.3 What remap and annotate refresh

After `remap` or `annotate`, each affected VM gets:
- its `sshable.host` set to `cp_reach_ip4`, or its IPv6 address;
- the `resource_name` of its open IPv4 billing record renamed (§3);
- a DNS refresh for its load balancers and Postgres resources.

`annotate` refuses to reserve an address a VM holds, and to move a pool with VMs between internet (`public`/`nat`) and `internal`.

---

## 3. Billing

The IPv4 billing record of a VM is named after the address customers see, always written as a /32:

| Pool exposure | `resource_name` | Billed |
|---|---|---|
| `public` | `<pool IP>/32` (same as upstream) | yes |
| `nat` | `<external IP>/32` | yes |
| `internal` | — | no IPv4 record |

Rates for a BYOH location come from the overlay directory `BILLING_RATES_EXTRA_DIR` ([VERIFY.md](VERIFY.md) §1.1). `remap` and `annotate` refuse with a clear error when a VM's rate is not loaded in the running process.

---

## 4. Egress settings of the location

VMs without IPv4, and by default VMs on an `internal` pool, leave through the host's NAT table `inet byoh_egress` in `/etc/nftables.d/1-byoh-egress.conf`. These location profile keys control it (`bin/byoh-location set --location L ...`):

| Key | Flag | Default | Effect |
|---|---|---|---|
| `vm_egress_nat4` | `--[no-]vm-egress-nat4` | true | VMs without IPv4 get outbound IPv4 through the host NAT. Off: no IPv4 egress for them. |
| `internal_egress` | `--internal-egress host_nat\|site` | `host_nat` | `host_nat`: `internal` VMs also use the host NAT. `site`: they SNAT to their pool address, and the site's own NAT carries them. |
| `egress_smtp` | `--[no-]egress-smtp` | false | TCP 25 through the host NAT is dropped unless set |
| `vm_egress_deny` | `--egress-deny CIDRS` | none | Added to the networks host-NAT traffic may not reach. The table always denies `underlay_cidrs`, `cp_source_cidrs` and `host_mgmt_allow` too, and drops every VM's original-direction traffic to RFC 1918 networks in that list. |

The table on each host is built from the profile at install time. When `set` changes these keys it starts a strand that reinstalls the table on every host of the location that is past prep, and prints their ids; a host before prep gets the new settings from prep. `bin/byoh-host move-location` into a BYOH location starts the same strand. To reinstall it by hand:

```bash
bundle exec bin/byoh-host setup-egress-nat --host vh...
```

VMs pick up a change of `vm_egress_nat4` or `internal_egress` only when they are recreated.

---

## 5. Rollback levels

Full steps are in [VERIFY.md](VERIFY.md) §4.

| Level | After | Summary |
|---|---|---|
| R3 | host move, annotate or VM recreate | revoke, destroy the location's VMs, `move-location --rollback-to hetzner-fsn1 --empty-only` (resets the pools to `routed`/`public` with no reserve or external IPs, and removes the egress table) |
| R2 | location create | revoke, `bin/byoh-location delete` |
| R1 | code deploy | `bin/byoh-host export-audit`, migration `down` to 20261012, check out `aws-mumbai-m2-pre`, `install_rhizome`, restart. Only when no BYOH billing record exists in the open invoice month. |
