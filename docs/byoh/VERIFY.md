# BYOH verification: M2 canary gate, live window, rollback and the M4 gates

This page is the runbook for milestone M2 ([ROADMAP.md](ROADMAP.md) §3.3): honest addresses, real locations, and IPv4 egress for VMs without a public IPv4. It has four parts:

1. Before you start: settings, processes and the backup checklist.
2. The canary gate G0-G17, run in the `canary` terraform workspace on AWS. `scripts/byoh/verify/m2-gate.sh` automates the checks. §2.5 is the same gate for other platforms.
3. The live window L0-L4 in ap-south-1.
4. Rollback levels R1-R3.

§6 holds the M4 gates G-M4-1 to G-M4-6 (one-command site and host, the F5 monitor soak, preflight).

The full continuous checklist (NETWORKING §8.5: `host_guard`, the hairpin, `--from-outside`) belongs to P2/P3 (milestone M7) and is not part of this gate.

Pool commands are described in [POOL_OPERATIONS.md](POOL_OPERATIONS.md).

---

## 1. Before you start

### 1.1 `BILLING_RATES_EXTRA_DIR`

BYOH locations are billed from an overlay directory of rate files, written by `bin/byoh-location rates` and `create --rates-from`. The shipped `config/billing_rates/*.yml` is never edited. The name is exactly `BILLING_RATES_EXTRA_DIR`; there is no `CLOVER_` prefix.

Set the variable in `.env.rb`, so that **web, respirate and monitor** all load it. `bootstrap-dev-ctrl-plane.sh` writes it into a new `.env.rb`; add it by hand to an older one. On the development layout, a directory in the operator's home needs no sudo (the live control plane uses `/home/ubuntu/ubicloud-billing-rates.d`):

```ruby
ENV["BILLING_RATES_EXTRA_DIR"] ||= "/home/ubuntu/ubicloud-billing-rates.d"
```

On a packaged control plane (`scripts/byoh/install.sh`) the variable is in `/etc/ubicloud/env` and defaults to `/var/lib/ubicloud/billing_rates.d`. The services run as user `ubicloud` with `ProtectHome=yes`, so they cannot see anything under `/home`, `/root` or `/run/user`: never point the variable at the operator's home there, and move the files when you migrate a development control plane. G1 reads the value with `ubicloud-admin env get BILLING_RATES_EXTRA_DIR --reveal`, fails a path that resolves under those three, and checks that user `ubicloud` can read and write the directory, so run the gate as root or with passwordless sudo.

- A process started without the variable cannot resolve a BYOH rate id. VM create fails, and invoices cannot be built.
- Rates are read once at process start. Restart all three processes after every `create --rates-from` or `rates` command.
- `bin/byoh-location show` and `list` print a warning when the variable is unset and a BYOH location exists.

### 1.2 Processes

The gate requires `puma` and `respirate`. It requires `bin/monitor` only with `GATE_EXPECT_MONITOR=1`; otherwise it reports whether the monitor runs as INFO. `bootstrap-dev-ctrl-plane.sh` starts the monitor only with `UBI_START_MONITOR=1`.

The gate finds out how the control plane runs (`GATE_SERVICES`, default `auto`). When `ubicloud.target` is active or enabled, it is `systemd`: G1 checks the units `ubicloud-web`, `ubicloud-respirate` and `ubicloud-monitor`, and G7 reads the respirate log from the journal of `ubicloud-respirate.service` (`GATE_RESPIRATE_LOG=journal`), which needs root or group `adm` or `systemd-journal` (otherwise the gate tries `sudo -n`, and fails the step if it cannot read the log). Otherwise it is `tmux`: G1 looks for the processes and G7 reads `/tmp/respirate.log`. Installed units that are neither active nor enabled count as `tmux`, because that is the state while a development control plane is migrated (after `install.sh --no-start`, before the cutover) and after a rollback to it; `/etc/ubicloud/env` alone does not matter. `bootstrap-dev-ctrl-plane.sh` judges the target the same way. Set `GATE_SERVICES=tmux` or `systemd` to override the guess. The database steps run `bundle exec` from the current directory, which on a packaged control plane only reaches the database as user `ubicloud` with the env file; that combination is UNVERIFIED.

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
| `GATE_EXTERNAL_SSH_VIA` | `[user@]host` outside the site that G6 jumps through (`ssh -J`) to reach VM-A's external IP. Default: connect directly from the control plane. Set it when a router 1:1 NATs the external IP without NAT reflection and the control plane is inside the site. UNVERIFIED: never run. |
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
| G0 | On the operator workstation: `terraform -chdir=terraform/aws-byoh workspace select canary`, then `terraform state list`. If state is not empty, `destroy` first. Apply with `canary.tfvars`: 3 `byoh_secondary_private_ips`, 1 `byoh_internal_private_ips`, `data_plane_nested_virtualization = true`, and `operator_ssh_cidr` and `web_ui_cidr` (required since M4). | `.generated/canary/pools.yaml` has 3 `nat` entries and 1 `internal` entry | manual |
| G1 | Clone `byoh-driver` and bootstrap. Check `BILLING_RATES_EXTRA_DIR` (§1.1). Leave the monitor off on EBS (§1.2). | puma and respirate run; `.env.rb` sets the variable | `g1` |
| G2 | Run the `byoh_location_create_command` terraform output (since M4 `sudo ubicloud-admin site add ... --rates-from hetzner-fsn1`; on the development control plane of G1, `packaging/bin/ubicloud-admin --dev site add ...` or `bin/byoh-location add ...` with the same options). Restart the three processes. `bin/byoh-location grant --location <name> --project <ubid>`. | `show` reports full coverage; every rate type of hetzner-fsn1 was copied | `g2` |

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
| G6 | `GATE_VM_A_EXPOSURE=public` for `routed`/`public` pools. With `nat` behind a router doing 1:1 NAT, the SSH to VM-A's external IP must start outside the site when NAT reflection is off: set `GATE_EXTERNAL_SSH_VIA` to an outside host, or expect that one line to FAIL. |
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

---

## 6. M4 gates (G-M4-1 to G-M4-6)

Milestone M4 ([ROADMAP.md](ROADMAP.md) §3.3) adds `ubicloud-admin site add` and `host add --ssh`, host preflight, and the F4/F5/F6/F9/F10 portability fixes. Its exit gates need real infrastructure, which the build machine does not have. They are **scripted, not run**: each row says what has been checked locally instead. Record runs in §6.2.

| Gate | What | Script | Pass when | Status |
|---|---|---|---|---|
| G-M4-1 | E2 on AWS: a **fresh** terraform workspace (never `company-mumbai`), `install.sh`, then `site add` and `host add --ssh` exactly as [recipes/aws.md](recipes/aws.md) gives them | `scripts/byoh/verify/m4-e2.sh` with `PLATFORM=aws` | `host add` exits 0, the host reaches `accepting`, and the M2 gate steps pass (default `g1 g2 g4 g5`; `GATE_STEPS` for more once VMs exist) | UNVERIFIED, not run |
| G-M4-2 | E2 on Proxmox: one VM built from [recipes/proxmox.md](recipes/proxmox.md), the same three commands | `m4-e2.sh` with `PLATFORM=proxmox` | as G-M4-1 | UNVERIFIED, not run |
| G-M4-3 | F5 soak on an EBS-backed host (the G-M4-1 host) | `scripts/byoh/verify/m4-f5-soak.sh --host vh... --hours 24 --interval 600`, monitor started by hand | every sample passes: the monitor runs; no `unavailable` label; `accepting`; `checkup` unset; no open non-info page for the host, and none raised since the soak began and resolved again; `perform_health_checks` true over a fresh session; no down reading of the host in the monitor's log since the last sample | UNVERIFIED, not run |
| G-M4-4 | F5 soak on a virtio host (the G-M4-2 VM) | as G-M4-3 | as G-M4-3 | UNVERIFIED, not run |
| G-M4-5 | F5 soak on an LVM-root host (Ubuntu's default LVM install, own hardware or a VM) | as G-M4-3 | as G-M4-3 | UNVERIFIED, not run |
| G-M4-6 | Preflight catches no `/dev/kvm` or a kvm64-class CPU (PF3), a pool containing the uplink IP (PF17), and a hybrid CPU (`PF8-hybrid`) | `scripts/byoh/test/preflight-fixtures.sh`, `scripts/byoh/test/m4-host-add.sh` (runs A, B, C), `spec/lib/byoh_host_preflight_spec.rb`, `rhizome/host/spec/ubicloud_host_parity_spec.rb` | each is a `fail` that stops `host add` before a change, and none can be accepted except `PF8-hybrid` | **Pass on fixtures and `ubi-m4-*` containers** (2026-10-15). The evidence is fixture files and containers without `/dev/kvm`, not real hardware: the kvm64 and hybrid fixtures are synthesised (`scripts/byoh/test/fixtures/host/{kvm64-model,kvm64-vmx,intel-hybrid,arm-biglittle}`) |

### 6.1 Running the scripted gates

Both scripts run on the control plane from the repository root, and log to `var/`. They were exercised against stubs only (`scripts/byoh/test/m4-gate-scripts.sh`, 111 checks). Their database checks run `m2-checks`: on a packaged control plane through `sudo ubicloud-admin run m2-checks` (the release and `/etc/ubicloud/env`; the scripts pick it when `/etc/ubicloud` exists or the services run under systemd), on a development one through `bundle exec`. Both try it before anything else and stop with exit 2 when it cannot run, so a setup problem never reads as a failing host; `GATE_CHECKS` and `SOAK_CHECKS` override the command.

**E2 (G-M4-1, G-M4-2).** `install.sh` is the first of the three commands; run it as [INSTALL.md](INSTALL.md) says. Then:

```bash
export SITE=byoh-aws-m4 PLATFORM=aws HOST_SSH=ubuntu@<data private IP> \
  HOST_KEY=~/byoh_ssh_key POOL_FILE=~/pools.yaml \
  EXPECT_HOST_KEY="SHA256:... SHA256:..."            # host_add_command step 1's output, flags and all
scripts/byoh/verify/m4-e2.sh -- --display "AWS (BYOH M4 canary)" --underlay 10.98.0.0/16 \
  --overlay 172.20.0.0/14 --cp-reach onhost --cp-source <control plane private IP>/32 \
  --mgmt-allow <operator /32> --rates-from hetzner-fsn1
```

- `site add` options go after `--`, unchanged (terraform prints them as `byoh_location_create_command`). An existing site is skipped.
- Without `EXPECT_HOST_KEY`, set `HOST_ADD_YES=1` to confirm with `--yes`; compare the fingerprints in the log with the console afterwards.
- `EXPECT_HOST_KEY` takes bare `SHA256:...` fingerprints or the `--expect-host-key SHA256:...` flags terraform's step 1 prints.
- The script generates the registration key and passes it as `--registration-key`, so the gate's root logins (`GATE_HOST_KEY`) use the key the control plane keeps; set `GATE_HOST_KEY` to use your own. The key is a root login to the host, so it lives outside the repository, in `~/.ubicloud-m4-e2/` (0700, `E2_KEY_DIR`), named by platform, site and main IP:
  - After a failure it stays, and the last log line names it: re-running the same command (the resume `host add` recommends) reuses it, as the control plane already holds it.
  - After a pass the script shreds it; `E2_KEEP_KEY=1` keeps it for later `GATE_STEPS` runs, and the log says to `shred -u` it when the window ends.
  - A re-run against a host that is already registered, with the key gone, stops with FAIL before the gate: `resume` never installs a new key. Set `GATE_HOST_KEY` to a root key of the host then.
- `HOST_ADD_ARGS` adds options (`--storage-disk ...`, `--accept-check ...`, `--main-ip ...`). The gate checks the `--main-ip` given there (else the host of `HOST_SSH`); a `MAIN_IP` that differs from it is refused. `GATE_STEPS` picks the M2 gate steps; `GATE_*` settings of §1.4 pass through.
- The log has every output line with seconds since its phase began, then the phase durations (`site add`, `host add`, `m2 gate`) and the verdict. The bring-up's own phases show as the watch's label lines.
- AWS: end the window by stopping the data plane or `terraform destroy` of the workspace. Proxmox: `qm stop` the VM.

**F5 soak (G-M4-3 to G-M4-5).** On a host registered on M4 code (an older one needs `byoh-host relearn-device-ids --host vh... --yes` first), start the monitor by hand (packaged: `sudo systemctl start ubicloud-monitor`; development: `bin/monitor` in a tmux session), then:

```bash
scripts/byoh/verify/m4-f5-soak.sh --host vh<ebs> --host vh<virtio> --host vh<lvm> --hours 24 --interval 600
```

Each sample checks the monitor and runs `m2-checks health --host H --since START --probe` for each host, START being the soak's start:

- `--since` fails on a non-info page for the host raised after START even when it is resolved again, so a host that went `unavailable` and recovered between two samples is not missed.
- The monitor logs every down reading ("Got new pulse." with `"reading":"down"`), also those that never set `checkup` or recover within the 90 s before HostNexus pages. Each sample reads the log written since the last one (`SOAK_MONITOR_LOG`: the `ubicloud-monitor` journal under systemd, `/tmp/monitor.log` under tmux) and fails on a down reading of the host. A log it cannot read is a WARN line: then only pages and the sampled state count, and a mark-down shorter than the interval and the 90 s deadline goes unseen.
- `--probe` logs in to the host and runs the monitor's health checks; their read/write check writes and deletes a 1 MiB file in each storage path. It refuses (FAIL) a host whose SSH host keys are not pinned yet, as its session would pin the keys it meets in the database; respirate pins them on its next SSH session to the host. Nothing else is written.

Afterwards stop the monitor again (it stays disabled until M9, [OPERATIONS.md](OPERATIONS.md) §9).

### 6.2 M4 results

| Gate | Date | Result | Notes |
|---|---|---|---|
| G-M4-1 | 2026-10-16 | pass (AWS, run e2e1, §7) | `m4-e2.sh` on m8i.2xlarge with nested virtualization: site add, host add with `--expect-host-key` and `--storage-disk`, bring-up to `accepting`, m2 gate G1 G2 G4 G5; then G3, G7-G9b, G12-G14 with three VMs |
| G-M4-2 | — | not run | needs a Proxmox VM |
| G-M4-3, 4, 5 | — | not run | need G-M4-1, G-M4-2 and an LVM-root host, 24 h each |
| G-M4-6 | 2026-10-15 | pass (fixtures and containers) | `m4-host-add.sh` runs A (no `/dev/kvm`: exit 1 at preflight, no change), B (a /29 holding the uplink IP: exit 1 with PF17), C (the `intel-hybrid` fixture: `PF8-hybrid` blocks, `--accept-check PF8-hybrid` downgrades it) |

## 7. Real-infrastructure run e2e1 (AWS ap-south-1, 2026-10-16)

`scripts/byoh/test/aws-e2e/` created five tagged instances in the test VPC and tore them down afterwards (about 2.5 hours, roughly $3). Branch `aws-e2e`, starting from `byoh-driver` 0f671401e; the fixes below were built into releases v0.1.0-e2e2 to e2e4 on the control plane with the manual release switch and pushed to hosts with `install_rhizome`.

| What | Instance | Result |
|---|---|---|
| M3 `install.sh`, production mode, `--tls acme` on `<eip>.sslip.io` | t3.large | pass: smoke ok, a Let's Encrypt certificate (issuer YE1), services as systemd units, database role checks ok |
| M3 re-run of `install.sh` with `--backup-recipient` | ctrl | pass: idempotent; `status: ok` |
| M3 account, web login over HTTPS | ctrl | pass: `ubicloud-admin account create`, two-step login, project listed |
| M3 real reboot | ctrl | pass: every unit back, `status: ok` |
| M3 manual release switch (three times) | ctrl | pass: stage, backup, migrate, use, start; previous release kept |
| M3 backup then restore | ctrl | pass: restored into `ubicloud_restore` and swapped; host and VM counts unchanged; `status: ok` |
| E1 canary: production-mode boot image from the public mirror, VM boot | m8i.2xlarge | pass: `ubuntu-noble` downloaded with `BOOT_IMAGE_SOURCE=public`; three VMs running about a minute after create |
| M4 G-M4-1 (`m4-e2.sh`) | m8i.2xlarge | pass after the fixes below |
| M2 gate G3, G7, G8, G9, G9b, G12, G13, G14 (after a host reboot) | m8i.2xlarge | pass; VM-A leaves as its EIP; IMDS blocked; SMTP and the underlay blocked. G6, G10, G11 not run (no data-plane ingress before M7; no spare EIP) |
| Ladder detection, PF3 | t3.xlarge, t3.large | pass: "none (L3-L5) on AWS EC2", the move-to-C8i/M8i/R8i fix and the fallbacks; nothing changed on the host |
| L4 PVM go/no-go (`pvm-go-no-go.sh`) | m6i.large | **GO** with Cloud Hypervisor 46.0 and 53.0 (cocoonstack/pvm v0.1.0); guest vs host: CPU 87%, memory 95-100%, syscalls 47%, fork+exec 32%, login prompt 140 s; recovery-check PASS on the stock kernel |
| L3 container host and VM | t3.xlarge | pass after the fixes below: CPU 99.8% and memory 99.9% of the host; EIP egress; IMDS blocked; modprobe, mount, kernel sysctl writes, user namespaces and nft refused; no `/dev/kvm`, `/dev/fuse` or host disks; LUKS2 disk; uid map 0 -> 1000000000; stop, start, delete, billing family `container` |
| L5 emulated host and VM | t3.xlarge | pass: `-accel tcg,thread=multi,tb-size=256`, create to running 2 min 16 s; CPU 29% and memory 2% of the host; egress, DNS, apt; stop, start, delete; billing family `emulated`. A t3.large (one core) is refused by bootstrap, as designed |

Bugs the run found, each fixed on `aws-e2e` with a spec where code changed:

1. `terraform/aws-byoh/user-data-data.sh`: `systemctl reload ssh` fails under socket activation on current 24.04 images, so `set -e` ended the script before the pool IPs came off the NIC.
2. `ByohHostWatch` did not count upstream's `patch` label (after the boot image download), so host add exited 3 on a healthy bring-up.
3. `ubicloud-admin run` did not allow `byoh-virt`.
4. `m2-gate.sh` G3 and G13 called `bundle` directly, which a packaged control plane does not have.
5. Container prep asked dpkg for `lxc-utils`; Ubuntu 24.04 ships the tools in `lxc`.
6. LearnStorage failed forever on a BYOH host without `--storage-disk`: nothing created `/var/storage`.
7. The container network hook switched namespaces (`ip -n`), which remounts `/sys`; Ubuntu's AppArmor profile for `lxc-start` denies that.
8. The static `lxc-container-default-cgns` profile denies the `rslave` mount of `/` that systemd 255 needs, so container guests' init exited at once; containers now use LXC's generated profile.
9. A stopped container's unit ended `failed`: ExecStop's `lxc-stop` exits 2 after the clean shutdown.
10. Wording: the tier capacity refusals ("a emulated") and the m4-e2 resume hint.

Still not run on real machines: Proxmox (G-M4-2), the F5 24 h soak (G-M4-3 to 5), a real Cloudflare tunnel, G6/G10/G11, and the PVM tier end to end (L4-T2, `scripts/byoh/test/real/pvm-e2e.sh`): the GO allowed the build, which branch `pvm-build` has since done (spec-gated only; NO_KVM.md §6.7). Open gaps seen but not fixed: a container guest's `nproc` shows the host's CPUs (the cgroup limit holds; lxcfs does not virtualize the count), and `byoh-location rates` prints the development-layout restart hint on a packaged control plane.

## 8. Real-infrastructure run pvm1: the L4 PVM tier (AWS ap-south-1, 2026-10-17)

A control plane (t3.large, `install.sh` in production mode with `--tls acme`) and one m6i.2xlarge (Nitro, no VMX, Secure Boot not enforced), created and removed by `scripts/byoh/test/aws-e2e/` (run `pvm1`, about 1.2 hours). Branch `pvm-build`; `scripts/byoh/test/real/pvm-e2e.sh` (L4-T2) with the cocoonstack/pvm v0.1.0 example pins (third party, for testing).

| Phase | Result |
|---|---|
| location, neg-sha | pass: a wrong guest sha256 refused by `site set`; a wrong host-deb sha256 refused on the host with GRUB, the kernel packages and `/etc/grub.d` unchanged; a wrong guest sha256 refused by the host in bring-up |
| host-add, patch-kernel, host-check | pass: `host add --virt-tier pvm --install-pvm-kernel` to `accepting` in 184 s (install, one-shot PVM boot, verify); `/dev/kvm` and `kvm_pvm`; stock kernel stays the GRUB default |
| vm | pass: a pvm-2 VM running 20 s after create, SSH 6 s later; DNS, HTTPS egress, apt; guest kernel 6.12.33 (pinned sha); console on hvc0 and the serial log |
| prod-path, bench | pass. Guest vs host: CPU 97%, memory about 100%, 4k random fio on ubiblk 93%, HTTPS download 82%, syscalls 48%, fork+exec 32%, 512 MiB dd write 32%; the VM held 8357 MiB of its 8576 MiB budget |
| lifecycle, host-reboot, oob-reboot, power-cycle | pass: stop, start, restart; a HostNexus reboot, a reboot behind the control plane's back and a stop and start of the instance each bring the PVM boot and the VM back, noticed by the host itself |
| tenancy, refusals | pass: the location stays single-project; a pvm-2 `ubuntu-jammy` VM is refused at create |
| stock-return | pass: a PVM boot that does not happen pages, leaves the host on stock, and `pvm retry` recovers it |
| delete, billing, teardown | pass: nothing of the VM left on the host; billing family `pvm`; `pvm uninstall` and destroy return a stock host |
| guest-pin-rollout | NOT RUN: no second guest kernel build (UNVERIFIED) |

The run found two script bugs, fixed on `pvm-build`: re-registering the same instance needs its leftover `rhizome` user deleted (preflight PF16-rhizome-user refuses it, by design), and `serial-log -r` on every poll never shows a finished fetch.

It also found that a packaged control plane served no API: `clover.rb` routes only `api.*` hosts to the API, and the TLS front served the `--url` host alone, so `ubi` got the HTML login page. `install.sh` now serves `api.<host>` (branch `api-front`, merged into `pvm-build`). Verified on the same control plane after a release switch: a Let's Encrypt certificate for `api.15-206-161-137.sslip.io`, an unauthenticated JSON 401, and `bin/ubi vm list` against `https://api.<host>/cli`.

