# Ubicloud BYOH — AWS Console Setup (zero-tooling edition)

> **Not using AWS?** If you have a Proxmox host at home, read
> [`SETUP_PROXMOX.md`](SETUP_PROXMOX.md) instead — same end state,
> no cloud account needed, free to run. This doc is for people who
> already have an AWS account and want the fastest on-ramp there.

**Audience**: you have an AWS account and a web browser. That's it.
You don't need Terraform, an SSH client, a "bastion" machine, a laptop
with keys on it, or any CLI tools at all. Everything happens inside
the AWS Console using **Session Manager** (the "Connect" button on an
EC2 instance) to get browser-based shells on each host.

**Time**: ~30 minutes of clicking + ~10 minutes of waiting for the
ctrl plane bootstrap to finish.

**Cost**: ~$5.50/hr while running (t3.medium + m5d.metal bare metal
+ 3 Elastic IPs). Destroy everything when you're done and it stops
billing.

**End state**: you can log into the Ubicloud web UI in your browser,
create a VM, SSH into it from anywhere on the internet, and it's
running on real AWS bare metal via the BYOH generic provider.

---

## Table of contents

1. [What you're building](#1-what-youre-building)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Create a VPC](#step-1--create-a-vpc)
4. [Step 2 — Create an IAM role for SSM](#step-2--create-an-iam-role-for-ssm)
5. [Step 3 — Create a security group](#step-3--create-a-security-group)
6. [Step 4 — Launch the control plane instance](#step-4--launch-the-control-plane-instance)
7. [Step 5 — Launch the data plane instance (bare metal)](#step-5--launch-the-data-plane-instance-bare-metal)
8. [Step 6 — Allocate and associate 3 Elastic IPs](#step-6--allocate-and-associate-3-elastic-ips)
9. [Step 7 — Open the control plane shell (Session Manager)](#step-7--open-the-control-plane-shell-session-manager)
10. [Step 8 — Bootstrap the control plane](#step-8--bootstrap-the-control-plane)
11. [Step 9 — Generate the ctrl→data SSH key](#step-9--generate-the-ctrldata-ssh-key)
12. [Step 10 — Install the key on the data plane (Session Manager)](#step-10--install-the-key-on-the-data-plane-session-manager)
13. [Step 11 — Register the BYOH host](#step-11--register-the-byoh-host)
14. [Step 12 — Watch it bootstrap](#step-12--watch-it-bootstrap)
15. [Step 13 — Open the web UI and create your first VM](#step-13--open-the-web-ui-and-create-your-first-vm)
16. [Step 14 — SSH into your VM from anywhere](#step-14--ssh-into-your-vm-from-anywhere)
17. [Troubleshooting](#troubleshooting)
18. [FAQ](#faq)
19. [Cleanup — tear it all down](#cleanup--tear-it-all-down)
20. [Advanced variants](#advanced-variants)

---

## 1. What you're building

Two Ubuntu EC2 instances and three Elastic IPs inside a dedicated VPC:

```
         +------------------------  VPC 10.98.0.0/16  ---------------------+
         |                                                                  |
         |    +--------------------+         +------------------------+    |
Browser -|--> |  ubi-byoh-ctrl     |         |  ubi-byoh-data         |    |
 (UI)    |    |  t3.medium         | --SSH-> |  m5d.metal (real bare  |    |
         |    |  Ubicloud web UI   |         |  metal, 96 vCPU/384GB) |    |
         |    |  + Postgres        |         |                        |    |
         |    |  + respirate       |         |  runs your VMs inside  |    |
         |    |  + ctrl logic      |         |  KVM + SPDK + CH       |    |
         |    +--------------------+         +--+---------------------+    |
         |                                      |                           |
         |                           ENI secondary IPs:                    |
         |                           10.98.1.128 <-> EIP #1                |
         |                           10.98.1.129 <-> EIP #2                |
         |                           10.98.1.130 <-> EIP #3                |
         +------------------------------------------------------------------+

       internet  -->  EIP #1 (e.g. 52.x.x.x)  -->  your VM #1
       internet  -->  EIP #2                  -->  your VM #2
       internet  -->  EIP #3                  -->  your VM #3
```

- **Control plane** runs the Ubicloud stack: the web UI (Roda/Puma on
  port 3000), the Postgres database, and the `respirate` dispatcher
  that drives state machines (e.g. "create a VM").
- **Data plane** is the actual bare metal host. Ubicloud SSHes *into*
  it from the control plane and runs VM workloads there via
  `cloud-hypervisor` + `SPDK`. It needs to be bare metal (`.metal`
  suffix on the instance type) because nested virtualization won't
  give SPDK real NVMe access.
- **3 Elastic IPs** each 1:1-mapped to one secondary private IP on
  the data plane's ENI. Each is a "slot" in the BYOH IP pool — when
  a VM is allocated one of those slots it becomes publicly reachable
  from the internet via the matching EIP.

You will manage **both** instances entirely through the AWS Console's
"Connect" button (Session Manager), which gives you an in-browser
shell. **No SSH client or key file ever touches your laptop.** The
control plane SSHes to the data plane over the VPC's internal network
using a key that the control plane generates itself and that you
copy-paste into the data plane's `authorized_keys` via a second
Session Manager browser tab.

---

## 2. Prerequisites

1. An AWS account with permission to create VPCs, EC2 instances
   (including **bare metal** — m5d.metal or equivalent), Elastic IPs,
   and IAM roles. If this is a shared corporate account, make sure
   someone's okay with you adding the infra below.
2. A region that offers bare-metal instance types. All of these work:
   `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, `eu-central-1`,
   `ap-south-1`, `ap-southeast-1`, `ap-northeast-1`. This guide uses
   **ap-south-1 (Mumbai)** throughout. Pick whatever is closest to
   you and substitute the region name everywhere.
3. A web browser. You will not install anything locally.

That's it. You do not need Terraform, an SSH client, a key file, a
"jump box", a VPN, or a local Ubicloud checkout.

**One thing to check before you start**: service limits. AWS accounts
start with a bare-metal vCPU quota of 0 in many regions. Go to
**Service Quotas → EC2 → "Running On-Demand High Memory instances"**
(and also the plain "Running On-Demand Standard instances" limit) and
confirm your limit is at least **96** (m5d.metal has 96 vCPU).
If it's 0 or less than 96, request an increase — approval usually
takes <1 hour but can take up to a business day. Without this you'll
hit `VcpuLimitExceeded` at step 5.

---

## Step 1 — Create a VPC

Console path: **VPC → Your VPCs → Create VPC**

In the creation wizard, select **"VPC and more"** (this gives you a
one-shot wizard that creates the VPC, subnets, internet gateway, and
route tables all together).

Fill in:

| Field                         | Value                     |
|-------------------------------|---------------------------|
| Name tag auto-generation      | `ubi-byoh`                |
| IPv4 CIDR block               | `10.98.0.0/16`            |
| IPv6 CIDR block               | No IPv6 CIDR              |
| Tenancy                       | Default                   |
| Number of Availability Zones  | **1**                     |
| Number of public subnets      | **1**                     |
| Number of private subnets     | **0**                     |
| NAT gateways                  | **None**                  |
| VPC endpoints                 | **None**                  |
| Enable DNS hostnames          | checked                   |
| Enable DNS resolution         | checked                   |

Click **Create VPC**. Wait for the green success banner (~10 seconds).

**Why these values**:
- `10.98.0.0/16` — an RFC1918 block that's very unlikely to collide
  with your existing AWS VPCs, on-prem networks, or VPN tunnels. If
  you already use 10.98.x.x for something else, substitute any /16
  that's free (e.g. 10.77.0.0/16). Write down whatever you pick —
  you'll reference it in later steps.
- **1 AZ, 1 public subnet, no NAT** — this is a test environment.
  One AZ is enough, a public subnet is the minimum to reach the
  internet, and you don't need a NAT gateway because both instances
  have public IPs directly.
- **DNS hostnames + resolution on** — required for Session Manager
  to resolve the SSM endpoints.

After creation, note the **subnet ID** (looks like `subnet-0abc...`)
of the single public subnet — you'll select it when launching the
instances. Also note the **availability zone** (e.g. `ap-south-1a`).

---

## Step 2 — Create an IAM role for SSM

This role is what makes the "Connect → Session Manager" button work.
Without it, the Connect button will say **"SSM Agent is not online"**
and you'll be stuck needing a real SSH client.

Console path: **IAM → Roles → Create role**

- **Trusted entity type**: AWS service
- **Use case**: EC2 → next
- **Permissions**: search for and tick **`AmazonSSMManagedInstanceCore`**
  (this is the AWS-managed policy that grants the minimum permissions
  for SSM to work — agent check-in, session data exchange). Nothing else.
- Click next.
- **Role name**: `ubi-byoh-ssm-role`
- Click **Create role**.

AWS also needs an **instance profile** with the same name as the role
— it creates this automatically when you make a role via the console,
so you don't have to do anything extra. Just remember the name:
`ubi-byoh-ssm-role` (you'll select it when launching both EC2
instances).

**Why this works**: Ubuntu 24.04 AMIs from Canonical ship with the
SSM agent pre-installed and enabled. The agent reaches out to the
regional SSM endpoint and registers the instance *if and only if*
the instance has an attached IAM role granting it permission to do
so. Once registered, the Console's "Connect" button can open a
WebSocket straight to a shell on the instance, tunneled through
AWS's control plane. No inbound SSH port required. No key.

---

## Step 3 — Create a security group

Console path: **VPC → Security Groups → Create security group**

| Field                   | Value                                       |
|-------------------------|---------------------------------------------|
| Security group name     | `ubi-byoh-sg`                               |
| Description             | `Ubicloud BYOH test — web UI + intra-SG`    |
| VPC                     | *select the VPC you just created*           |

**Inbound rules** (click "Add rule" for each):

| Type        | Port  | Source          | Description                         |
|-------------|-------|-----------------|-------------------------------------|
| Custom TCP  | 3000  | `0.0.0.0/0`     | Ubicloud web UI                     |
| HTTPS       | 443   | `0.0.0.0/0`     | optional TLS (future-proof)         |
| SSH         | 22    | `0.0.0.0/0`     | SSH into your VMs via EIPs          |
| All traffic | all   | `ubi-byoh-sg`   | **intra-SG (critical)**             |

To add the "intra-SG" rule: Type = **All traffic**, Source =
**Custom**, then in the source box start typing the security group's
own name and pick it from the dropdown (it will end up looking like
`sg-0xxx / ubi-byoh-sg`). This lets the control plane talk to the
data plane on any port without exposing anything to the internet,
*and* lets VM-to-VM traffic flow inside the data plane.

**Outbound rules**: leave the default "All traffic to 0.0.0.0/0".

Click **Create security group**.

**Do you need to open SSH 22 to 0.0.0.0/0?** Only if you want to SSH
into your created VMs from the public internet. Each VM will live
behind one of the 3 EIPs from Step 6. If you're going to use VMs only
from inside the VPC, tighten this to `10.98.0.0/16` instead.

**Why no port 22 rule for operator SSH?** Because you're not going
to use operator SSH. Session Manager is the only way you'll shell
into the ctrl and data planes, and Session Manager doesn't use port
22 — the traffic is tunneled over HTTPS to the AWS control plane
and then out-of-band to the SSM agent inside the instance. You never
touch port 22 from the outside.

---

## Step 4 — Launch the control plane instance

Console path: **EC2 → Instances → Launch instances**

| Field                     | Value                                              |
|---------------------------|----------------------------------------------------|
| Name                      | `ubi-byoh-ctrl`                                    |
| Application / OS Images   | **Ubuntu Server 24.04 LTS (HVM), SSD, x86_64**     |
| Instance type             | **t3.medium**                                      |
| Key pair                  | **"Proceed without a key pair (Not recommended)"** |
| VPC                       | `ubi-byoh-vpc`                                     |
| Subnet                    | `ubi-byoh-subnet-public1-<AZ>`                     |
| Auto-assign public IP     | **Enable**                                         |
| Firewall (security groups)| **Select existing** → `ubi-byoh-sg`                |
| Configure storage         | **40 GiB, gp3**                                    |

**"Proceed without a key pair"** is the whole point. A key pair is
only useful if you're going to SSH into the instance from an SSH
client, which you aren't — you're going to use Session Manager.
Having no key pair means there's simply no way to brute-force
password or key login from the internet; the only shell access path
is Session Manager, which is authenticated by your AWS credentials.

Now expand **Advanced details** at the bottom of the launch wizard
and set:

| Field                     | Value                                             |
|---------------------------|---------------------------------------------------|
| IAM instance profile      | `ubi-byoh-ssm-role` *(from Step 2)*               |
| User data                 | *paste the script below*                          |

**User data script** — this runs automatically on first boot. It
installs the handful of tools the control plane bootstrap script
needs before it can run:

```bash
#!/bin/bash
set -e
apt-get update
apt-get install -y git tmux jq curl unzip ca-certificates

# Friendly hostname
hostnamectl set-hostname ubi-byoh-ctrl

# Pre-create ubuntu user's bootstrap marker dir
install -d -o ubuntu -g ubuntu /home/ubuntu/.ubi-bootstrap

# MOTD so it's obvious which host you're on in Session Manager
cat > /etc/motd <<'MOTD'
   ==================================================================
    Ubicloud BYOH — CONTROL PLANE
    Next: sudo su - ubuntu, then run the bootstrap script
    (see docs/byoh/SETUP.md Step 8)
   ==================================================================
MOTD
```

Click **Launch instance**. Wait ~30 seconds for the instance to reach
the "Running" state, then wait another ~60 seconds for Session
Manager to register it. The user-data itself takes ~30 seconds to
finish.

**How to tell Session Manager is ready**: go to
**EC2 → Instances → ubi-byoh-ctrl → Connect → Session Manager tab**.
If the "Connect" button is grayed out with a warning about "SSM agent
not online", give it one more minute and refresh. If it's still gray
after 3 minutes, check the troubleshooting section — the usual causes
are a missing IAM role or a VPC that can't reach the SSM service
endpoint.

---

## Step 5 — Launch the data plane instance (bare metal)

This is the one that costs money — m5d.metal is **~$5.42/hour**
on-demand in most regions. Don't forget to destroy it when you're
done testing.

Console path: **EC2 → Instances → Launch instances**

| Field                     | Value                                              |
|---------------------------|----------------------------------------------------|
| Name                      | `ubi-byoh-data`                                    |
| Application / OS Images   | **Ubuntu Server 24.04 LTS (HVM), SSD, x86_64**     |
| Instance type             | **m5d.metal** *(or the cheapest `.metal` in your region)* |
| Key pair                  | **"Proceed without a key pair"**                   |
| VPC                       | `ubi-byoh-vpc`                                     |
| Subnet                    | same public subnet as the ctrl instance            |
| Auto-assign public IP     | **Enable**                                         |
| Firewall                  | **Select existing** → `ubi-byoh-sg`                |
| Configure storage         | **120 GiB, gp3**                                   |

**Why m5d.metal?**
- It's **actual bare metal**, not nested virt — cloud-hypervisor and
  SPDK need direct access to VT-x/EPT and to real NVMe devices,
  which a regular EC2 instance can't provide.
- In `ap-south-1` (Mumbai) at time of writing it's ~$5.42/hr
  on-demand; ap-south-1, ap-southeast-1, us-east-2, and eu-central-1
  are usually the cheapest.
- 96 vCPU + 384 GB RAM + 4×838 GB NVMe instance store + 25 Gbps
  networking. Wildly oversized for a single test VM but it's the
  floor — there's no smaller bare-metal option on AWS.

**Why 120 GiB root disk?** The four instance-store NVMes on
m5d.metal are **not automatically used** — that's a known limitation
of the current BYOH storage discovery logic. SPDK will serve VM disk
images from `/var/storage` which lives on the root EBS volume.
120 GB covers 1 VM with the default 40 GB root disk plus image cache
plus ~20 GB headroom. Bump to 200–300 GB if you want to create
multiple VMs or larger VMs.

**Expand Advanced details** at the bottom:

| Field                     | Value                                             |
|---------------------------|---------------------------------------------------|
| IAM instance profile      | `ubi-byoh-ssm-role`                               |
| User data                 | *paste the script below*                          |

**User data script**:

```bash
#!/bin/bash
set -e
apt-get update
apt-get install -y openssh-server curl ca-certificates

# Allow root public-key login (Ubicloud ctrl plane SSHes in as root)
sed -i 's|^#*PermitRootLogin.*|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config
systemctl restart ssh

# Kernel routing for "instance as a router" — AWS requires source/dest
# check OFF too (set that in the console after launch), and these
# sysctls to let the kernel forward packets destined for VMs.
cat > /etc/sysctl.d/99-ubi-byoh.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.proxy_arp = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-ubi-byoh.conf

hostnamectl set-hostname ubi-byoh-data

cat > /etc/motd <<'MOTD'
   ==================================================================
    Ubicloud BYOH — DATA PLANE (m5d.metal bare metal)
    This is where your VMs will actually run. Don't touch anything
    here unless you know what you're doing. Configuration is driven
    by the control plane via SSH.
   ==================================================================
MOTD
```

**Now — before clicking Launch — scroll up to the "Network settings"
box and click "Edit"**. A wider view opens. Look for
**"Advanced network configuration"** and then the
**"Secondary IPv4 addresses"** field — the exact UI changes from
time to time but the field is always under the network interface
section. Set:

| Field                          | Value                                        |
|--------------------------------|----------------------------------------------|
| Assign a secondary private IP  | **Assign 3 IP addresses manually**           |
| IP 1                           | `10.98.1.128`                                |
| IP 2                           | `10.98.1.129`                                |
| IP 3                           | `10.98.1.130`                                |

If the console doesn't let you type them manually, just pick
**"Assign automatically: 3"** — AWS will pick 3 random IPs from the
subnet. Write down whatever it picks, because you'll reference those
exact 3 IPs in Step 6, Step 11, and every time you register a VM.

Click **Launch instance**.

**Critical post-launch step** — wait for the instance to reach
**Running**, then:

1. Click the instance
2. **Actions → Networking → Change source/destination check**
3. Click **Stop** (yes, "stop" — the button toggles the setting)
4. Confirm

Verify: the instance's detail page now shows **"Source/dest. check:
false"**. If it still says `true`, repeat — AWS occasionally no-ops
the first click.

**Why this matters**: the data plane is a router. When a VM sends a
packet, the source IP is the VM's private IP (one of
10.98.1.128/129/130), *not* the data plane's primary IP. AWS
normally drops such packets ("spoofing protection"). Disabling
source/dest check is the AWS-supported way to say "yes, this
instance is an intentional router". This is exactly how NAT
instances, VPN gateways, and similar custom appliances work.

Bare-metal instances take **5–8 minutes** to reach "Running" (they're
actually being racked — AWS physically dedicates a server to you),
and **10–20 minutes** to fully terminate when you destroy them later.
Be patient.

---

## Step 6 — Allocate and associate 3 Elastic IPs

Each EIP becomes a "slot" in the BYOH IP pool. When a VM is assigned
the matching private IP, that VM becomes reachable from the internet
on the associated EIP.

Console path: **EC2 → Elastic IPs → Allocate Elastic IP address**

For each of the 3 EIPs:

1. **Allocate Elastic IP address** → Network border group = default
   → **Allocate**. Name the allocation `ubi-byoh-eip-0` (then `-1`,
   then `-2` on subsequent allocations).
2. Select the new EIP → **Actions → Associate Elastic IP address**:

    | Field              | Value                                              |
    |--------------------|----------------------------------------------------|
    | Resource type      | **Instance**                                       |
    | Instance           | `ubi-byoh-data`                                    |
    | Private IP address | `10.98.1.128` (or .129, .130 — one per EIP)        |
    | Reassociation      | **Allow reassociation** (checked)                  |

3. Click **Associate**.

Repeat for the other two. At the end, the **Elastic IPs** list
should show three entries, each associated with `ubi-byoh-data`,
each with a distinct private IP in the `10.98.1.12x` range.

**Write down the mapping.** You will need it in Step 14 and anywhere
you want to reach a specific VM from the internet. Example:

```
  EIP 52.66.110.229  <->  10.98.1.128  (pool slot 0)
  EIP 3.6.57.198     <->  10.98.1.129  (pool slot 1)
  EIP 65.0.90.4      <->  10.98.1.130  (pool slot 2)
```

You can always re-check this mapping later by going to
**EC2 → Elastic IPs** and looking at the "Private IP address"
column.

**Each unassociated EIP costs about $3.60/month** — so if you have
spare EIPs sitting in your account from previous testing, either
associate them to something or release them.

---

## Step 7 — Open the control plane shell (Session Manager)

This is the magic step that makes the whole "zero tooling" thing
work.

Console path: **EC2 → Instances → ubi-byoh-ctrl → Connect**

At the top of the Connect page, select the **Session Manager** tab
(the other tabs are EC2 Instance Connect, SSH client, and Serial
console — you want Session Manager).

Click **Connect** (the button should be blue and enabled; if it's
grayed out, wait ~1 minute and refresh — the SSM agent needs time
to register).

A terminal opens in a new browser tab. You're logged in as `ssm-user`
— not `root`, not `ubuntu`. Switch to the `ubuntu` user before you
do anything else:

```bash
sudo su - ubuntu
```

You're now in a shell as `ubuntu` on the control plane, with no local
tools, no SSH key, no config files — exactly the state a new machine
starts in.

**Keep this tab open.** You'll run steps 8, 9, 11, and 12 in this
tab.

---

## Step 8 — Bootstrap the control plane

In the ctrl shell from Step 7, run:

```bash
curl -sSL https://raw.githubusercontent.com/NameawaShinderu/ubicloud-byoh/byoh-driver/scripts/byoh/bootstrap-ctrl-plane.sh | bash
```

This downloads the idempotent bootstrap script and runs it. The
script does 11 steps:

1. `apt-get install` build tools, libpq, Postgres 16
2. Install `mise` (language version manager) into `~/.local`
3. Install Ruby 4.0.2 via mise (~3 minutes — compiles Ruby from source)
4. Install Node.js 24.12.0 via mise
5. Clone `ubicloud/ubicloud` at the `byoh-driver` branch into `~/ubicloud`
6. Configure Postgres (create role, database, trust auth for localhost)
7. `bundle install` all Ruby dependencies
8. `npm install && npm run prod` (build web UI assets)
9. Generate `.env.rb` with a dev-mode secret
10. Run database migrations
11. Start `puma` (web UI on port 3000) and `respirate` (dispatcher)
    in tmux sessions

**Expected runtime**: ~8–12 minutes on t3.medium. The Ruby compile
(step 3) dominates.

You'll see progress output for each step. If it hits an error, the
script stops and the marker file for that step is **not** created —
so you can fix the issue and re-run the same command; it will pick
up exactly where it left off.

**What "done" looks like**: the final lines should say:

```
━━━━━ 11. Start services in tmux ━━━━━
  started: puma (ctrl-plane-puma session)
  started: respirate (ctrl-plane-respirate session)

✓ Control plane bootstrap complete.

Next: run bin/register-byoh-host (see docs/byoh/SETUP.md Step 11)
```

Verify services are alive:

```bash
cd ~/ubicloud
tmux ls
# should show: ctrl-plane-puma and ctrl-plane-respirate sessions
curl -sI http://localhost:3000/ | head -1
# should print: HTTP/1.1 302 Found    (or 200)
```

If `curl localhost:3000` doesn't respond, `tmux attach -t
ctrl-plane-puma` to see what's happening — usually a typo in a
.env.rb or a port already in use.

---

## Step 9 — Generate the ctrl→data SSH key

Still in the ctrl Session Manager shell:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/byoh_data -N '' -C 'ubi-byoh ctrl-to-data'
cat ~/.ssh/byoh_data.pub
```

You'll see one line output that looks like:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIXXXXXXXXXXX ubi-byoh ctrl-to-data
```

**Select that entire line with your mouse and copy it.** You're going
to paste it into the data plane shell in the next step.

**Tip**: Session Manager's browser shell supports normal
select-to-copy. Triple-click on the line to select the whole line,
then Ctrl+C (or Cmd+C on Mac).

**What this key is for**: the Ubicloud control plane SSHes *into*
the data plane as `root` to run provisioning commands, push rhizome
(the on-host agent), configure SPDK, etc. That SSH session uses this
key. It lives only on the ctrl plane — you don't need it on your
laptop, and it never leaves the ctrl plane.

---

## Step 10 — Install the key on the data plane (Session Manager)

**Open a new browser tab** (keep the ctrl tab open, you'll come back
to it). In the new tab, go to:

**EC2 → Instances → ubi-byoh-data → Connect → Session Manager → Connect**

You're now in an `ssm-user` shell on the data plane. Append the
public key you copied from Step 9 into `/root/.ssh/authorized_keys`:

```bash
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh
echo 'PASTE-THE-PUBLIC-KEY-LINE-HERE' | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
```

Replace `PASTE-THE-PUBLIC-KEY-LINE-HERE` with the actual line you
copied. Make sure you keep the single quotes so the shell doesn't
try to interpret anything inside.

Verify:

```bash
sudo cat /root/.ssh/authorized_keys
```

Should show your key line exactly once.

**Test the SSH from ctrl to data** — go back to the **ctrl**
Session Manager tab and run:

```bash
# Get the data plane's primary private IP first — from the EC2 console:
# EC2 → Instances → ubi-byoh-data → Networking tab → Private IPv4 address
# (it will be something like 10.98.1.42 — NOT one of the pool IPs)
DATA_IP=10.98.1.XX  # substitute yours

ssh -i ~/.ssh/byoh_data -o StrictHostKeyChecking=no root@$DATA_IP 'hostname && uname -a'
```

Expected output:

```
ip-10-98-1-XX
Linux ip-10-98-1-XX 6.8.0-... x86_64 GNU/Linux
```

If you get "Permission denied", double-check that the key line in
`/root/.ssh/authorized_keys` matches exactly what `cat
~/.ssh/byoh_data.pub` prints on the ctrl plane.

You can now close the data plane Session Manager tab — you won't
need it again except for debugging. From here on everything happens
from the ctrl plane.

---

## Step 11 — Register the BYOH host

Back in the ctrl Session Manager tab:

```bash
cd ~/ubicloud
export RACK_ENV=development

./bin/register-byoh-host \
  --provider generic \
  --main-ip 10.98.1.XX \
  --routed-network 10.98.1.128/32 \
  --routed-network 10.98.1.129/32 \
  --routed-network 10.98.1.130/32 \
  --ssh-key ~/.ssh/byoh_data \
  --location mumbai-test \
  --default-boot-image ubuntu-noble \
  --yes
```

**Replace `10.98.1.XX` with the data plane's *primary* private IP**
— the same one you used to SSH into it in Step 10. This is the
address the control plane will SSH to for all provisioning.

Flags:

- `--main-ip`: the data plane's management IP (where SSH connects)
- `--routed-network`: one flag per pool slot, each as a `/32`. Every
  VM you later create will be assigned one of these IPs. Three slots
  = three concurrent VMs. Add more `--routed-network` lines if you
  allocated more EIPs.
- `--ssh-key`: path to the private key you generated in Step 9
- `--location`: a free-form label. Shows up in the web UI. Use
  anything recognizable like `mumbai-test`, `homelab`, `aws-sbx`.
- `--default-boot-image`: pre-download this boot image on the host
  at registration time. **Critical** — without this flag, the
  `boot_image` table stays empty and the VM allocator will fail with
  `"no space left on any eligible host"` when you try to create a
  VM.
- `--yes`: skip the interactive confirmation prompt

Expected output:

```
Registering BYOH host...
  provider      = generic
  main_ip       = 10.98.1.XX
  location      = mumbai-test
  routed nets   = [10.98.1.128/32, 10.98.1.129/32, 10.98.1.130/32]
  ssh key       = /home/ubuntu/.ssh/byoh_data
  boot images   = [ubuntu-noble]

Created host_provider row
Created location
Created sshable
Created vm_host
Created addresses (3 routable)
Queued Prog::Vm::HostNexus strand <strand-ubid>

Registration complete.
  vm_host ubid:  vh-XXXXX
  strand:        st-XXXXX
```

The strand ID is the state-machine instance that the `respirate`
dispatcher will now drive forward.

---

## Step 12 — Watch it bootstrap

The ctrl plane has queued a strand; now it will SSH to the data
plane, install rhizome, set up SPDK, learn the network, install
the boot image, and mark the host as `accepting`. Follow along:

```bash
cd ~/ubicloud
bundle exec ruby -e '
  require_relative "model"
  strand_id = ENV["ST"]
  loop do
    s = Strand[ubid: strand_id]
    puts "#{Time.now.strftime("%H:%M:%S")} label=#{s.label.inspect} exitval=#{s.exitval.inspect}"
    break if s.exitval
    sleep 5
  end
' ST=st-XXXXX
```

Expected progression (~8 minutes end-to-end on m5d.metal):

```
13:04:12 label="start"                exitval=nil
13:04:17 label="bootstrap_rhizome"    exitval=nil
13:04:32 label="install_rhizome"      exitval=nil
13:05:47 label="prep_host"            exitval=nil
13:06:52 label="learn_network"        exitval=nil
13:07:02 label="learn_storage"        exitval=nil
13:07:12 label="setup_hugepages"      exitval=nil
13:07:22 label="setup_spdk"           exitval=nil
13:09:10 label="install_vhost_backend" exitval=nil
13:09:20 label="download_boot_images" exitval=nil
13:11:40 label="wait_host_ready"      exitval=nil
13:12:10 label={"msg"=>"host ready"}  exitval={"host_id"=>"vh-XXXX"}
```

When you see the final line with a non-nil `exitval`, the host is
in the `accepting` state and ready to serve VMs.

**Stuck at one label for >5 minutes?** Check `tmux attach -t
ctrl-plane-respirate` to see the live dispatcher output. Most stalls
are network timeouts on `prep_host` (apt-get reaching out to Ubuntu
mirrors) or `setup_spdk` (the SPDK compile).

---

## Step 13 — Open the web UI and create your first VM

Get the ctrl plane's **public** IP from the EC2 console
(**ubi-byoh-ctrl → Details → Public IPv4 address**, something like
`13.206.71.54`). In your **laptop's** browser, open:

```
http://<ctrl-public-ip>:3000/
```

**First-time setup on the web UI**:

1. You'll be redirected to `/login`. Click **"Create account"**.
2. Fill in: email, name, password. Click **Create account**.
3. You'll need to confirm your email — in dev mode the confirmation
   link is printed to the Puma log, not actually emailed. Go to the
   ctrl Session Manager tab and run:
   ```bash
   tmux attach -t ctrl-plane-puma
   ```
   Search the tmux scrollback (Ctrl+B then `[` to enter copy mode,
   then Ctrl+S to search) for `"verify/"` — you'll find a URL like
   `http://localhost:3000/verify/xyz123`. Copy the `/verify/xyz123`
   part, paste onto your public URL:
   `http://<ctrl-public-ip>:3000/verify/xyz123`, hit enter. Detach
   from tmux with Ctrl+B then `d`.
4. Log in with the email + password you just set.
5. You're in. Create a project — any name, e.g. "test-project".

**Upload your public SSH key** (this goes *into* the VM you're about
to create, so you can SSH into it from your laptop):

1. Left sidebar → **SSH keys** → **Create SSH key**
2. Name: `my-laptop`
3. Public key: paste your laptop's `~/.ssh/id_ed25519.pub` or
   `~/.ssh/id_rsa.pub` (generate one with `ssh-keygen -t ed25519`
   locally if you don't have one yet)
4. Create

**Create a VM**:

1. Left sidebar → **Virtual machines** → **Create virtual machine**
2. Fields:
    - **Location**: `mumbai-test` (the label you set in Step 11)
    - **Name**: `test-vm`
    - **Size**: `standard-2` (2 vCPU / 8 GB / 20 GB) or smaller
    - **Boot image**: `ubuntu-noble`
    - **SSH keys**: check `my-laptop`
    - **Public IPv6**: off (not configured in this setup)
    - **Private subnet**: "Create new" is fine
3. Click **Create virtual machine**

You'll be redirected to the VM detail page. Watch the status field —
it goes `start` → `allocate_vm` → `prep` → `clone_ip` → `download` →
`start_after_host_reboot` → `wait_sshable` → `running`. Total time
~3 minutes for the first VM (it has to download + unpack the Ubuntu
image). Subsequent VMs are faster.

---

## Step 14 — SSH into your VM from anywhere

Once the VM is `running`, the detail page shows its **"Public IPv4"**
field. **Important: the value shown in the UI is the VM's
VPC-private IP** (e.g. `10.98.1.128`), not the Elastic IP. This is
a known limitation — see the [FAQ](#faq) below. To SSH in from the
public internet you need to use the matching Elastic IP.

Look up the EIP for the private IP the VM was assigned. Check the
mapping you wrote down in Step 6:

```
10.98.1.128  <->  EIP 52.66.110.229
10.98.1.129  <->  EIP 3.6.57.198
10.98.1.130  <->  EIP 65.0.90.4
```

If your VM got `10.98.1.128`, its public IP is `52.66.110.229`. From
**your laptop**:

```bash
ssh ubi@52.66.110.229
```

**The username is `ubi`**, not `ubuntu` and not `root`. Ubicloud VMs
use the `ubi` unix user by default.

If the SSH hangs: the security group might still be blocking port 22
from your IP. Go to **EC2 → Security Groups → ubi-byoh-sg** and
confirm the SSH rule exists (Step 3).

You're in. You have a real VM on real AWS bare metal. Run
`neofetch`, `htop`, whatever you like. Destroy it from the web UI
when done. VM destroy takes ~20 seconds.

---

## Troubleshooting

### "SSM agent not online" / Connect button is grayed out

- **Most common cause**: IAM role not attached. Go to the instance,
  **Actions → Security → Modify IAM role**, select `ubi-byoh-ssm-role`,
  save. Wait ~60 seconds, refresh the Connect page.
- **Next most common**: VPC can't reach the SSM regional endpoint
  (usually because you put the instance in a private subnet with no
  NAT gateway). Confirm the instance has a public IP *or* that the
  VPC has VPC endpoints for `com.amazonaws.<region>.ssm`,
  `com.amazonaws.<region>.ssmmessages`, and
  `com.amazonaws.<region>.ec2messages`.
- **Rare**: SSM agent crashed. Only happens on older AMIs. Use a
  fresh Ubuntu 24.04 AMI (not Ubuntu 20.04).

### Bootstrap script fails on `ruby 4.0.2` install

- Transient mise/Ruby source tarball fetch. Re-run the same curl
  one-liner — it's idempotent and resumes where it left off.

### Bootstrap script says `bundle install` failed with a native-gem error

- Some apt library is missing. Install the missing lib with
  `sudo apt-get install -y libXXX-dev`, then re-run the script.
- Most common culprits: `libyaml-dev`, `libffi-dev`, `libpq-dev`.

### Puma isn't responding on port 3000

```bash
tmux attach -t ctrl-plane-puma
```

- **Address already in use** — another process is on 3000; kill it
  or change Puma's port in `config/puma.rb`.
- **Sequel database error** — migrations didn't run or DB user is
  wrong. From `~/ubicloud`: `bundle exec rake db:migrate`.
- **"No such file: .env.rb"** — bootstrap was interrupted before
  step 9. Re-run the bootstrap script (it'll resume).

### ctrl→data SSH returns "Permission denied (publickey)"

- Open the data plane Session Manager tab. Run
  `sudo cat /root/.ssh/authorized_keys` and confirm the key you
  appended is there exactly once. Check for extra whitespace or
  missing characters at the line ends (common copy-paste error).
- Run `sudo grep PermitRootLogin /etc/ssh/sshd_config` — should
  show `PermitRootLogin prohibit-password` (not `no`). If it says
  `no`, the user-data script didn't run — check
  `sudo cat /var/log/cloud-init-output.log`.

### `register-byoh-host` says "Address taken" or "duplicate main_ip"

- You probably ran it twice. The first succeeded; the second is
  hitting a uniqueness constraint. Check with:
  ```bash
  cd ~/ubicloud && bundle exec ruby -e '
    require_relative "model"
    HostProvider.each { |hp| puts "#{hp.provider_name} #{hp.server_identifier}" }
  '
  ```
- For a clean retry: delete the rows (`vm_host`, `sshable`,
  `host_provider`, `location` for this host) and re-run. Or use a
  different `--server-identifier`.

### Host strand stuck on `prep_host` for >10 minutes

```bash
ssh -i ~/.ssh/byoh_data root@10.98.1.XX 'tail -50 /var/log/ubi-rhizome/*.log'
```

- Usually `apt-get update` hitting a slow mirror. Wait 10 more
  minutes or re-queue the strand.
- If the data plane has no internet at all: check the VPC's route
  table has a route `0.0.0.0/0 → igw-xxx` for the subnet.

### Host strand stuck on `setup_spdk` for >10 minutes

- SPDK compile can genuinely take 2–4 minutes the first time. >10
  minutes is abnormal. SSH in and check
  `journalctl -u ubi-spdk.service -f`.

### VM creation hangs at `wait_sshable`

- **The VM is booting slowly.** cloud-init can take 90+ seconds the
  first time an image is used. Give it 5 minutes.
- **After 5 minutes**: SSH into the data plane and check that the
  VM process is alive:
  ```bash
  ssh -i ~/.ssh/byoh_data root@10.98.1.XX 'pgrep -a cloud-hypervisor'
  ```

### Web UI loads but login says "Email not verified"

- In dev mode, emails are printed to the Puma log instead of sent.
  Find the verify URL in `tmux attach -t ctrl-plane-puma` (search
  for `/verify/`).

### VM created but can't SSH into it from my laptop

- Double-check that you're using the matching **EIP**, not the
  private IP displayed in the web UI.
- Check that the SG rule for SSH 22 has the right source. If you
  tightened it to `10.98.0.0/16` in Step 3 you won't be able to
  SSH from your laptop — widen it to `0.0.0.0/0` or to your
  laptop's public IP.
- Verify you uploaded the right SSH key in the web UI and that the
  matching private key is loaded on your laptop: `ssh -v ubi@<eip>`
  will show which keys it's trying.

### I destroyed stuff in the wrong AWS account

- If you ran `terraform destroy` (or `aws ec2 terminate-instances`)
  against the wrong account, and the destroy "succeeded" but your
  BYOH infra is still running, check `aws sts get-caller-identity`.
  Terraform refresh against a wrong-account credential silently
  prunes resources from state rather than erroring out, leading to
  a no-op destroy on the intended resources while the real ones
  keep running. Re-auth and re-run.

---

## FAQ

### Q. Why does the web UI show `10.98.1.130` as a VM's "public IP" instead of my actual Elastic IP?

Because Ubicloud stores **"the IP on the wire"** — i.e. the
destination address that actually shows up on the packet when it
arrives at the host. On AWS, the VPC edge does a **DNAT**
(destination network address translation) from `<EIP>` →
`<private IP>` **before** the packet is delivered to the instance's
ENI. From the data plane's point of view, the packet arrived with
destination `10.98.1.130`, and that's what Ubicloud records in the
database. It never learns that the packet was addressed to the EIP
originally.

**Workaround right now**: keep the EIP↔private-IP mapping table
(from Step 6) handy and translate manually. The web UI is
technically telling you the truth about what the host sees.

**Proper fix** (coming in a future release): add an
`assigned_vm_address.external_ipv4` column to the DB schema, let
the `host_provider` config store an `eip_map`, and have the
allocator populate the external IP on assignment. ~150 lines of
Ruby. It's on the roadmap but wasn't in scope for the first BYOH
release.

On **non-AWS** bare metal (OVH, Hetzner, Equinix, a home lab) this
problem doesn't exist: the provider routes the public IP directly
to your box with no DNAT, and the IP you see in the UI *is* the
IP on the internet. AWS is unusual in this regard.

### Q. Do I really need m5d.metal? Can I use a smaller/cheaper instance?

You need a `.metal` instance type (anything with `.metal` suffix).
Non-metal instance types on AWS run under the Nitro hypervisor,
which doesn't give nested KVM the kind of CPU-mode access that
cloud-hypervisor + SPDK need. You'll get errors like "KVM:
VT-x not enabled" or SPDK will fail to pin CPUs.

Cheaper `.metal` alternatives:

| Instance    | vCPU | RAM    | NVMe              | ~$/hr | Notes                   |
|-------------|------|--------|-------------------|-------|-------------------------|
| c5n.metal   | 72   | 192 GB | EBS only          | $3.89 | No instance store       |
| m5.metal    | 96   | 384 GB | EBS only          | $4.61 | Like m5d.metal w/o NVMe |
| **m5d.metal** | 96 | 384 GB | 4 × 838 GB NVMe | $5.42 | Used in this guide      |
| i3.metal    | 72   | 512 GB | 8 × 1.9 TB NVMe   | $4.99 | Old gen but lots of NVMe|
| c7i.metal-24xl | 96 | 192 GB | EBS only       | $4.89 | Newest gen, CPU-heavy   |

Use **`c5n.metal`** if you want the cheapest thing that works —
you'll just have to bump the root disk to 200+ GB since there's no
instance store and the root EBS has to hold everything.

### Q. Can I run this without a `.metal` instance? Like on a t3?

No — a non-`.metal` EC2 instance is itself already a VM, and
cloud-hypervisor can't run nested virtual machines inside it. You'd
need either a `.metal` instance on AWS, a bare-metal box at OVH /
Hetzner / Equinix / Latitude / Cherry, or your own hardware.

### Q. What if I want to run the control plane on my laptop or on a cheap VPS, and only the data plane on AWS?

See "Advanced variants" below. The short version: yes, it's
supported — the ctrl plane can be anywhere, as long as it can open
an **outbound** SSH connection to the data plane's management IP.
The ctrl plane doesn't need any inbound ports from the data plane,
so a ctrl plane behind NAT (your laptop, a home Proxmox VM, a
cheap DigitalOcean droplet) is fine.

### Q. Why do I need 3 Elastic IPs? Can I just use 1?

You can use any number — 1 EIP = 1 VM slot. 3 is the default
because most test scenarios want to create 2 or 3 VMs. Each EIP
costs ~$3.60/mo when unassociated; once associated with an
instance (directly or via a secondary private IP), AWS doesn't
charge for it.

### Q. Why does the user data script run as root, but the bootstrap script says `sudo su - ubuntu`?

User data runs as root on first boot — that's the EC2 behavior,
not a choice. Inside the user data we install OS-level stuff
(apt packages, sshd config, sysctls) that needs root. The
bootstrap script, by contrast, installs Ruby + Node + Ubicloud
into the `ubuntu` user's home directory (so they're not
system-wide, making it easier to debug, uninstall, and re-run).
`sudo su - ubuntu` switches to that user.

### Q. Is Session Manager secure?

Yes — more secure than SSH over the internet. Session Manager
authentication is your AWS IAM identity, session data is
encrypted in transit (HTTPS to the SSM endpoint, then TLS to the
agent), session logs can be sent to CloudTrail/S3 for audit, and
the VPC doesn't need **any** inbound ports open for the ctrl/data
instances themselves. Compare to SSH: you'd need key management,
port 22 exposed to some CIDR, and no audit trail by default.

### Q. How do I know this isn't going to touch my other AWS infra?

Every resource this guide creates is named with the `ubi-byoh-`
prefix. When you destroy things, you destroy only resources with
that prefix. The guide never uses bulk operations, never touches
the default VPC, never deletes anything that isn't named
explicitly. If you're paranoid, also tag everything you create
with `Project=ubicloud-byoh-test` (the console wizard lets you
set tags during creation) and use that tag as a filter for the
cleanup step.

---

## Cleanup — tear it all down

To stop billing, destroy everything in this order (the order
matters because some resources can't be deleted while others
depend on them):

1. **Terminate both EC2 instances** first.
   - **EC2 → Instances** → select `ubi-byoh-ctrl` and `ubi-byoh-data`
   - **Instance state → Terminate instance**
   - Confirm. Wait for state to become `terminated`. **Bare metal
     takes 10–20 minutes** to terminate because AWS physically wipes
     the machine. Be patient — don't assume it's stuck.

2. **Release the 3 Elastic IPs**.
   - **EC2 → Elastic IPs** → select each ubi-byoh EIP
   - **Actions → Release Elastic IP address** → confirm
   - If "Release" is grayed out, the EIP is still associated — wait
     for the instance to finish terminating and the association to
     clear automatically, then release.

3. **Delete the security group**.
   - **VPC → Security Groups** → `ubi-byoh-sg` → **Actions → Delete
     security group**. If it says "dependency violation", the
     instances aren't fully terminated yet — wait and retry.

4. **Delete the VPC** (this cascades and deletes the subnet, IGW,
   route table automatically).
   - **VPC → Your VPCs** → `ubi-byoh-vpc` → **Actions → Delete VPC**
   - AWS will warn you about dependencies — if the security group
     from step 3 is still there, delete that first.

5. **(Optional) Delete the IAM role**.
   - **IAM → Roles** → `ubi-byoh-ssm-role` → **Delete**
   - Only do this if you're not going to rebuild the environment
     soon. You can also leave it for future use.

**Sanity check** — at the end, these should all return empty:

- **EC2 → Instances** filtered by Name `ubi-byoh-*` → empty
- **EC2 → Elastic IPs** filtered by Name `ubi-byoh-*` → empty
- **VPC → Your VPCs** filtered by Name `ubi-byoh-*` → empty

**One thing to double-check: unassociated Elastic IPs.** AWS charges
**$0.005/hour (~$3.60/mo) per unassociated EIP**. Go to **EC2 →
Elastic IPs**, sort by "Associated instance ID", and release
anything with no associated instance (assuming it's not something
you use as a reserved DR address for another workload).

---

## Advanced variants

These are not walkthroughs — they're brief pointers for people who
want to deviate from the default AWS-Console-only path.

### Variant 1 — Use Terraform instead of clicking

If you want to reproduce this infra declaratively, a Terraform
module is available at `terraform/aws-byoh/` in this repo. It
provisions the same VPC + SG + 2 EC2 instances + 3 EIPs as this
guide, plus an SSH key pair (since it assumes you might want to
use SSH directly for CI purposes).

```bash
cd terraform/aws-byoh
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set aws_region, vpc_cidr, etc.
terraform init
terraform apply
```

The Terraform module **does** use an SSH key (not Session
Manager), so it's not directly equivalent to this console guide —
but the resulting EC2 instances have `AmazonSSMManagedInstanceCore`
attached so you can still use Session Manager afterwards.

### Variant 2 — Control plane on a VPS, data plane on real bare metal

This is the "production-like" BYOH topology. You put the Ubicloud
control plane on a cheap $4–$10/month VPS (Hetzner Cloud CX22,
DigitalOcean, Linode, Vultr, OVH VPS, your own machine at home,
whatever), and you put the data plane on actual rented bare metal
at a provider that gives you full hardware access: **OVH** (~€90/mo
for an Advance-1), **Hetzner Dedicated** (~€40/mo for an
AX41-NVMe), **Equinix Metal** (~$0.50/hr), **Latitude.sh**,
**Cherry Servers**, **Leaseweb**, or your own colo box.

Key differences vs. the AWS-only path:

- **No AWS console, no VPC, no Elastic IPs**. You use whatever
  management interface the provider gives you.
- **No source/dest check trickery**. Real bare metal providers
  assign you a routed `/29` or `/28`, which is a pool of real
  publicly-reachable IPs. The data plane gets them directly; no
  NAT, no EIP-remapping, no "IP in the DB vs IP on the internet"
  discrepancy. The web UI will show the actual public IP of
  each VM.
- **The ctrl plane can be anywhere.** It only needs to make
  **outbound** SSH connections to the data plane.

Short walkthrough:

1. Rent a VPS (any provider). Install Ubuntu 24.04. SSH in.
2. Run the ctrl plane bootstrap script on the VPS.
3. Rent bare metal. Install Ubuntu 24.04. SSH in as root.
4. Generate an SSH key on the ctrl plane VPS. Copy the public
   half into the bare metal's `/root/.ssh/authorized_keys`.
5. Run `register-byoh-host` from the ctrl plane VPS, pointing
   `--main-ip` at the bare metal's public IP and
   `--routed-network` at whatever routed range the provider
   gave you.
6. Open the ctrl plane's web UI in your browser.

The BYOH driver itself doesn't care at all whether the data plane
is on AWS, Hetzner, or under your desk.

### Variant 3 — Everything self-hosted on Proxmox / Libvirt / KVM

If you have a home server running Proxmox, you can run **both**
ctrl plane and data plane as guests. Caveats:

- The Proxmox host must support nested virtualization — enable
  with `echo 1 > /sys/module/kvm_intel/parameters/nested` (Intel)
  or `echo 1 > /sys/module/kvm_amd/parameters/nested` (AMD).
- The data plane guest must be configured with **CPU type "host"**,
  not "kvm64", so nested virt flags pass through.
- Even then, SPDK will run but won't have real NVMe access — it'll
  work off file-backed devices. Performance is much slower than
  real hardware; this setup is only for functional testing.
- Your home router needs to route whatever IP range you pick for
  `--routed-network` through to the data plane guest.

Setting this up correctly is more involved than the AWS console
path, which is why we don't recommend it for a first-time setup.

---

## What's next

You now have a working Ubicloud BYOH deployment. Things you can
explore from here:

- **Create more VMs** via the web UI. Each VM you create consumes
  one slot in the routed-network pool, so you can run up to 3
  concurrent VMs with the default config. Allocate more EIPs and
  re-register the host to expand the pool.
- **Register a second host**. Repeat Steps 4–12 for another
  m5d.metal in the same location, or in a different location
  (change `--location`). The Ubicloud allocator will spread VMs
  across multiple hosts automatically.
- **Private networks**. Create a private subnet in the web UI and
  attach multiple VMs to it — Ubicloud's overlay networking (IPsec
  + nftables) gives you an isolated L2-ish network that works
  across hosts.
- **Read the source**. `prog/vm/host_nexus.rb` is the state machine
  that ran during Step 12. `lib/hosting/generic_apis.rb` is the
  BYOH driver itself. `lib/byoh_registration.rb` is what
  `register-byoh-host` calls into.

If you hit anything that isn't covered here, open an issue at
https://github.com/NameawaShinderu/ubicloud-byoh/issues with the
ctrl plane respirate logs (`tmux attach -t ctrl-plane-respirate`)
and as much detail as you can.
