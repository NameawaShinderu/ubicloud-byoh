# Ubicloud BYOH Quickstart — from zero to a running VM on AWS

This walks you from a fresh AWS account to a running Ubicloud VM on
BYOH (bring-your-own-hardware generic provider) in under 30 minutes.
Every step is a concrete command; every gotcha I hit during validation
is documented inline.

**Target audience**: someone who's read the README, cloned this fork,
and wants to see the BYOH driver work end-to-end on real hardware.

**What you get at the end**:
- A Ubicloud control plane on an AWS `t3.medium` instance
- A BYOH data plane on an AWS `m5d.metal` (real bare-metal server
  with Intel Xeon Platinum 8259CL, 96 vCPU, 384 GB RAM, 4×900 GB NVMe)
- 3 publicly-reachable Elastic IPs for your VMs
- A working web UI where you sign up, upload SSH keys, create VMs
- A real VM running Ubuntu 24.04 on the BYOH host, SSH-able from
  anywhere on the internet via its EIP

---

## Prerequisites (on your workstation)

- **AWS account** with sufficient quota:
  - **`L-1216C47A` (Running On-Demand Standard instances)**: ≥ 100 vCPUs (`m5d.metal` consumes 96)
  - **`L-0263D0A3` (EC2-VPC Elastic IPs)**: ≥ 5 free slots (we use 3)
- **AWS credentials** (access key + secret) exported as env vars
- **Terraform ≥ 1.5** (`brew install terraform` or `apt install terraform`)
- **git** for cloning this repo
- An SSH client

---

## Step 1: Clone this repo

```bash
git clone <github-url> ubicloud-byoh
cd ubicloud-byoh
git checkout byoh-driver
```

All BYOH work lives on the `byoh-driver` branch. The `main` branch
is upstream Ubicloud, untouched.

---

## Step 2: Provision AWS infrastructure via Terraform

```bash
cd terraform/aws-byoh
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
# Optionally: tighten operator_ssh_cidr to your /32 public IP
# Optionally: bump data_root_size_gb if you want more VM storage

export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...

terraform init
terraform apply
```

Watch the output — it ends with a `handoff_instructions` block
containing everything you need for the next step:

```
==================================================================
 Ubicloud BYOH test infrastructure is ready.
==================================================================

Control plane (t3.medium, runs postgres + clover + respirate):
  public IP:  13.x.x.x
  private IP: 10.99.1.153
  SSH:        ssh -i ./.generated/byoh_ssh_key ubuntu@13.x.x.x

Data plane (m5d.metal, real bare metal):
  public IP:  52.y.y.y
  private IP: 10.99.1.101  ← this is the --main-ip for register-byoh-host
  instance:   i-xxxxxxxxxxxxxxxxx

BYOH IP pool (3 × secondary private IPs with 1:1 EIP mapping):
  10.99.1.128  ⇄  EIP 13.aaa.aaa.aaa
  10.99.1.129  ⇄  EIP 13.bbb.bbb.bbb
  10.99.1.130  ⇄  EIP 35.ccc.ccc.ccc
```

**Keep this output visible** — you'll need the IPs and the EIP
mapping for the rest of the procedure.

**Timing**: the `m5d.metal` instance takes 7-15 minutes to POST
through its Nitro BMC. `terraform apply` blocks on this.

---

## Step 3: Bootstrap the control plane

SSH into the control plane using the generated key:

```bash
ssh -i terraform/aws-byoh/.generated/byoh_ssh_key ubuntu@<ctrl_public_ip>
```

The MOTD banner tells you what to do next. Essentially:

```bash
# On the control plane:
git clone <github-url> ubicloud
cd ubicloud
git checkout byoh-driver
./scripts/byoh/bootstrap-ctrl-plane.sh
```

This takes 5-10 minutes on first run and installs:

- Ruby 4.0.2 via mise
- Node 24.12.0 via mise
- System packages (postgres-16, build-essential, libpq-dev, …)
- Postgres with `clover`/`clover_password` roles + `clover_test` DB
- `pg_hba.conf` → `trust` for local connections (test-env only)
- `bundle install` → 171 gems
- `npm install` + `npm run prod` → assets compiled
- `.env.rb` with random secrets
- Database migrations
- Sequel schema caches refreshed
- Puma + respirate running in tmux sessions

On a second run it's near-instant — every step checks a marker file
under `~/.ubi-bootstrap/` and skips if already done.

**Verify puma is listening**:

```bash
curl -sS -o /dev/null -w "HTTP %{http_code}\n" http://localhost:3000/login
# → HTTP 200
```

---

## Step 4: Install the control plane's SSH key on the data plane

Ubicloud's `BootstrapRhizome` prog SSHes into the data plane **as
root** using an Ed25519 key it generates during VM host registration.
You need to install that key on the data plane's
`/root/.ssh/authorized_keys` **before** running `register-byoh-host`.

Two options:

### Option A — Let `bin/register-byoh-host` generate a fresh key

```bash
# Still on the control plane:
bin/register-byoh-host \
    --main-ip <data_private_ip> \
    --routed-network 10.99.1.128/32 \
    --routed-network 10.99.1.129/32 \
    --routed-network 10.99.1.130/32 \
    --routed-network fd00:aa55::/64 \
    --location aws-mumbai-byoh \
    --default-boot-image ubuntu-noble \
    --server-identifier aws-m5d-metal-1 \
    # DON'T add --yes yet
```

The CLI will:
1. Generate a fresh Ed25519 keypair
2. Print the **public key** and wait for you to press ENTER

**Now in a second terminal**, still on the control plane:

```bash
# Copy the printed pubkey into a variable or paste it directly:
PUBKEY="ssh-ed25519 AAAA...  ubicloud-byoh-ctrl"

# Install it as root on the data plane (using the AWS keypair):
ssh -i terraform/aws-byoh/.generated/byoh_ssh_key ubuntu@<data_private_ip> \
  "sudo bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo \"$PUBKEY\" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"
```

Now go back to the first terminal and press ENTER on the
`register-byoh-host` prompt.

### Option B — Reuse an existing key you already have

```bash
bin/register-byoh-host \
    --main-ip <data_private_ip> \
    --ssh-key ~/.ssh/my_existing_ed25519_key \
    --routed-network 10.99.1.128/32 \
    --routed-network 10.99.1.129/32 \
    --routed-network 10.99.1.130/32 \
    --routed-network fd00:aa55::/64 \
    --location aws-mumbai-byoh \
    --default-boot-image ubuntu-noble \
    --server-identifier aws-m5d-metal-1 \
    --yes
```

You still have to manually copy the **public** half of that key to
the data plane's `/root/.ssh/authorized_keys` first.

---

## Step 5: Wait for the host to reach `accepting` state

The `register-byoh-host` call queues a `Vm::HostNexus` strand.
Respirate picks it up and drives the host through:

```
start
  → setup_ssh_keys            (no-op for BYOH — Phase 3 guard)
  → bootstrap_rhizome         (creates rhizome user + installs agent over SSH)
  → prep                      (installs SPDK + cloud-hypervisor + nftables)
      + LearnCpu, LearnMemory, LearnOs, LearnStorage, LearnPci
  → setup_hugepages           (allocates 1 G hugepages)
  → setup_storage_backend     (SPDK vhost-user backend)
  → download_boot_images      (ubuntu-noble qcow2 download)
  → reboot                    (the bare-metal POST cycle)
  → verify_spdk + verify_hugepages + start_vms + configure_metrics
  → wait                      (healthy idle state, allocation_state = accepting)
```

Total time on a fresh m5d.metal: **~15-25 minutes**. Most of it is
the reboot cycle (AWS Nitro POST is slow).

**Monitor progress**:

```bash
# In another SSH session on the ctrl plane:
tmux attach -t respirate    # live logs
# or
psql -U clover -d clover_test -c \
  "SELECT prog, label, try, allocation_state FROM strand LEFT JOIN vm_host ON strand.id = vm_host.id WHERE vm_host.id IS NOT NULL;"
```

When you see `allocation_state = accepting`, the host is ready.

---

## Step 6: Create an account + project via the web UI

Open `http://<ctrl_public_ip>:3000/create-account` in your browser.

- Enter an email + password (this creates a Rodauth account)
- Sign up → auto-lands on `/project/<ubid>/dashboard` as owner of a
  default project

---

## Step 7: Upload your VM SSH public key

- Sidebar → **SSH Public Keys** → **Create**
- Name: `my-key`
- Public key: paste your local `~/.ssh/id_ed25519.pub` (or whatever
  you have). This is the key you'll use to SSH into VMs.
- Click **Create**

---

## Step 8: Create a VM

- Sidebar → **Virtual Machines** → **Create Virtual Machine**
- Name: anything
- Location: **eu-central-h1 (Germany)** (our BYOH host is registered
  at Hetzner's default location label because `bin/register-byoh-host`
  doesn't override `location_id`. This is harmless — Ubicloud just
  treats the location as an opaque label.)
- Size: `standard-2` (the smallest valid size — 2 vCPU, 8 GB)
- Boot image: **Ubuntu Noble 24.04 LTS** (downloaded in Step 5)
- SSH key: pick `my-key`
- Enable IPv4: ✅ checked
- Private subnet: `Create new`
- Click **Create**

The VM strand goes through:

```
start
  → allocate          (picks one of 10.99.1.128/.129/.130)
  → clone_disk        (copies Ubuntu image)
  → create_unix_user  (sets up user 'ubi' with your pubkey)
  → prep + run_nftables
  → wait_sshable      (polls the VM's SSH port)
  → wait              (display_state = running)
```

Takes **~2 minutes**.

---

## Step 9: SSH into your VM from anywhere

Once the UI shows `running`, look at the VM's "Public IPv4" field —
it'll be one of the private IPs (`10.99.1.128`/`.129`/`.130`). Look
up the matching EIP from the `byoh_eip_to_private_ip` terraform
output.

```bash
# From your laptop (anywhere on the internet):
ssh ubi@<matching-eip>
# Default username is 'ubi' — NOT 'ubuntu'.
# Key comes from whatever you uploaded in Step 7.
```

Inside the VM:

```bash
uname -a          # → Linux vm... 6.8.0-xxx-generic ... x86_64
cat /proc/cpuinfo | grep "model name" | head -1
# → Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz  (the m5d.metal's CPU)
df -h             # → vda ~40 GiB, backed by SPDK vhost-user
free -h           # → 8 GiB hugepages
```

Congratulations — you're inside a real KVM VM running on AWS
bare-metal hardware, reached via a real public Elastic IP, with full
Ubicloud-managed networking — all via the BYOH generic driver with
zero Hetzner-specific code paths fired.

---

## Teardown

```bash
# On your workstation:
cd terraform/aws-byoh
terraform destroy
```

Removes every AWS resource this terraform module created: both
instances, EIPs, SG, RT, IGW, subnet, VPC, keypair.

---

## Troubleshooting — every gotcha I hit during validation

### `bundle install` uses system Ruby 3.2.3 instead of mise-installed 4.0.2

**Cause**: mise global activation doesn't add its shim dir to PATH in non-interactive shell runs.

**Fix**: `bootstrap-ctrl-plane.sh` sets `PATH=$HOME/.local/share/mise/installs/ruby/4.0.2/bin:$PATH` explicitly.

### `FATAL: Peer authentication failed for user "clover"` during migrations

**Cause**: Postgres default `pg_hba.conf` uses peer auth on the Unix socket.

**Fix**: `bootstrap-ctrl-plane.sh` rewrites local auth to `trust` (test env only — NEVER do this on production).

### Strands stuck at `BootstrapRhizome/setup` with `NetSsh::MissingMock`

**Cause**: `RACK_ENV=test` activates the `lib/net_ssh.rb` test-mode monkey patch that raises `MissingMock` for every real SSH call.

**Fix**: run respirate with `RACK_ENV=development`. Specs use `RACK_ENV=test`, the live ctrl plane uses `development`.

### `npm run prod` fails with "Could not determine executable to run"

**Cause**: Node 20 is too old (package.json pins Node 24.12.0).

**Fix**: `bootstrap-ctrl-plane.sh` installs Node 24.12.0 via mise.

### `apt-get install ruby-bundler` fails with "has no installation candidate"

**Cause**: Ubuntu 24.04 AMIs ship with a stale apt index. The `bundler` package exists but isn't in the cached list until `apt-get update` runs.

**Fix**: `user-data-data.sh` runs `apt-get update && apt-get install -y ruby-bundler` at first boot, before the rhizome bootstrap could race on it.

### First VM allocates but strand stays at `wait_sshable`

**Cause**: declared `routed_networks` CIDR isn't actually routable from the control plane to the host. On AWS VPC, a CIDR inside the main VPC CIDR can't be overridden via route-table entry; it must be expressed as secondary private IPs on the ENI.

**Fix**: terraform assigns `secondary_private_ips = ["10.99.1.128", "10.99.1.129", "10.99.1.130"]` to the data plane's ENI at creation time. Your `routed_networks` list in `bin/register-byoh-host` must exactly match these IPs as `/32`.

### Second VM allocation fails with `no space left on any eligible host`

**Cause**: the data plane's LearnStorage prog only discovered the root EBS disk. Instance-store NVMes on `m5d.metal` are unregistered, so the 80 GB root is the only pool and fills after one VM.

**Fix (temporary)**: bump `data_root_size_gb = 200` in `terraform.tfvars` before apply. See `docs/providers/generic.md` → "Known limitation: storage device discovery" for the proper Phase 8 fix.

### `Permission denied (publickey)` when SSH-ing to the VM

**Cause**: you're using `ubuntu@` instead of `ubi@`. Ubicloud's default unix user is `ubi`.

**Fix**: `ssh ubi@<eip>`.

### `boot_image` table is empty, VM won't allocate

**Cause**: you forgot to pass `--default-boot-image ubuntu-noble` to `register-byoh-host`.

**Fix**: re-run registration with the flag, or manually trigger via a Ruby console: `VmHost.first.download_boot_image("ubuntu-noble")`.

---

## Next steps (if you want to go further)

- Create multiple VMs via the UI and watch the allocator pick random IPs from the pool
- Explore the web UI's project settings, firewalls, private subnets
- Destroy the VMs via the UI and re-create — confirm IPs get recycled
- Try the `vm_host.hardware_reset` path (dev-mode only) to exercise the BMC-via-Redfish path (note: AWS bare metal has no BMC; this will raise `CapabilityMissing` as expected)
- Replicate the setup on OVH or Hetzner — the only thing that changes is Step 2 (provisioning) and the "install routed IP block" pre-work. Everything from Step 3 onward is identical.
