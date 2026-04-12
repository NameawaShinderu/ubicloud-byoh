# BYOH bootstrap scripts

Reproducible scripts for standing up the Ubicloud control plane and BYOH
data plane on any Ubuntu 24.04 LTS host. Every manual step I performed
on the AWS Mumbai test environment (mise, ruby, node, postgres, bundle
install, npm build, migrations, cache refresh) is captured here so the
same thing can be done on OVH, Proxmox, a laptop with libvirt, or a
fresh AWS region — **zero manual steps**.

## The two roles

A Ubicloud BYOH deployment needs two kinds of Linux hosts:

| Role | What runs on it | Who runs this script | Script |
|---|---|---|---|
| **Control plane** | Postgres, clover (Roda/Puma), respirate dispatcher, `bin/register-byoh-host` CLI, web UI | You, once per deployment | `bootstrap-ctrl-plane.sh` |
| **Data plane** | rhizome agent + SPDK + cloud-hypervisor + the VMs themselves | You, once per BYOH host you want to add | `bootstrap-data-plane.sh` |

The control plane and data plane can be:
- **Same host** (single-machine lab) — run both scripts on the same box
- **Different hosts, same provider** (e.g. both in AWS Mumbai VPC) — what we have now
- **Different providers** (e.g. control plane in Hetzner Falkenstein, data plane on your Proxmox in your homelab) — the real BYOH use case

The control plane reaches the data plane over SSH; that's the only
coupling. No shared network is required as long as the control plane
can `ssh root@<data-plane-host>`.

## Prerequisites

- Target OS: **Ubuntu 24.04 LTS (Noble)**. Other Debian-derivatives may
  work but are unverified. Rocky/Alma/Fedora will not without porting.
- A copy of this ubicloud repo accessible to the target host (either
  cloned via git, or scp'd as a tarball).
- Sudo-capable user account on the target host.
- Outbound internet for apt + rubygems + npm + ubuntu image downloads.

## Usage — control plane

```bash
# On the target host (as a sudo-capable user, NOT as root):
./scripts/byoh/bootstrap-ctrl-plane.sh
```

The script is **idempotent** — you can re-run it and it'll skip steps
that are already done. Every step has a marker file under
`~/.ubi-bootstrap/` so reruns are fast.

Environment variables you can override:
- `UBI_REPO_DIR` — path to the ubicloud repo (default: `$HOME/ubicloud`)
- `UBI_RUBY_VERSION` — Ruby version (default: `4.0.2`)
- `UBI_NODE_VERSION` — Node version (default: `24.12.0`)
- `UBI_DB_NAME` — Postgres DB name (default: `clover_test`)
- `UBI_RACK_ENV` — Rack env (default: `development`; use `test` only when running specs)
- `UBI_START_SERVICES` — `1` to start puma + respirate in tmux after setup, `0` to skip (default: `1`)

## Usage — data plane

```bash
# On the BYOH target host (as a sudo-capable user):
./scripts/byoh/bootstrap-data-plane.sh
```

Idempotent. Prepares the host for the control plane's rhizome bootstrap
by ensuring root SSH works, pre-seeding `ruby-bundler` so Ubicloud's
`BootstrapRhizome` doesn't race on `apt-get update`, and printing the
operator's next step.

You'll also need to install the control plane's SSH public key into
`/root/.ssh/authorized_keys` on this host before running
`bin/register-byoh-host` on the control plane — the script prints
instructions for this step.

## Provider-specific pre-work

The bootstrap scripts handle the UNIVERSAL parts. These environment-
specific steps happen BEFORE you run `bin/register-byoh-host`:

| Provider | Pre-work | How the operator does it |
|---|---|---|
| **Hetzner (dedicated)** | Order an additional `/29` via Robot UI → "route to server X" | Hetzner's core routers route automatically |
| **OVH** | Order an IP block → "route to server X" | OVH handles routing; then `netplan apply` on the server |
| **Equinix Metal / Latitude / Cherry / Leaseweb** | Same pattern via provider panel | Their core does routing |
| **Proxmox + home router** | Add static route on router: `10.99.100.0/29 → <proxmox-ip>`; `sysctl net.ipv4.ip_forward=1` on Proxmox | Once — router config + sysctl |
| **AWS** | Assign N secondary private IPs to the ENI + associate M EIPs (1-to-1 for public reachability); disable source/dest check | See `scripts/byoh/providers/aws-routed-network-setup.sh` |
| **Colocation** | Your upstream routes the prefix to you | You already have this |

For AWS specifically, there's a helper script
`scripts/byoh/providers/aws-routed-network-setup.sh` that takes AWS
credentials + an ENI ID and does the EIP + secondary IP dance
automatically.

## Restart playbook

If the ctrl plane or data plane crashes, re-run the bootstrap script.
It'll detect the existing state and only do the missing steps (reload
tmux sessions, verify DB is up, etc.).

Full disaster recovery (fresh machine): start from
`backups/aws-mumbai-pre-eip/clover_test.dump` per the restore
instructions in `backups/README.md`.
