# Ubicloud BYOH — Complete Setup Guide (from zero)

This is the **from-scratch** setup guide for the Ubicloud BYOH (generic
provider) driver. If you've never touched this repo, never run Ubicloud
before, and are not sure what AWS / OVH / Hetzner even mean for bare
metal — start here. Every step tells you exactly what to type, why,
and what can go wrong.

If you already know what you're doing, skip ahead to
[docs/byoh/QUICKSTART.md](./QUICKSTART.md) — it's the same content
compressed into ~10 steps.

---

## Table of contents

1. [What is BYOH?](#1-what-is-byoh)
2. [What you'll have when you're done](#2-what-youll-have-when-youre-done)
3. [Pick a deployment topology](#3-pick-a-deployment-topology)
4. [The networking primer (read before anything else)](#4-the-networking-primer)
5. [Path A — everything on AWS (easiest first run)](#5-path-a--everything-on-aws)
   - 5.1 [Prerequisites](#51-prerequisites)
   - 5.2 [AWS account prep (quotas, IAM)](#52-aws-account-prep-quotas-iam)
   - 5.3 [Clone the repo](#53-clone-the-repo)
   - 5.4 [Configure `terraform.tfvars` — every variable explained](#54-configure-terraformtfvars--every-variable-explained)
   - 5.5 [`terraform apply`](#55-terraform-apply)
   - 5.6 [Bootstrap the control plane](#56-bootstrap-the-control-plane)
   - 5.7 [Install the ctrl→data SSH key](#57-install-the-ctrldata-ssh-key)
   - 5.8 [Register the data plane as a BYOH host](#58-register-the-data-plane-as-a-byoh-host)
   - 5.9 [Sign up on the web UI](#59-sign-up-on-the-web-ui)
   - 5.10 [Create your first VM](#510-create-your-first-vm)
   - 5.11 [SSH into your VM](#511-ssh-into-your-vm)
6. [Path B — control plane on a small VPS, data plane at OVH / Hetzner / colo](#6-path-b--distributed)
7. [Path C — everything on your Proxmox box at home](#7-path-c--self-hosted-on-proxmox)
8. [Troubleshooting](#8-troubleshooting)
9. [FAQ — including "why does the UI show `10.98.x.x` not my EIP?"](#9-faq)
10. [Cleaning up](#10-cleaning-up)
11. [What to read next](#11-what-to-read-next)

---

## 1. What is BYOH?

BYOH = **Bring Your Own Hardware**. It's a generic provider driver for
Ubicloud that lets you run Ubicloud on **any** SSH-reachable Linux
server — a bare-metal box at OVH/Hetzner/Equinix, a rented machine at
an obscure hoster, a server in a colo rack, a repurposed workstation,
a Proxmox VM in your basement. The driver was built by extending
Ubicloud's existing `Hosting::Apis` factory with a new
`Hosting::GenericApis` class that reads operator-declared routing
config instead of calling a provider-specific API like Hetzner's Robot.

**Why care about BYOH?** The stock Ubicloud is tightly coupled to
Hetzner's Robot API for host discovery, IP allocation, and reimage.
If you don't have a Hetzner account (or don't want one), you can't run
stock Ubicloud. BYOH breaks that coupling by making "how the host gets
its public IPs" a declaration you make at registration time — the
driver no longer needs to call any provider API.

**What does BYOH give you?**

- A real Ubicloud control plane (postgres + clover/Roda web UI + respirate
  dispatcher) on one machine.
- A real Ubicloud data plane (rhizome agent + SPDK + cloud-hypervisor +
  1G hugepages + per-VM network namespaces) on another machine.
- The ability to register any Ubuntu 24.04 host as a BYOH data plane
  via a single CLI command.
- Web UI + REST API + CLI for creating and managing VMs, the same as
  Hetzner Ubicloud, just pointed at your hardware.

---

## 2. What you'll have when you're done

A running Ubicloud deployment on YOUR infrastructure, where:

- You can sign up at `http://<ctrl-plane-ip>:3000/create-account`
- You can click **"Create Virtual Machine"** and pick a size, boot image, SSH key
- Ubicloud allocates the VM on your BYOH data plane within 2 minutes
- The VM boots Ubuntu 24.04 LTS and is reachable from anywhere on the
  internet via a real publicly-routable IP
- You can SSH into it with `ssh ubi@<public-ip>`

All of this works because of the BYOH driver — no Hetzner account
required, no provider-specific API calls, just SSH + optional Redfish.

---

## 3. Pick a deployment topology

BYOH supports three common topologies. **Pick one before reading further** —
the instructions branch based on your choice.

| Path | Control plane | Data plane | When to pick | Cost/month |
|---|---|---|---|---|
| **A** | AWS `t3.medium` | AWS `m5d.metal` | First-time run; you just want to see BYOH work end-to-end without buying hardware | ~$22/day |
| **B** | Small VPS ($5/mo) | Rented bare metal (OVH / Hetzner / Equinix / Latitude) | Real deployment with public reachability, no physical hardware to manage | ~$50-150/month |
| **C** | Proxmox VM on your home box | Proxmox VM on the same or another Proxmox box | Self-hosted, learning, zero cloud spend | $0 + electricity |

**Path A is the recommended first run.** Do it once to understand
the full flow, then switch to Path B or C for your real deployment.

Every path uses the same core commands and the same codebase — only
two things change between paths:

1. **Where the machines come from.** Path A uses Terraform against AWS.
   Paths B/C use whatever the provider gives you (a provisioning portal,
   an email with IPs, or virt-install on your Proxmox).
2. **How the data plane's public IP block gets routed to it.** On AWS
   it's a fiddly secondary-private-IP + EIP mapping. On Hetzner/OVH/
   Equinix it's a single order-the-block click. On Proxmox it's a
   static route on your home router.

The rest of the path (clone repo, bootstrap ctrl plane, register host,
sign up, create VM) is identical.

---

## 4. The networking primer

**Read this before starting ANY of the paths.** It saves hours of
debugging later.

A BYOH deployment has **three distinct layers of IP addresses**, and
they have nothing to do with each other. If you don't understand the
difference you WILL get confused.

### Layer 1 — The `sshable.host` IP (ctrl plane ⇄ data plane SSH)

This is the IP the control plane uses to SSH into the data plane over
port 22 to run the rhizome bootstrap and drive ongoing operations.

- **On Path A (all-on-AWS)**: both instances are in the same VPC; the
  ctrl plane uses the data plane's **VPC-private IPv4** (e.g.
  `10.98.1.136`). Works because both machines are in the same AWS
  subnet.
- **On Path B (distributed)**: different machines, different networks;
  the ctrl plane must SSH over the **public internet**, so
  `sshable.host` is the data plane's **public IPv4** (e.g. OVH's
  `51.89.x.y`).
- **On Path C (Proxmox)**: both VMs on your LAN; `sshable.host` is the
  data plane VM's **LAN IP** (e.g. `192.168.1.50`).

This is the `--main-ip` argument to `bin/register-byoh-host`.

### Layer 2 — The `routed_network` IP block (what VMs get as their "public" IP)

This is the pool of IPs Ubicloud hands out to VMs. Each VM gets one
IP from this pool as its "public IPv4" (what the UI shows, what
`assigned_vm_address.ip` stores).

- **On Path A (AWS)**: a pool of **VPC-private IPs** that are assigned
  as **secondary private IPs** on the data plane's ENI. AWS NATs
  Elastic IPs onto them at the VPC border (see FAQ for the display
  gotcha).
- **On Path B (bare-metal provider)**: a pool of **real public IPs**
  in a routed block the provider gave you (e.g. OVH routes
  `54.38.42.0/29` to your server, Hetzner routes `5.9.x.y/29` to yours,
  etc.). The 1:1 "IP in database = IP on the internet" assumption
  holds — this is what Ubicloud was originally designed for.
- **On Path C (Proxmox)**: a pool of **RFC1918 IPs** on a CIDR you
  carve out of your LAN (e.g. `192.168.99.0/29`). Your home router
  needs a static route pointing this CIDR to the data plane.

This is the `--routed-network` argument (repeatable) to
`bin/register-byoh-host`.

### Layer 3 — Overlay private subnet IP (inter-VM communication within a project)

Ubicloud creates an **overlay private subnet** per project/location
and gives every VM one IP from it. This subnet is always a random
RFC1918 `/26` that Ubicloud generates automatically — it has nothing
to do with your physical network or provider. VMs in the same private
subnet talk to each other via IPSec+VXLAN tunnels between hosts.

In the UI, the private subnet IP shows up as "Private IPv4" (e.g.
`172.26.186.15`) — this is **always auto-generated**, never something
you configure.

### Summary table

| Layer | What it is | Used for | Where it comes from |
|---|---|---|---|
| 1. `sshable.host` | Ctrl plane → data plane SSH endpoint | Host bootstrap + ongoing ops | You declare it at registration |
| 2. `routed_network` | Pool of "public" IPs for VMs | Each VM gets one; UI shows it | Provider gives you the block, you declare it |
| 3. Overlay subnet | Per-project inter-VM network | VM-to-VM inside one project | Auto-generated random RFC1918 /26 |

**The only layer that's AWS-weird** is Layer 2 on Path A, where the
"public" IP is actually a VPC-private IP that gets NAT'd to an EIP
at the VPC edge. Everywhere else, Layer 2 is a real routed public IP.
See [FAQ](#9-faq) for the AWS-specific UI display quirk.

---

## 5. Path A — everything on AWS

This is the recommended first-run path. You end up with a working
Ubicloud + a VM publicly reachable from anywhere on the internet, with
about 2 hours of wall time and ~$22 if you run it all day.

### 5.1 Prerequisites

Everything you need on **your local workstation** before you start:

| Tool | Why | Install |
|---|---|---|
| `git` | To clone the repo | `sudo apt install git` / built-in on macOS |
| `terraform >= 1.5` | To provision the AWS infra | https://developer.hashicorp.com/terraform/install |
| OR Docker | Alternative: run terraform via `hashicorp/terraform:1.9` image — no local install needed | `sudo apt install docker.io` |
| `ssh` client | To SSH into the instances after provisioning | built-in on Linux/macOS; Windows: use OpenSSH in PowerShell, or WSL |
| An **AWS account** with admin access | To run terraform | https://aws.amazon.com |
| A browser | For the Ubicloud web UI and AWS console | Any |
| An SSH keypair | For your user account inside VMs (separate from the infra key; you'll paste the pubkey into the Ubicloud UI in §5.10) | `ssh-keygen -t ed25519 -N "" -f ~/.ssh/byoh_vm_key -C "byoh-vm-user"` |

You do **not** need: Ubicloud locally, Ruby, Postgres, Node, nothing.
Everything runs on the AWS instances that terraform creates.

### 5.2 AWS account prep (quotas, IAM)

Three checks to do in the AWS console BEFORE running terraform:

**(a) Pick a region.** The default in `terraform.tfvars.example` is
`ap-south-1` (Mumbai). Other good options: `us-east-2`, `us-west-2`,
`eu-central-1`, `eu-west-1`. Two hard constraints:

1. The region must offer `m5d.metal`. Check with:
   ```bash
   aws ec2 describe-instance-type-offerings \
     --location-type region \
     --filters 'Name=instance-type,Values=m5d.metal' \
     --region <region>
   ```
   Empty output = not available in that region.
2. The region should be mostly EMPTY for you — BYOH creates a dedicated
   VPC, SG, key pair, etc., and you want clean isolation from any
   other infra in your account. `aws ec2 describe-instances --region
   <region>` should return few or no running instances for comfort.

**(b) Request bare-metal quota.** AWS default quota `L-1216C47A`
("Running On-Demand Standard instances") is **5 vCPUs** for new
accounts. `m5d.metal` consumes 96 vCPUs. You need at least **100 vCPUs**
of quota in your chosen region before terraform can create the data
plane instance.

To request an increase:
```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-1216C47A \
  --desired-value 100 --region <region>
```

Or via console: Service Quotas → EC2 → "Running On-Demand Standard instances"
→ Request quota increase. Usually auto-approved within 5-60 minutes.

**(c) Request Elastic IP quota.** Default is 5 per region; we use 3
for the VM pool. Request at least 10 if you plan to experiment:
```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-0263D0A3 \
  --desired-value 10 --region <region>
```

**(d) Create an IAM user (or use an existing one) with sufficient
permissions.** For a hands-on test, admin access is easiest. For
least-privilege production, use the policy at the bottom of
`terraform/aws-byoh/README.md`. Note the **Access Key ID** and
**Secret Access Key** — you'll paste them as env vars in §5.5.

### 5.3 Clone the repo

On your local workstation:

```bash
git clone https://github.com/NameawaShinderu/ubicloud-byoh.git
cd ubicloud-byoh
git checkout byoh-driver
```

**Verify you're on the right branch**:
```bash
git log --oneline byoh-driver -5
# top commit should be about "terraform module + QUICKSTART + ..."
```

### 5.4 Configure `terraform.tfvars` — every variable explained

```bash
cd terraform/aws-byoh
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

You must review **every line** of `terraform.tfvars`. Here's what each
variable does, when to change it, and what can go wrong:

#### `aws_region`
- **What**: Which AWS region to deploy in
- **Default**: `"ap-south-1"` (Mumbai)
- **Change when**: You want lower latency (pick the closest region to you),
  or your AWS quotas are higher in a different region, or you want to avoid
  a region where you already have infra
- **Gotchas**: Must offer `m5d.metal` (see §5.2). If you change this,
  also update `availability_zone`.

#### `availability_zone`
- **What**: The specific AZ within the region
- **Default**: `"ap-south-1a"`
- **Change when**: The default AZ doesn't have `m5d.metal` capacity on
  the day you're running this (rare, but possible). Check with:
  ```bash
  aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters 'Name=instance-type,Values=m5d.metal' \
    --region ap-south-1
  ```
- **If you change `aws_region`**: pick an AZ like `us-east-2a`, `eu-west-1a`, etc.

#### `vpc_cidr`
- **What**: The CIDR block for the dedicated VPC terraform creates
- **Default**: `"10.98.0.0/16"`
- **Change when**: Another VPC in your AWS account already uses
  `10.98.0.0/16` (terraform will error with "InvalidVpcRange"). Check
  with:
  ```bash
  aws ec2 describe-vpcs --query 'Vpcs[].CidrBlock' --output text --region <r>
  ```
- **Alternatives**: `10.97.0.0/16`, `10.96.0.0/16`, `10.250.0.0/16`,
  `172.20.0.0/16`, `192.168.100.0/16` — any RFC1918 `/16` that doesn't
  collide.
- **If you change this**: also update `subnet_cidr` and
  `byoh_secondary_private_ips` to be inside the new VPC CIDR.

#### `subnet_cidr`
- **What**: The public subnet inside the VPC
- **Default**: `"10.98.1.0/24"`
- **Must be inside**: `vpc_cidr`
- **Change when**: You changed `vpc_cidr` — pick any `/24` inside the new
  VPC CIDR (e.g. if `vpc_cidr = 10.97.0.0/16`, then
  `subnet_cidr = 10.97.1.0/24`).

#### `operator_ssh_cidr`
- **What**: Which IPs are allowed to SSH into the instances + the web UI port
- **Default**: `"0.0.0.0/0"` (open to the entire internet — chosen for ease
  of testing)
- **Change when**: **Always, for real use.** Lock it down to your
  workstation's public IP:
  ```bash
  curl -s https://checkip.amazonaws.com
  # → 203.0.113.42
  ```
  Then in tfvars: `operator_ssh_cidr = "203.0.113.42/32"`.
- **Gotcha**: If your home ISP gives you a dynamic IP, you'll have to
  re-apply terraform whenever it changes. For a short-lived test,
  `0.0.0.0/0` is fine.

#### `ctrl_plane_instance_type`
- **What**: EC2 instance type for the Ubicloud control plane
- **Default**: `"t3.medium"` (2 vCPU, 4 GB RAM, ~$0.042/hr)
- **Change when**: You're running many concurrent VMs and puma/respirate
  need more RAM. Upgrade to `t3.large` (8 GB) or `t3.xlarge` (16 GB).
  For a 1-2 VM test, `t3.medium` is enough.

#### `data_plane_instance_type`
- **What**: EC2 instance type for the BYOH data plane (the machine that
  actually runs your VMs)
- **Default**: `"m5d.metal"` (96 vCPU, 384 GB RAM, 4×900 GB NVMe instance
  store, ~$5.42/hr)
- **Must be**: A **bare-metal** instance type (`.metal` suffix). Virtualized
  instances like `c5.xlarge` would fail because SPDK can't bind NVMe
  devices via VFIO on Nitro-virtualized instances.
- **Alternatives by cost**:
  - `m5d.metal` — $5.42/hr, 96 vCPU, 384 GB RAM, 4×900 GB NVMe (recommended default)
  - `m5.metal` — $4.61/hr, 96 vCPU, 384 GB RAM, EBS-only (no local NVMe)
  - `c5.metal` — $4.08/hr, 96 vCPU, 192 GB RAM, EBS-only
  - `r5d.metal` — $6.67/hr, 96 vCPU, 768 GB RAM, 4×900 GB NVMe
  - `i3en.metal` — $10.85/hr, 96 vCPU, 768 GB RAM, 8×7.5 TB NVMe
  - `m6id.metal` — $7.30/hr, 128 vCPU, 512 GB RAM, 4×1.4 TB NVMe (newer Ice Lake)
- **Quota**: Uses 96-128 vCPUs of `L-1216C47A`. Increase quota first (§5.2).

#### `ctrl_root_size_gb`
- **What**: Root EBS disk size for the control plane in GB
- **Default**: `40`
- **Change when**: Rarely. 40 GB is plenty for postgres + the Ubicloud
  code + gems + node_modules + test DB. If you're running in production
  with real user data, bump to 100+.

#### `data_root_size_gb`
- **What**: Root EBS disk size for the data plane in GB
- **Default**: `120`
- **Critical**: Due to a known gap (see
  [docs/providers/generic.md](../providers/generic.md) → "Known
  limitation: storage device discovery"), Ubicloud currently uses
  **only the root disk** for VM storage on `m5d.metal`. The 4×900 GB
  instance-store NVMes are NOT discovered. So `data_root_size_gb` must
  accommodate all your VMs' disks. Budget:
  - 1 VM (40 GB default disk): 80 GB root
  - 2-3 VMs: 120 GB root (current default, ~2 concurrent VMs)
  - 5+ VMs: 250 GB root
  - 10+ VMs: 500 GB root
- **Alternative**: Pick `m5.metal` or `c5.metal` (EBS-only) instead and
  bump root to 500+ GB — same effective behavior for less money (no
  wasted instance store).

#### `byoh_secondary_private_ips`
- **What**: The pool of secondary private IPs to assign to the data plane's
  primary ENI. Each IP becomes a slot Ubicloud can hand out to a VM as
  its "public" IP. Each gets an Elastic IP associated 1:1 for real
  public reachability.
- **Default**: `["10.98.1.128", "10.98.1.129", "10.98.1.130"]` — 3 slots
- **Constraints**:
  - Must be inside `subnet_cidr`
  - Must not conflict with the instance's primary private IPs (AWS auto-assigns
    `.4` through some low number to the ctrl + data plane instances —
    pick `.128+` to stay far away)
  - Must not use reserved addresses (AWS reserves the first 4 and the
    last IP of every subnet)
  - Pool size = max concurrent publicly-reachable VMs; each IP consumes
    one Elastic IP from your `L-0263D0A3` quota (§5.2)
- **Change when**:
  - You want more VMs — add entries like `"10.98.1.131"`, `"10.98.1.132"`
  - You changed `subnet_cidr` — recompute the IPs to be inside the new subnet
- **Instance limit**: `m5d.metal` allows up to 50 secondary IPs per ENI,
  so you can scale this up substantially before hitting AWS limits.

### 5.5 `terraform apply`

```bash
# Inside terraform/aws-byoh/

# Option 1: Terraform installed locally
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
terraform init
terraform apply

# Option 2: Terraform via Docker (no local install required)
docker run --rm \
  -v "$PWD:/work" -w /work \
  -e AWS_ACCESS_KEY_ID=AKIA... \
  -e AWS_SECRET_ACCESS_KEY=... \
  hashicorp/terraform:1.9 init
docker run --rm \
  -v "$PWD:/work" -w /work \
  -e AWS_ACCESS_KEY_ID=AKIA... \
  -e AWS_SECRET_ACCESS_KEY=... \
  hashicorp/terraform:1.9 apply -auto-approve
```

**Timing**: 5-15 minutes. The `m5d.metal` instance is the slow part —
AWS's Nitro BMC does a full POST cycle on first boot. You'll see
terraform print messages every ~30 seconds saying "still creating" for
the data plane.

**At the end**, terraform prints a `handoff_instructions` block with
the public IPs, SSH commands, and the EIP ⇄ private IP map. **Save
this output** — copy it to a note file, you'll reference it
repeatedly.

Example output:
```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Outputs:

byoh_eip_to_private_ip = {
  "65.0.90.4"     = "10.98.1.128"
  "52.66.110.229" = "10.98.1.129"
  "3.6.57.198"    = "10.98.1.130"
}
byoh_ip_pool        = ["10.98.1.128", "10.98.1.129", "10.98.1.130"]
ctrl_public_ip      = "13.206.71.54"
ctrl_private_ip     = "10.98.1.191"
data_public_ip      = "13.233.108.32"
data_private_ip     = "10.98.1.136"
ssh_private_key_path = "./.generated/byoh_ssh_key"
handoff_instructions = ...
```

**`handoff_instructions`** is a multi-line formatted version of the
same info for easy copy-paste.

**Sanity checks:**
```bash
# Verify the generated SSH key exists
ls -la .generated/byoh_ssh_key
# → should be -rw------- 1 you you 387 ... byoh_ssh_key

# Verify the ctrl plane is reachable
ssh -i .generated/byoh_ssh_key \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@<ctrl_public_ip> 'uptime; cat /var/log/user-data.done'
# → should print uptime + /var/log/user-data.done
```

If the SSH fails with "permission denied" but you can see the instance
is running in the AWS console, the cloud-init may still be finishing —
give it another 30-60 seconds.

### 5.6 Bootstrap the control plane

SSH into the ctrl plane:
```bash
ssh -i .generated/byoh_ssh_key \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@<ctrl_public_ip>
```

You'll see a custom MOTD banner welcoming you to the BYOH control plane.
Now clone the repo on the ctrl plane itself and run the bootstrap:

```bash
# On the ctrl plane
git clone https://github.com/NameawaShinderu/ubicloud-byoh.git ubicloud
cd ubicloud
git checkout byoh-driver
./scripts/byoh/bootstrap-ctrl-plane.sh
```

This takes **5-10 minutes** on first run. What it does:

1. Verifies Ubuntu 24.04 LTS
2. Installs system packages (git, tmux, libpq-dev, postgres-16, build deps)
3. Installs Ruby 4.0.2 via mise (compiles from source, ~3 min)
4. Installs Node 24.12.0 via mise (~1 min)
5. Creates Postgres users (clover, clover_password) + `clover_test` DB
6. Rewrites `pg_hba.conf` to `trust` local connections (test env only!)
7. `bundle install` — 171 Ruby gems (~2 min)
8. `npm install` + `npm run prod` — compiles Tailwind → `assets/css/app.css`
9. Generates `.env.rb` with random session secrets + column encryption key
10. Runs database migrations
11. Refreshes Sequel schema caches
12. Starts puma (port 3000) + respirate (dispatcher) in tmux sessions

Every step has a marker file under `~/.ubi-bootstrap/`. **Safe to re-run** —
if the script is interrupted or you want to reset, delete the marker
directory: `rm -rf ~/.ubi-bootstrap` and re-run.

**Verify it worked**:
```bash
# On ctrl plane
curl -sS -o /dev/null -w "HTTP %{http_code}\n" http://localhost:3000/login
# → HTTP 200
tmux ls
# → puma: 1 windows (created ...)
# → respirate: 1 windows (created ...)
```

### 5.7 Install the ctrl→data SSH key

The Ubicloud control plane uses an Ed25519 SSH key to log into the
data plane **as root** and install the rhizome agent. You need to:

1. Generate a fresh keypair on the ctrl plane
2. Install its public half into the data plane's `/root/.ssh/authorized_keys`
3. Feed its private half to `bin/register-byoh-host` via `--ssh-key`

Because terraform created the same AWS keypair on both instances, you
can SSH from ctrl plane to data plane as `ubuntu` using the AWS key.
You need that AWS key on the ctrl plane — copy it up from your local
machine:

```bash
# ON YOUR LOCAL MACHINE (not the ctrl plane)
scp -i terraform/aws-byoh/.generated/byoh_ssh_key \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    terraform/aws-byoh/.generated/byoh_ssh_key \
    ubuntu@<ctrl_public_ip>:~/.ssh/byoh_aws_key
```

Then SSH back into the ctrl plane:
```bash
ssh -i terraform/aws-byoh/.generated/byoh_ssh_key \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@<ctrl_public_ip>
```

On the ctrl plane, four commands:

```bash
# 1. Set permissions on the copied AWS key
chmod 600 ~/.ssh/byoh_aws_key

# 2. Generate a fresh Ed25519 key specifically for the Ubicloud ctrl→data flow
ssh-keygen -t ed25519 -N "" -f ~/.ssh/byoh_ctrl_key -C "ubicloud-byoh-ctrl"

# 3. Install its public half on the data plane's /root/.ssh/authorized_keys
cat ~/.ssh/byoh_ctrl_key.pub | ssh -i ~/.ssh/byoh_aws_key \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@<data_private_ip> \
    'sudo bash -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && wc -l /root/.ssh/authorized_keys"'

# 4. Verify ctrl plane can SSH as root to the data plane
ssh -i ~/.ssh/byoh_ctrl_key \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@<data_private_ip> 'whoami; hostname'
# → root
# → ip-10-98-1-XXX
```

### 5.8 Register the data plane as a BYOH host

Still on the ctrl plane, from `~/ubicloud`:

```bash
export PATH=$HOME/.local/share/mise/installs/ruby/4.0.2/bin:$PATH

RACK_ENV=development bundle exec bin/register-byoh-host \
    --main-ip <data_private_ip> \
    --routed-network 10.98.1.128/32 \
    --routed-network 10.98.1.129/32 \
    --routed-network 10.98.1.130/32 \
    --routed-network fd00:aa55::/64 \
    --location aws-mumbai-byoh \
    --default-boot-image ubuntu-noble \
    --server-identifier aws-m5d-metal-1 \
    --ssh-key ~/.ssh/byoh_ctrl_key \
    --yes
```

**Substitute** `<data_private_ip>` with the value terraform printed (e.g.
`10.98.1.136`). **Substitute** the three `/32` CIDRs with the
`byoh_secondary_private_ips` from your tfvars — they must match
EXACTLY.

Expected output (runs in under 5 seconds):
```
Host registered.
  VmHost UBID:  vhxxxxxxxxxxxxxxx
  Strand UBID:  vhxxxxxxxxxxxxxxx
```

**Now wait for the host to bootstrap and reach `accepting` state.** In
a second tmux pane (or second SSH session):

```bash
watch -n 15 "psql -U clover -d clover_test -c \"
SELECT s.prog, s.label, s.try, vh.allocation_state
FROM strand s LEFT JOIN vm_host vh ON s.id=vh.id
WHERE s.prog IN ('Vm::HostNexus', 'BootstrapRhizome', 'DownloadBootImage');\""
```

You'll see the strand walk through:
```
setup_ssh_keys → bootstrap_rhizome → prep → wait_prep → setup_hugepages
  → setup_storage_backend → download_boot_images → prep_reboot → reboot
  → verify_spdk → verify_hugepages → start_slices → start_vms
  → configure_metrics → wait
```

**Total time: ~15-25 minutes.** The `reboot` label is the slowest (the
m5d.metal does a full Nitro POST). When you see:
```
allocation_state | accepting
```
the host is ready.

If any strand sits with `try > 5`, something's wrong — see
[Troubleshooting](#8-troubleshooting).

### 5.9 Sign up on the web UI

From **your local machine's browser**:

```
http://<ctrl_public_ip>:3000/create-account
```

- Enter any email + password (Rodauth doesn't send verification emails
  in dev mode)
- Pick a display name
- Click Create Account
- You'll land on `/project/<ubid>/dashboard` as the owner of a
  default project

### 5.10 Create your first VM

In the web UI:

1. **Sidebar → SSH Public Keys → Create**
   - Name: `my-key`
   - Public key: paste the contents of `~/.ssh/byoh_vm_key.pub` (the one
     you generated in §5.1 "Prerequisites")
   - Save
2. **Sidebar → Virtual Machines → Create Virtual Machine**
   - Name: `test-vm-1` (or whatever)
   - Location: **eu-central-h1 (Germany)** — this is the default label
     Ubicloud uses; our BYOH host is actually in AWS Mumbai but the
     location label doesn't affect anything functionally
   - Size: `standard-2` (smallest option — 2 vCPU, 8 GB RAM)
   - Boot image: **Ubuntu Noble 24.04 LTS**
   - SSH key: pick `my-key`
   - ✅ Enable IPv4
   - Private subnet: `Create new`
   - Click **Create**
3. Wait ~2 minutes. The VM status goes through `creating` →
   `running`. Refresh the overview page every 15 seconds.

### 5.11 SSH into your VM

In the UI, note the VM's "Public IPv4" field — it'll be one of
`10.98.1.128` / `.129` / `.130`. Look up the matching Elastic IP from
the `byoh_eip_to_private_ip` map terraform printed:

```
10.98.1.128 → 65.0.90.4
10.98.1.129 → 52.66.110.229
10.98.1.130 → 3.6.57.198
```

From your local machine:
```bash
ssh -i ~/.ssh/byoh_vm_key ubi@<matching-eip>
```

**Username is `ubi`, not `ubuntu`.** That's Ubicloud's default unix
user inside BYOH VMs.

Inside the VM:
```bash
uname -a
# → Linux vm... 6.8.x-generic ... x86_64
cat /proc/cpuinfo | grep "model name" | head -1
# → Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz
# (the m5d.metal's real CPU)
df -h /
# → ~40 GB root, served by SPDK vhost-user backend
free -h
# → 8 GB (1 GB hugepages)
```

**You did it.** You have a real VM running on AWS bare-metal
hardware, reached from anywhere on the internet via a real public IP,
provisioned entirely by Ubicloud via the BYOH driver, with zero
Hetzner-specific code paths involved.

---

## 6. Path B — Distributed

This is "control plane on a small cheap machine, data plane on
rented bare metal at a real hosting provider." The promise of BYOH
is that these two can be on completely different providers, in
different countries, behind different networks — as long as the
ctrl plane can SSH to the data plane over the internet, and the
data plane's `routed_network` block is reachable from the users'
browsers.

### 6.1 When to use Path B

- You want a real public-IP-reachable VM pool (not AWS-VPC-NAT'd)
- You want low cost: a $5/mo VPS + a €40-90/mo bare metal box
- You want to deploy on a provider other than AWS
- You want the control plane to survive if the data plane dies (and vice versa)

### 6.2 Control plane — picks

Anything with:
- A static public IPv4
- Ubuntu 24.04 LTS
- At least 2 vCPU, 4 GB RAM, 40 GB disk
- Outbound internet (apt, git, bundle install)
- Inbound SSH + port 3000 allowed from your operator IP

**Good picks:**
| Provider | Instance | ~$/month | Notes |
|---|---|---|---|
| Hetzner Cloud | CX22 (2 vCPU, 4 GB, 40 GB) | €4 | Best $/performance; use `ubuntu-24.04` image |
| DigitalOcean | Basic droplet (2 vCPU, 4 GB, 80 GB) | $24 | Easy onboarding; `ubuntu-24-04-x64` |
| Linode | Shared 4 GB | $24 | Similar to DO |
| OVH VPS | Starter / Value 2 | €5-8 | Cheap but slower provisioning |
| AWS EC2 | `t3.medium` | ~$30 | Familiar if you did Path A |
| Your own laptop | anything with 4+ GB RAM | $0 | Works but needs to be on when operators use the UI |

Provision it, SSH in, then run:
```bash
git clone https://github.com/NameawaShinderu/ubicloud-byoh.git ubicloud
cd ubicloud
git checkout byoh-driver
./scripts/byoh/bootstrap-ctrl-plane.sh
```

Same bootstrap script as Path A — it's provider-agnostic. In 5-10 min
you'll have puma + respirate running.

### 6.3 Data plane — picks (real bare metal)

For BYOH to really shine, use a provider that gives you **real routed
IP blocks** (not NAT-based like AWS). The operator experience is
drastically simpler because there's no EIP/secondary-IP dance.

| Provider | Plan | ~$/month | IP block model | Notes |
|---|---|---|---|---|
| **OVH** | Advance-1 Gen3 | €90-120 | Order additional `/29` via OVH Manager, routes automatically | Best for BYOH — iDRAC BMC, real NVMe, routed IPs |
| **Hetzner** dedicated | AX41-NVMe | €40 | Order `/29` via Robot, routed automatically | Cheapest real BYOH; but if you use Hetzner you might as well use the stock Hetzner driver |
| **Equinix Metal** | `c3.small.x86` | ~$0.30/hr | "Public IPv4" subnet assignment | Metal shutting down June 2026; use **Latitude.sh** as successor |
| **Latitude.sh** | `c2.small.x86` | ~$0.04-0.20/hr hourly | Similar to Equinix | Metal replacement, modern API |
| **Cherry Servers** | any w/ NVMe | ~€0.091/hr | Order block, routed | OpenAPI, BGP support |
| **Leaseweb** | NVMe dedicated | €70-100 | Order IPs, routed | |
| **Colo** (your own box) | own hardware | $0+power | Your upstream announces your prefix | Highest effort, highest control |

**Prerequisite**: the provider must give you a **routed IP block**
separate from the server's main IP. Most bare-metal providers do this
for free or a small fee. The typical ordering flow:

1. Log into provider panel
2. Navigate to "Additional IPs" / "IP Block" / "Failover IPs"
3. Order a `/29` or `/28` — say why you need it ("running VMs")
4. Within 10-60 minutes, provider emails you the CIDR + a confirmation
   that it's routed to server X
5. SSH into the server and add the block to `/etc/netplan/...` (some
   providers auto-configure it, some don't)

**The CIDR they give you is what you pass as `--routed-network` to
`bin/register-byoh-host`.**

### 6.4 Registering the data plane on Path B

Once your ctrl plane VPS and data plane bare metal are both up and
reachable from each other over the internet, and you've ordered the
routed block from your data plane provider, the registration is very
slightly different from Path A:

```bash
# On the ctrl plane VPS
# 1. generate the ctrl→data key
ssh-keygen -t ed25519 -N "" -f ~/.ssh/byoh_ctrl_key -C "ubicloud-byoh-ctrl"

# 2. copy pubkey to data plane's /root/.ssh/authorized_keys
#    (using whatever SSH method works — the provider probably gave you
#    root access initially, or an 'operator' user with sudo)
ssh-copy-id -i ~/.ssh/byoh_ctrl_key.pub root@<data-plane-public-ip>

# 3. register
cd ~/ubicloud
export PATH=$HOME/.local/share/mise/installs/ruby/4.0.2/bin:$PATH
RACK_ENV=development bundle exec bin/register-byoh-host \
    --main-ip <data-plane-public-ip>            \
    --routed-network 54.38.42.0/29              \
    --routed-network 2001:db8:xxx::/64          \
    --location ovh-gravelines-1                 \
    --default-boot-image ubuntu-noble           \
    --server-identifier ovh-advance-1-01        \
    --ssh-key ~/.ssh/byoh_ctrl_key              \
    --yes
```

**Key differences from Path A:**

1. `--main-ip` is the data plane's **real public IP** (not a VPC-private IP).
   Why: the ctrl plane VPS has no other way to reach the data plane
   box besides the internet.
2. `--routed-network` is the **real public CIDR the provider routed to
   you** (e.g. `54.38.42.0/29`). Ubicloud will hand individual IPs from
   this block out to VMs, and each VM will have a **real internet-
   reachable public IP** — no NAT, no lookup tables, no EIP dance.
   The "Public IPv4" shown in the UI IS the IP you SSH to.
3. No terraform. The provider gave you a machine; you just SSH in and
   run `bootstrap-data-plane.sh`:
   ```bash
   # on the data plane bare metal
   git clone https://github.com/NameawaShinderu/ubicloud-byoh.git ubicloud
   cd ubicloud && git checkout byoh-driver
   ./scripts/byoh/bootstrap-data-plane.sh
   ```
   (It installs openssh-server, allows root pubkey login, pre-installs
   `ruby-bundler`, and sets `net.ipv4.ip_forward=1`.)

### 6.5 Network flow on Path B

```
  your laptop          internet         ctrl plane VPS                    data plane at OVH
    │                     │                    │                                │
    │ ssh ubi@54.38.42.1  │                    │                                │
    │─────────────────────┼────────────────────┼───────────────────────────────▶│
    │                     │ routed via OVH core to your dedicated server's NIC │
    │                     │                                                    │ kernel forwards to VM netns → tap → VM
    │                                                                          │
  your laptop          ctrl plane VPS             internet                    data plane
    │                       │                        │                          │
    │ http://13.206.71.54:3000 (ctrl plane VPS)      │                          │
    │─────────────────▶│ clover web UI             │                          │
    │                       │ clover dispatch SSH    │                          │
    │                       │────────────────────────┼─────────────────────────▶│ rhizome, register, etc.
```

**The only thing the ctrl plane and data plane do with each other is
SSH over the internet on port 22.** No shared network, no overlay, no
tunnel. Ctrl plane is in Germany (Hetzner VPS), data plane is in
France (OVH bare metal), VMs are on the OVH bare metal with real
French public IPs — users from anywhere on the internet SSH straight
to them.

### 6.6 Web UI access on Path B

Your ctrl plane VPS runs puma on port 3000. How do operators reach it?

- **Option 1: direct port 3000**: open port 3000 on the VPS firewall
  to your operator team's IPs. Access via
  `http://<vps-public-ip>:3000`. Not HTTPS — fine for testing,
  **not fine for production**.
- **Option 2: reverse proxy on the VPS**: install nginx or caddy on
  the VPS, terminate TLS with Let's Encrypt, proxy to
  `localhost:3000`. Now operators use `https://ubicloud.yourdomain.com`.
- **Option 3: Tailscale**: put the ctrl plane VPS on your Tailscale
  network, never expose port 3000 publicly. Operators use
  `http://ubi-ctrl.tail-xxxx.ts.net:3000` (or similar). Zero public
  exposure; zero cert management.
- **Option 4: Cloudflare Tunnel**: even simpler than Tailscale if you
  already use Cloudflare.

Pick based on your threat model and laziness. For a test, Option 1 is
fine. For production, Option 3 or 4.

---

## 7. Path C — Self-hosted on Proxmox

This is the zero-cloud-spend path: everything runs on a Proxmox box
in your home or office. You need **nested virtualization** enabled
on the Proxmox host so the data plane's cloud-hypervisor VMs can
actually boot.

### 7.1 When to use Path C

- You have a Proxmox host already (homelab, office)
- You want to learn Ubicloud without spending any money
- You're OK with VMs only being reachable from your LAN (no public IPs)
- You're comfortable editing your router's static routing table

### 7.2 Proxmox prerequisites

On the Proxmox host:

```bash
# On the Proxmox node (proxmox-host.lan)
# Verify nested virtualization is supported
grep -E 'vmx|svm' /proc/cpuinfo | head -1
# → should return a line (if empty, your CPU can't do nested)

# Enable nested KVM
echo "options kvm-intel nested=Y" | sudo tee /etc/modprobe.d/kvm-intel.conf
# (or kvm-amd for AMD)
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
cat /sys/module/kvm_intel/parameters/nested
# → should print Y or 1
```

### 7.3 Create the ctrl plane and data plane VMs

In the Proxmox UI:

**Ctrl plane VM (`ubi-byoh-ctrl`)**
- OS: Ubuntu 24.04 LTS Server ISO
- CPU type: `host` (important for nested virt)
- 4 vCPUs, 8 GB RAM, 60 GB disk
- BIOS: OVMF (UEFI)
- Network: `vmbr0` (bridged to your LAN — gets a LAN IP via DHCP)

**Data plane VM (`ubi-byoh-data`)**
- OS: Ubuntu 24.04 LTS Server ISO
- CPU type: `host` — and explicitly enable VMX if asked
- 4 vCPUs, 16 GB RAM, 80 GB disk
- BIOS: OVMF (UEFI)
- Network: `vmbr0`
- In args (Options → "Args"): `-cpu host,+vmx,+svm` (lets the data
  plane's Linux expose nested KVM to cloud-hypervisor)

Install Ubuntu 24.04 on both. Set static LAN IPs in your DHCP server
or via netplan.

### 7.4 Configure your home router for the BYOH routed block

You're going to declare a CIDR block like `192.168.99.0/29` to
Ubicloud as the VM IP pool. For these IPs to actually be reachable
from other devices on your LAN (e.g. your laptop), your home router
needs a **static route** telling it "traffic for `192.168.99.0/29`
goes to `192.168.1.50` (the data plane VM's LAN IP)."

**How to add a static route — by router brand:**

| Router | Where |
|---|---|
| **OpenWRT** | Network → Static Routes → Add. Interface `lan`, target `192.168.99.0/29`, IPv4-gateway `192.168.1.50` |
| **pfSense** | System → Routing → Static Routes → Add. Network `192.168.99.0/29`, gateway = new gateway pointing at `192.168.1.50` |
| **OPNsense** | System → Routes → Configuration → Add |
| **Unifi Dream Machine** | Network → Settings → Routing → Static Routes |
| **Mikrotik RouterOS** | `/ip route add dst-address=192.168.99.0/29 gateway=192.168.1.50` |
| **TP-Link Archer / ASUS / consumer router** | Advanced → LAN → Static Routing → Add. Most support it; some don't — if yours doesn't, pick one of the router options above as your next upgrade. |
| **Cheap ISP-provided router** | Usually no. You'll either have to replace it or use Path B instead. |

Also: on the data plane VM itself, enable IP forwarding:
```bash
# On the data plane VM
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 7.5 Bootstrap + register

Same commands as Path B, minus terraform. SSH into ctrl plane VM, run
`bootstrap-ctrl-plane.sh`, generate ctrl→data key, install it on the
data plane VM's `/root/.ssh/authorized_keys`, run `register-byoh-host`:

```bash
# on ctrl plane VM
cd ~/ubicloud
export PATH=$HOME/.local/share/mise/installs/ruby/4.0.2/bin:$PATH
RACK_ENV=development bundle exec bin/register-byoh-host \
    --main-ip 192.168.1.50                \
    --routed-network 192.168.99.0/29      \
    --routed-network fd00:aa55::/64       \
    --location homelab-rack-1             \
    --default-boot-image ubuntu-noble     \
    --server-identifier proxmox-box-01    \
    --ssh-key ~/.ssh/byoh_ctrl_key        \
    --yes
```

Web UI: `http://<ctrl-plane-LAN-ip>:3000` from any device on your LAN.

Create a VM via the UI, it gets `192.168.99.1`, and since your home
router has a static route to the data plane, you can SSH to it from
any LAN device:
```bash
ssh ubi@192.168.99.1
```

For **public reachability**: use your router's port forwarding to
expose one of the `192.168.99.x` IPs via the router's WAN IP on
port 22. Not as clean as Path B's "real public IPs", but works for
a test.

---

## 8. Troubleshooting

### `bundle install` uses system Ruby 3.2.3 instead of mise-installed 4.0.2
**Cause**: mise global activation doesn't add its shim dir to PATH in
non-interactive shells.
**Fix**: `bootstrap-ctrl-plane.sh` sets PATH explicitly. If you're
running commands outside the script, always prepend
`$HOME/.local/share/mise/installs/ruby/4.0.2/bin` to PATH.

### `FATAL: Peer authentication failed for user "clover"` during migrations
**Cause**: Postgres default `pg_hba.conf` uses peer auth on the Unix socket.
**Fix**: `bootstrap-ctrl-plane.sh` handles this. If you hit it running
manually: edit `/etc/postgresql/16/main/pg_hba.conf`, change `peer`
to `trust` on the `local all all` line, `sudo systemctl reload postgresql`.

### Strand stuck at `BootstrapRhizome/setup` with `NetSsh::MissingMock`
**Cause**: `RACK_ENV=test` activates a monkey-patch that raises
`MissingMock` for every real SSH call.
**Fix**: Always use `RACK_ENV=development` on the live ctrl plane.
Specs use `RACK_ENV=test`.

### `npm run prod` fails with "Could not determine executable to run"
**Cause**: Node version too old (package.json pins 24.12.0; Node 20
won't work).
**Fix**: `bootstrap-ctrl-plane.sh` installs Node 24.12.0 via mise.

### `apt-get install ruby-bundler` fails with "has no installation candidate"
**Cause**: Ubuntu 24.04 AMIs ship with a stale apt index.
**Fix**: `user-data-data.sh` runs `apt-get update && apt-get install -y
ruby-bundler` at first boot, before the rhizome bootstrap.

### First VM allocates but strand stays at `wait_sshable` forever
**Cause**: the declared `routed_networks` CIDR isn't actually reachable
from the control plane. On AWS, the `/32` IPs must match the
`byoh_secondary_private_ips` in your tfvars, AND terraform must have
associated EIPs with them.
**Fix**: `terraform output byoh_eip_to_private_ip` should show 3
mappings. If it shows an error or empty map, re-run `terraform apply`.

### Second VM fails with `no space left on any eligible host`
**Cause**: data plane's only storage device is the root disk, which is
nearly full after one VM's boot disk. (See `docs/providers/generic.md`
→ storage discovery gap.)
**Fix**: bump `data_root_size_gb` in tfvars to 200-500 and re-apply.
Or use `m5.metal` + EBS-only with a 500 GB root.

### `Permission denied (publickey)` when SSH-ing to the VM
**Cause**: using `ubuntu@` instead of `ubi@`.
**Fix**: `ssh ubi@<eip>`. Ubicloud's default unix user is `ubi`.

### Strand at `Vm::HostNexus/reboot/try=0` for 20+ minutes
**Not a problem** — bare metal POST is slow, especially on `m5d.metal`
(7-15 min). The `reboot` label is napping on `sshable.available?`
until the host comes back. Check data plane SSH port — if it's
timeout, still POSTing; if it's refused, post-POST but sshd not ready
yet; if banner shows, the reboot label will advance on its next
respirate tick.

### Many child strands (LearnCpu, SetupSysstat, etc.) have `try > 0`
**Not a problem** if they eventually advance. Ubicloud's strand
dispatcher retries on transient errors; you'll often see `try=3` or
`try=5` on a slow host as `apt-get update` takes a while. Only
worry if `try > 10` on the same strand with the same label.

### SG rule error during terraform apply: "The same permission must not appear multiple times"
**Fix**: Don't define two `ingress` blocks for port 22 with overlapping
CIDR lists. Either combine them into one, or give them different
source CIDRs. Already handled in `terraform/aws-byoh/main.tf`.

### VPC limit exceeded during terraform apply
**Cause**: AWS default VPC quota is 5 per region. You already have 4+
VPCs in your chosen region.
**Fix**: Delete unused VPCs, OR pick a different region, OR request a
quota increase (`aws service-quotas request-service-quota-increase
--service-code vpc --quota-code L-F678F1CE --desired-value 10`).

### AWS bare-metal instance fails to terminate (stays `shutting-down` forever)
**Not a problem** — bare metal termination takes 10-15 min (must flush
NVMe caches, verify hardware, etc.). Just wait.

---

## 9. FAQ

### Q: Why does the Ubicloud UI show `10.98.1.130` as my VM's public IP, not the Elastic IP `3.6.57.198`?

**Short answer**: Because on AWS, `10.98.1.130` IS the IP the host kernel
sees when packets arrive — the EIP gets DNAT'd to it at the VPC edge
BEFORE reaching the host. Ubicloud's model stores "the IP the host sees
on the wire" as the VM's public IP.

**Long answer**: Ubicloud was originally designed for Hetzner, where
the provider's core routers route a real public `/29` directly to your
server's NIC. On Hetzner, when someone on the internet sends a packet
to `5.9.1.130`, that EXACT IP arrives on your server's network
interface and gets forwarded to the VM. No NAT, no rewriting. The IP
on the wire IS the IP on the internet — they're the same thing.

On AWS, it's different. AWS's VPC is a virtualized L3 network. When
someone on the internet sends a packet to EIP `3.6.57.198`, AWS's edge
gateway rewrites the destination to `10.98.1.130` (the secondary
private IP the EIP is associated with) BEFORE handing the packet to
your instance. Your instance's kernel sees `10.98.1.130`, not
`3.6.57.198`. Ubicloud looks at what the kernel sees and stores that.

**Workaround**: keep the `byoh_eip_to_private_ip` map from terraform
output handy, and when you SSH to a VM, use the EIP that matches the
private IP shown in the UI.

**Proper fix (Phase 8 work, not yet merged)**: add an optional
`external_ipv4` column to `assigned_vm_address`, populate it from a
mapping stored in `host_provider.config.eip_map`, and display it in
the UI alongside the internal IP. This is ~150 LOC + a migration and
is a legitimate next phase.

### Q: Can I declare the EIPs directly as `routed_networks`?

No — see [Q above](#q-why-does-the-ubicloud-ui-show-1098130-as-my-vms-public-ip-not-the-elastic-ip-3657198).
Ubicloud expects the `routed_network` CIDRs to be IPs the host kernel
actually receives packets for. Since AWS NATs the EIP before the host
sees the packet, the host never sees the EIP as a destination. If you
declare the EIP, the allocator gives it to a VM, but no packets ever
arrive for it.

### Q: Why not use route-table entries like `10.98.100.0/29 → ENI` instead of secondary private IPs?

I tried this in an earlier iteration. AWS rejects `create-route` for
any destination CIDR that's inside the VPC's main CIDR range
(`InvalidParameterValue: "Route destination doesn't match any subnet
CIDR blocks"`). The ONLY supported way to route extra IPs inside the
VPC CIDR to a specific instance is via secondary private IPs on its
ENI. You can route a CIDR that's **outside** the VPC main CIDR (e.g.
`192.168.99.0/29`) via a route table entry, but then AWS doesn't
natively know the IP belongs to the instance, and you need extra
netplan config on the host.

### Q: Can I run Ubicloud without the AWS-specific stuff — i.e. just use real routed public IPs?

Yes — Paths B and C. Hetzner, OVH, Equinix, Leaseweb, Cherry Servers,
Latitude.sh, colocation, and Proxmox+router-static-route all give you
real routed IPs. The UI then correctly shows the real public IP
because there's no NAT in the way.

### Q: Can I run both ctrl plane and data plane on the same machine?

Yes. Set `--main-ip` to `127.0.0.1` (or the local loopback IP) and run
both bootstrap scripts on the same box. You lose the `wait_sshable`
timing benefit (the VM's `sshable.host` points to itself), but
functionally it works. Some Ubicloud features that depend on host-
to-host IPSec overlay (cross-host VM-to-VM) won't apply in a
single-host setup but everything else does.

### Q: Can I run multiple data planes?

Yes — run `bin/register-byoh-host` for each host. Each gets its own
pool of routed IPs, each with its own rhizome bootstrap + SPDK
install. Ubicloud's allocator picks the best host for each new VM
based on free capacity, location, family, and (optionally)
diagnostics preferences.

### Q: How do I replace a data plane without losing my VMs?

You can't (yet). Ubicloud has a "graceful reboot" and "draining" mode
for VmHost but not a full "migrate all VMs off this host" path. For
now, if you need to replace a data plane, destroy its VMs, unregister
it, register the new one, and re-create VMs.

### Q: What happens if the ctrl plane dies?

Nothing happens to running VMs — they keep running on the data plane
because the data plane is completely independent once bootstrapped.
Ubicloud's rhizome agent runs its own state machine on each host via
systemd. When the ctrl plane comes back, respirate reconciles state
from the DB and continues driving strands.

What breaks: no new VMs can be created until the ctrl plane comes
back. No UI access. No scheduled operations (billing, monitoring).

### Q: Can I run Ubicloud on Rocky Linux / Alma / Fedora / Debian?

Not supported yet. The bootstrap scripts assume Ubuntu 24.04 LTS
because that's what upstream Ubicloud's rhizome agent + prep_host.rb
are built around (apt package names, systemd unit paths, etc.). A
proper multi-distro port is a real piece of work.

### Q: Is BYOH production-ready?

Not without more work. Known gaps:
1. **Storage discovery** on multi-NVMe hosts (only root disk is used;
   instance-store NVMes sit idle on `m5d.metal`)
2. **EIP display on AWS** (private IP shown, EIP hidden — see FAQ)
3. **Automated reimage** (BYOH has no PXE infrastructure; reimage
   raises `CapabilityMissing`)
4. **BMC IPMI support** (only Redfish is implemented; IPMI-only BMCs
   fall back to `CapabilityMissing`)
5. **Graceful VM migration** between hosts

Use BYOH for testing, validation, personal homelab, non-critical
workloads. For production you should do the Phase 8+ work to close
these gaps.

---

## 10. Cleaning up

### Path A
```bash
# on your local workstation
cd terraform/aws-byoh
terraform destroy
```
Removes every AWS resource this module created. **Then rotate your
AWS access keys** (they might be in your shell history / `~/.aws/credentials`).

### Path B
- Cancel your VPS at Hetzner/DO/Linode
- Cancel your bare metal at OVH/Hetzner/Equinix/etc.
- Delete the routed IP block (usually automatic on cancellation)

### Path C
- Destroy the Proxmox VMs
- Remove the static route from your home router

---

## 11. What to read next

- **`docs/providers/generic.md`** — deep dive on the BYOH networking
  model, known limitations, per-provider operator pre-work
- **`docs/byoh/QUICKSTART.md`** — compressed version of this doc (10
  steps, no explanations)
- **`scripts/byoh/README.md`** — what the bootstrap scripts do and why
- **`terraform/aws-byoh/README.md`** — the Terraform module, inputs,
  outputs, IAM policy
- **`lib/hosting/generic_apis.rb`** — the driver itself (~100 LOC of
  Ruby, easy read)
- **Upstream Ubicloud docs at https://www.ubicloud.com/docs** — for
  anything about the web UI, CLI, or features that aren't BYOH-specific
- **GitHub issue #3779** — the original "support for self-hosted
  physical servers" discussion that motivated BYOH

Good luck. If you hit something not covered here, open an issue on the
fork's GitHub repo.
