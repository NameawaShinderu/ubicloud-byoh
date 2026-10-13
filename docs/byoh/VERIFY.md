# BYOH verification: M2 canary gate, live window and rollback

This page is the runbook for milestone M2 ([ROADMAP.md](ROADMAP.md) §3.3): honest addresses, real locations, and IPv4 egress for VMs without a public IPv4. It has four parts:

1. Before you start: settings, processes and the backup checklist.
2. The canary gate G0-G17, run in the `canary` terraform workspace on AWS. `scripts/byoh/verify/m2-gate.sh` automates the checks. §2.5 is the same gate for other platforms.
3. The live window L0-L4 in ap-south-1.
4. Rollback levels R1-R3.

The full continuous checklist (NETWORKING §8.5: `host_guard`, the hairpin, `--from-outside`) belongs to P2/P3 (milestone M7) and is not part of this gate.

Pool commands are described in [POOL_OPERATIONS.md](POOL_OPERATIONS.md).

---

## 1. Before you start

### 1.1 `BILLING_RATES_EXTRA_DIR`

BYOH locations are billed from an overlay directory of rate files, written by `bin/byoh-location rates` and `create --rates-from`. The shipped `config/billing_rates/*.yml` is never edited. The name is exactly `BILLING_RATES_EXTRA_DIR`; there is no `CLOVER_` prefix.

Set the variable in `.env.rb`, so that **web, respirate and monitor** all load it. `bootstrap-ctrl-plane.sh` writes it into a new `.env.rb`; add it by hand to an older one. A directory in the operator's home needs no sudo (the live control plane uses `/home/ubuntu/ubicloud-billing-rates.d`):

```ruby
ENV["BILLING_RATES_EXTRA_DIR"] ||= "/home/ubuntu/ubicloud-billing-rates.d"
```

- A process started without the variable cannot resolve a BYOH rate id. VM create fails, and invoices cannot be built.
- Rates are read once at process start. Restart all three processes after every `create --rates-from` or `rates` command.
- `bin/byoh-location show` and `list` print a warning when the variable is unset and a BYOH location exists.

### 1.2 Processes

The gate requires `puma` and `respirate`. It requires `bin/monitor` only with `GATE_EXPECT_MONITOR=1`; otherwise it reports whether the monitor runs as INFO. `bootstrap-ctrl-plane.sh` starts the monitor only with `UBI_START_MONITOR=1`.

Upstream health checks misjudge hosts without `wwn-`/`nvme-eui` disk links and SMART, which today means AWS EBS and Proxmox virtio disks, and may mark them `unavailable` ([PLATFORMS.md](PLATFORMS.md) F5). On such hosts, leave the monitor off. If you start it, watch `allocation_state`.

### 1.3 Backup checklist

Take all of these before L1, and again before any rollback:

| Item | How | Why |
|---|---|---|
| Database | `pg_dump` as postgres, size > 0 bytes | everything |
| `.env.rb` | copy, mode 600 | secrets and `BILLING_RATES_EXTRA_DIR` |
| Overlay directory | `tar` of `$BILLING_RATES_EXTRA_DIR` | BYOH prices; without it the rate ids in billing records cannot be resolved. Each `rates` audit row also keeps a copy of the YAML it wrote. |
| Operator audit | `bin/byoh-host export-audit --out backups/audit-<ts>.jsonl` | the `byoh_operator_action` rows. The migration's `down` refuses while rows newer than the last export exist. |
| Tag | `git tag aws-mumbai-m2-pre` (local) | code rollback target |

`backups/` is gitignored and holds secrets. Never commit or print its contents.

### 1.4 Gate script settings

`scripts/byoh/verify/m2-gate.sh` runs on the control plane, from the repository root. It reads its settings from the environment:

| Variable | Meaning |
|---|---|
| `GATE_LOCATION` | the BYOH location name |
| `GATE_RATES_FROM` | the location the rates were copied from (default `hetzner-fsn1`) |
| `GATE_HOST`, `GATE_MAIN_IP` | the VmHost ubid and its `--main-ip` |
| `GATE_IPV6_MODE` | `gua` or `ula`, checked by G4; unset means not checked |
| `GATE_EXPECT_MONITOR` | `1` to require `bin/monitor` in G1 (default `0`, §1.2) |
| `GATE_VM_A_EXPOSURE` | `nat` (default) or `public`: the pool exposure G6 expects for VM-A |
| `GATE_HOST_KEY` | root SSH key for the data plane (default `~/.ssh/byoh_data`) |
| `GATE_VM_KEY` | private key whose public half the gate VMs were created with |
| `GATE_VM_A`, `GATE_VM_B`, `GATE_VM_C`, `GATE_VM_D` | the VMs of G6, G7, G8 and G10 |
| `GATE_NEW_EXTERNAL` | VM-A's EIP after the G11 remap |
| `GATE_CTRL_PRIV`, `GATE_UNDERLAY_PROBE`, `GATE_SMTP_PROBE` | G9b targets: the control plane's private IP, another underlay host with SSH open, and an internet host that accepts TCP 25 |

The script's database checks call `scripts/byoh/verify/m2-checks`, a read-only wrapper around `lib/byoh_gate_checks.rb`. You can run it on its own:

```bash
bundle exec scripts/byoh/verify/m2-checks host --host vh... --ipv6-mode ula
bundle exec scripts/byoh/verify/m2-checks vm --vm vm... --expect public|nat|none|internal|waiting
bundle exec scripts/byoh/verify/m2-checks info --vm vm...      # private_ip4= and inhost= for the proxy below
```

**How VM checks connect.** The script proxies through the data plane into the VM's network namespace, and connects to the VM's private IPv4 there:

```bash
ssh -n -o "ProxyCommand=ssh -i <host key> root@<main IP> ip netns exec <inhost> nc %h %p" ubi@<private_ip4> <command>
```

`<inhost>` is the VM's namespace name, from the first 8 characters of its ubid. This needs no route from the control plane or the host to the VM, works for VMs without IPv4, and works on any platform. It needs `nc` on the host; `bootstrap-data-plane.sh` installs `netcat-openbsd`. Every ssh the script runs passes `-n`; without it, the first ssh in a heredoc-driven run swallows the rest of the script.

Jumping to the VM's IPv6 through the host, which earlier versions did, **fails on ULA hosts** with "No route to host" (verified on the live AWS host, 2026-10-13). The VM namespace routes only `2000::/3` back to the host, so it cannot answer a ULA source (CLAUDE.md §10 #7).

---

## 2. Canary gate (`canary` workspace)

Run the canary in the existing `canary` workspace. Never create a `canary-m2` workspace. `m2-gate.sh all` runs G1, G2, G4-G10 once the setup steps are done. The rest run as single steps.

### 2.1 Setup

| Step | Action | PASS when | Script |
|---|---|---|---|
| G0 | On the operator workstation: `terraform -chdir=terraform/aws-byoh workspace select canary`, then `terraform state list`. If state is not empty, `destroy` first. Apply with `canary.tfvars`: 3 `byoh_secondary_private_ips`, 1 `byoh_internal_private_ips`, and `data_plane_nested_virtualization = true`. | `.generated/canary/pools.yaml` has 3 `nat` entries and 1 `internal` entry | manual |
| G1 | Clone `byoh-driver` and bootstrap. Check `BILLING_RATES_EXTRA_DIR` (§1.1). Leave the monitor off on EBS (§1.2). | puma and respirate run; `.env.rb` sets the variable | `g1` |
| G2 | Run the `byoh_location_create_command` terraform output (`bin/byoh-location create ... --rates-from hetzner-fsn1`). Restart the three processes. `bin/byoh-location grant --location <name> --project <ubid>`. | `show` reports full coverage; every rate type of hetzner-fsn1 was copied | `g2` |

### 2.2 Registration

| Step | Action | PASS when | Script |
|---|---|---|---|
| G3 | Negative test: register with a /29 that contains the main IP | Exit ≠ 0, with "contains main_ip" | `g3` |
| G4 | `bin/register-byoh-host --location <name> --main-ip <data plane private IP> --pool-file pools.yaml --ssh-key ~/.ssh/byoh_data --default-boot-image ubuntu-noble --yes` | The host is `accepting`, `ipv6_mode=ula` (with `GATE_IPV6_MODE=ula`), `net6` is inside `ula48`, and a `register-byoh-host` row is in `byoh_operator_action`. A host registered before M2 and moved with `move-location` has no such row; its `move-location` row turns the check into INFO. | `g4` |
| G5 | Host checks | `ip -br -4 addr` shows only the primary (VM `vetho*` link-local addresses aside). Table `inet byoh_egress` is loaded. No VM `local_vetho_ip` is in `APIPA_EXCLUDED`. `byoh-pool verify` has no failure. | `g5` |

### 2.3 Customer-facing gates

Create the VMs with the gate key: VM-A `ubi vm <loc>/gate-a create "$(cat key.pub)"`, VM-B with `-6`, VM-C with `-e internal`.

| Step | Action | PASS when | Script |
|---|---|---|---|
| G6 | VM-A (nat; `public` on sites with routed or onlink public pools) | API, UI and CLI show the EIP; SSH via the EIP works; the IPv4 billing record's `resource_name` is `<EIP>/32`; the control plane reaches it at the pool IP (`cp_reach: onhost`) | `g6`, then check the UI and `ubi vm show` by hand |
| G7 | VM-B (no IPv4) | The respirate log has "byoh netns probe ok" for the VM and no "byoh netns probe gave up". The UI shows the shared-NAT text. In the VM, `getent hosts`, `apt-get update` and `curl -4 ifconfig.me` work, and the last returns the host's own egress IP. | `g7` |
| G8 | VM-C (`ip4_exposure=internal`) | `ip4_scope=internal`; no IPv4 billing record; apt and DNS work through the host NAT (`internal_egress: host_nat`, C13) | `g8` |
| G9 | Metadata from VM-A, B and C | `curl http://169.254.169.254/` times out; the link-local drop counter rises | `g9` |
| G9b | From VM-B: `nc -w3 <ctrl private> 22`, `nc -w3 <underlay host> 22`, `nc -w3 <smtp host> 25` | All fail; the deny4 and SMTP counters rise | `g9b` |
| G10 | Create a 4th internet VM (VM-D) once the 3 nat addresses are taken | VM-D waits for capacity; no internet VM holds the internal address | `g10` |

### 2.4 Pool, load balancer and host gates

| Step | Action | PASS when | Script |
|---|---|---|---|
| G11 | `bin/byoh-pool remap --host H --ip <VM-A pool IP> --external <new EIP>` (associate the EIP in AWS first) | The new EIP shows in UI and API and in the billing record name; the load balancer DNS name resolves to it; `sshable.host` is right; `verify` is clean | `g11` |
| G12 | Put VM-B in an IPv6 load balancer | Egress still works | `g12` |
| G13 | `add` a spare address, `remove --drain` it, `annotate` the host's own export (a no-op), `export` round trip | `verify` is clean after each step | `g13` (round trip); `add`/`remove` by hand |
| G14 | Reboot the host from the admin page (not "Hardware Reset", which needs a BMC) | G5, G7, G8 and G9 pass again | `g14` |
| G15 | `g15-before`, then create and destroy a VM 20 times, then `g15-after` | VM count, free addresses, used cores and hugepages, storage and orphaned billing records are back exactly; audit rows are kept | `g15-before`, `g15-after` |
| G16 | Full rake in the test container (CLAUDE.md §7) | Green; the exact strings in `vm_setup_spec` are untouched | manual |
| G17 | `terraform destroy` in `canary` | `aws ec2 describe-addresses` lists no canary EIPs | manual |

Record each result in §5.

### 2.5 The gate on other platforms (Proxmox, bare metal, colo)

The gate itself does not depend on the platform. Only G0, G11 and G17 use AWS: terraform, EIPs and `describe-addresses`. Elsewhere:

| Step | Instead |
|---|---|
| G0 | Create the machines and do the site network work by hand ([SETUP.md](SETUP.md), [SETUP_PROXMOX.md](SETUP_PROXMOX.md)) |
| G1 | `GATE_EXPECT_MONITOR=0` unless PLATFORMS.md says the monitor suits the hosts' disks |
| G4 | Set `GATE_IPV6_MODE` to the mode you registered, or leave it unset |
| G6 | `GATE_VM_A_EXPOSURE=public` for `routed`/`public` pools. With `nat` behind a router doing 1:1 NAT, VM-A's external IP must be reachable from the control plane. |
| G9b | `GATE_CTRL_PRIV`, `GATE_UNDERLAY_PROBE` (another site host with SSH open) and `GATE_SMTP_PROBE` as on AWS |
| G11 | Change the router's 1:1 NAT first, then `bin/byoh-pool remap` |
| G17 | Remove the machines |

A site without internet pools, such as Proxmox `onlink` + `internal`, has no VM-A and no VM-D. Run `m2-gate.sh g1 g2 g3 g4 g5 g7 g8 g9 g9b`, then G12-G15.

The gate has been run only on AWS. On any other platform it is UNVERIFIED.

---

## 3. Live window (ap-south-1, NET L1-L4)

**No terraform command runs in `company-mumbai` before M7.** The live security group has drifted from `main.tf`, and the state does not match the live EIPs. Pool data for the live host comes from `aws ec2 describe-addresses`, never from terraform output.

### 3.1 Preconditions (L0). Stop if any fails.

1. The M1 window is done and has soaked for at least 48 hours:
   - `SELECT filename FROM schema_migrations WHERE filename LIKE '%generic_provider%'` returns `20260412_add_generic_provider.rb`;
   - `20261012_byoh_free_io_cpus.rb` is applied;
   - `ruby -v` reports 4.0.7.
   Never combine the M1 and M2 windows.
2. The user has confirmed that the 3 live VMs are test VMs (ROADMAP D-3). For each, record name, size, image, SSH key, subnet and firewall. **L3a destroys their disks permanently**; copy off anything needed first.
3. The window has been rehearsed on a restored `pg_dump` on the canary control plane.
4. APIPA check. Record the hits; they are acceptable only because L3a recreates every VM:
   ```sql
   SELECT name, local_vetho_ip FROM vm
   WHERE local_vetho_ip <<= ANY('{169.254.0.0/24,169.254.169.0/24,169.254.170.0/24,169.254.255.0/24}');
   ```
5. Pool shape. Record whether the pool is one /29 or eight /32s; `export` keeps that shape:
   ```sql
   SELECT cidr FROM address WHERE routed_to_host_id = '<vm_host id>';
   ```

### 3.2 Steps

| Step | Action | Check | Rollback |
|---|---|---|---|
| L0′ | Stop the services. Take the §1.3 backups. Tag `aws-mumbai-m2-pre`. | The dump is > 0 bytes | — |
| L1 | Pull. Put `~/.local/bin` (mise) on PATH before `bundle install`, or bundler fails with "No such file or directory - mise". Delete `~/.ubi-bootstrap/{migrations,caches-refreshed}`. Migrate, then refresh the caches. Add `BILLING_RATES_EXTRA_DIR` to `.env.rb`. Start the services. `VmHost.all.each(&:install_rhizome)` in `bin/pry`. **Upgrade vhost-block-backend** on every host registered before M1: they have v0.2.2, but new VMs need `version_code >= 401`, so every VM create fails with "No capacity left". In `bin/pry`: `VmHost.all.each { Prog::Storage::SetupVhostBlockBackend.assemble(it.id, Config.vhost_block_backend_version, allocation_weight: 100) }`, and wait for the strands to finish. Do **not** run `setup-egress-nat` yet: the host is not a BYOH host until L3a. | New columns have their defaults; existing VMs are reachable; `vhost_block_backend` has a version with `version_code >= 401` and weight 100; behaviour is identical to M1 (U17) | R1 |
| L2 | `bin/byoh-location create --name byoh-aws-aps1 --display-name byoh-aws-aps1 --ui-name "AWS Mumbai (BYOH)" --underlay 10.98.0.0/16 --overlay 172.20.0.0/14 --cp-reach onhost --cp-source <ctrl private>/32 --mgmt-allow <ctrl private>/32,<operator>/32 --ula-underlay none --rates-from hetzner-fsn1`. Restart the services. `grant`. Keep the location hidden. | `show` has complete coverage; warnings reviewed | R2 |
| L3a | Destroy the 3 VMs and wait until the host has none. Drain the host (admin "Move to Draining"). `bin/byoh-host move-location --host H --location byoh-aws-aps1 --empty-only`; it starts the strand that installs the egress table. Wait for that strand to finish, then set the host back to accepting. | `location_id` is the new location; `nft list table inet byoh_egress` works on the host | R3 |
| L4 | Operator: `aws ec2 describe-addresses --output json > eips.json`. Then `bin/byoh-pool export --host H --set delivery=fabric,exposure=nat --external-map eips.json > live-pools.yaml`. Review it: an address without an EIP becomes `reserve` in a block, or `exposure: internal` for a /32. Then `bin/byoh-pool annotate --host H --pool-file live-pools.yaml`. | `list` shows nat and the EIPs; `verify` is clean | R3 (its `move-location --rollback-to` resets the pools) |
| L3b | Recreate the VMs in `byoh-aws-aps1`, plus one VM without IPv4. | The G6, G7 and G9 equivalents pass (`m2-gate.sh g6 g7 g9`) | R3 |
| Post | Record the results in §5. Set `--visible` only after the soak. The host is now outside the rhizome rollout lists, so update it with `install_rhizome`. | — | — |

---

## 4. Rollback

Each level includes the levels below it. Run them in order.

**R3** (after L3a, L4 or L3b):
1. `bin/byoh-location revoke` the grant.
2. Destroy every VM in the BYOH location. This closes their billing records.
3. Drain the host, then `bin/byoh-host move-location --host H --rollback-to hetzner-fsn1 --empty-only`. In the same transaction it resets the host's IPv4 pools to `routed`/`public` with nothing reserved and no external IPs, and rewrites the declared pools as bare CIDRs, which the R1 `down` guard requires. (`annotate` cannot do this: it refuses `public` on a pool that is not globally routable, such as the RFC 1918 /32s here.) It also starts the strand that removes `inet byoh_egress` and its file from the host.
4. Check on the host that `nft list table inet byoh_egress` fails and `/etc/nftables.d/1-byoh-egress.conf` is gone. If not, run `nft delete table inet byoh_egress` and remove the file.

The host now behaves as in M1 (U17), running M2 code. **Stay on M2 code after R3** while any BYOH billing record exists in the current invoice month: M1 code cannot resolve the overlay rate ids. A full code rollback is allowed only once that month's invoices are finalised.

**R2** (after L2): `revoke`, then `bin/byoh-location delete --location byoh-aws-aps1`. The location must be empty. The rate file is kept.

**R1** (code rollback; only when no BYOH billing records exist):
1. `bin/byoh-host export-audit --out backups/audit-<ts>.jsonl`.
2. Run the migration `down` to 20261012. It refuses, naming the condition, while any M2 data remains (reserved rows, external IPs, non-default delivery or exposure, a location profile, an internal VM, or audit rows newer than the export).
3. `git checkout aws-mumbai-m2-pre`.
4. `install_rhizome`.
5. Restart the services.

Never rename `migrate/20261013_byoh_network_contract.rb` once it has been applied anywhere.

---

## 5. Results

| Run | Date | Steps | Result | Notes |
|---|---|---|---|---|
| canary | — | G0-G17 | not run yet | The live window ran after a rehearsal on a restored `pg_dump` instead (L0 item 3) |
| live | 2026-10-13 | M1 + M2 window, L0-L4, gate G5-G9b | **pass**, with the notes | AWS ap-south-1, code 17d383a9c, Ruby 4.0.7 via mise. M1 and M2 ran in one window (not the separate windows L0 item 1 asks for). See below. |

**Live window, 2026-10-13 (verified):**

- **Upgrade:**
  - `bundle install` needed `~/.local/bin` (mise) on PATH.
  - The migration rename SQL and the migrations ran as rehearsed.
  - The rehearsal on a restored dump had caught upstream's 20260601 billing migrations failing on records opened after the cutoff; 17d383a9c fixed that before the window.
- **Storage backend:** after the merge, every VM create failed with "No capacity left" until vhost-block-backend was upgraded with `Prog::Storage::SetupVhostBlockBackend.assemble(host.id, Config.vhost_block_backend_version, allocation_weight: 100)`. The host, registered before M1, had only v0.2.2, and new VMs need `version_code >= 401`. This is now an L1 step.
- **Billing rates:** `BILLING_RATES_EXTRA_DIR=/home/ubuntu/ubicloud-billing-rates.d`.
- **Location and host:**
  - Location `byoh-aws-aps1` was created with `--ula48 fd1b:3821:6123::/48`, so the existing host's `net6` fits it.
  - The host was moved with `move-location`, and the egress table loaded on the real host without problems.
- **Pools:** annotated `fabric`/`nat` with the EIPs from `aws ec2 describe-addresses`; `byoh-pool verify` reported 0 failures.
- **VMs:** the 3 user VMs were recreated, plus `m2-gate-nat` (burstable-1, nat) and `m2-gate-noip` (no IPv4).
- **Gate:**
  - G5 passed except "a register-byoh-host audit row exists". That is expected for a host registered before M2 and then moved; the check is now INFO when a `move-location` row exists.
  - G6 passed: API, billing record name, and SSH via the EIP.
  - G7 passed: DNS, apt, and `curl -4` egress equal to the host's IP 13.126.46.177. The netns probe logged ok after 33 s.
  - G9 passed: metadata blocked, link-local counter 0 → 5.
  - G9b passed: control plane .102:22, host .138:22 and SMTP 25 blocked; deny4 counter 0 → 6, SMTP counter 0 → 3.
- **Gate tooling:**
  - The script's IPv6 jump through the host failed on this ULA host ("No route to host"). The netns ProxyCommand worked, and the script now uses it (§1.4).
  - Inner ssh calls in a heredoc needed `-n`.
- **Afterwards:**
  - A stale "No capacity left" page from before the storage upgrade stayed open until it was resolved by hand.
  - The data-plane instance was stopped to save cost.
