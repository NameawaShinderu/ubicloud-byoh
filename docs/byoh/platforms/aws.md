# BYOH on AWS EC2

AWS is the only platform where BYOH has been run end to end. This page covers:

- a data plane on a nested-virtualization instance (m8i/c8i/r8i) or a `.metal` instance;
- the `terraform/aws-byoh` module, with one workspace and one tfvars file per environment;
- the pool model: ENI secondary private IPs with Elastic IPs (`fabric` + `nat`), and optionally secondary IPs without EIPs (`fabric` + `internal`).

Labels used on this page:
- **Verified**: run on the live ap-south-1 environment, with the date.
- **UNVERIFIED**: never run here.
- **provider docs, UNVERIFIED here**: taken from AWS documentation, not tested in this repo.

The general runbook is [SETUP.md](../SETUP.md). The network design is [NETWORKING.md](../NETWORKING.md) (§9.1 is the AWS runbook). The gate is [VERIFY.md](../VERIFY.md).

---

## 1. Fit

Use AWS when:
- you want a disposable lab or canary that is torn down with one command;
- you already run in AWS and want a few customer VMs with real public IPv4 addresses;
- you want the only shape this project has tested.

Avoid AWS when:
- you need many public IPv4 addresses per host. Each needs its own EIP, and the default EIP quota is small (§2.3).
- you need public IPv6 for VMs. The module's VPC has no IPv6, so hosts use `ula` mode and VMs get no IPv6 (§2.3).

**Network model** (NETWORKING §3.2):

| Pool | `delivery` | `exposure` | What the customer sees |
|---|---|---|---|
| Secondary private IP **with** an EIP (`byoh_secondary_private_ips`) | `fabric` | `nat` | The EIP, shown as Public IPv4 and billed. SSH, Postgres and load balancer DNS use the EIP. |
| Secondary private IP **without** an EIP (`byoh_internal_private_ips`) | `fabric` | `internal` | The private IP, labelled Internal. It is reachable only inside the VPC, has no IPv4 billing, and gets outbound internet through the host NAT. |
| No IPv4 (VM created with `-6`) | — | — | No IPv4. Outbound IPv4 goes through the host NAT, using the host's own public IP. |

`fabric` means the AWS network delivers each address to the ENI it is assigned to. The address must **not** be configured inside the OS (contract C5, §3.3). The AWS edge translates the EIP 1:1 to the private IP and keeps the client's source address, so customer firewall rules work as written.

---

## 2. Requirements

### 2.1 Data plane host

| Requirement | On AWS | Check |
|---|---|---|
| Ubuntu 24.04 x86_64 | The module picks the latest Canonical `ubuntu-noble-24.04-amd64-server` AMI | `lsb_release -rs` |
| KVM | A nested-virtualization type with `cpu_options.nested_virtualization = "enabled"`, or a `.metal` type | `ls -l /dev/kvm`; `grep -cw vmx /proc/cpuinfo` |
| 1G hugepages | The `pdpe1gb` CPU flag (present on m8i) | `grep -cw pdpe1gb /proc/cpuinfo` |
| Memory | Any size. Since a0259a997, LearnMemory accepts every dmidecode unit, so a whole number of GiB is no longer required (unit specs only, UNVERIFIED on a host). m8i sizes are whole GiB anyway. | `sudo dmidecode -t memory \| grep Size:` |
| Disk | EBS gp3 root (`data_root_size_gb`, default 120). VM disks live under `/var/storage` on the root filesystem. | `df -h /var/storage` |
| Outbound internet | Public subnet with an internet gateway, and a public IP on the data plane | `curl -sI https://cloud-images.ubuntu.com`; boot images also need HTTP (80) to cloud-images-archive.ubuntu.com ([PLATFORMS.md](../PLATFORMS.md) PF15) |
| Only the primary IP on the NIC | Handled by the cloud-init fix in `user-data-data.sh` (§3.3) | `ip -br -4 addr` |

**Instance choice:**

| Type | Status | Notes |
|---|---|---|
| **m8i.2xlarge**, nested virtualization | **Verified** (ap-south-1, 2026-10-11 and 2026-10-13) | 8 vCPU / 32 GiB. Gives 4 usable cores and 26 × 1G hugepages, enough for 2-3 `standard-2` VMs. About $0.45/h in ap-south-1 (CLAUDE.md §10a). Register → `accepting` took about 4 minutes. |
| Other m8i/c8i/r8i sizes | UNVERIFIED | AWS docs list C8i, M8i and R8i for nested virtualization. A newer version of the docs lists more families (C7i/M7i/R7i, the `-flex` and `d` variants, X8i, I7i) (provider docs, UNVERIFIED here). Check the [AWS nested virtualization page](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/amazon-ec2-nested-virtualization.html) for your region. |
| **m5d.metal** | Verified earlier (tag `aws-mumbai-working-v1`) | Native VT-x, 96 vCPU. About $5.86/h (ROADMAP.md §8, CLAUDE.md §10a). The 4 instance-store NVMe disks are **not** used (STOR-3). Needs vCPU quota (§2.3). |
| Any type without nested-virtualization support (or with it off), or any AMD/Graviton type, unless it is `.metal` | Will not work for standard VMs | No `/dev/kvm`. `bootstrap-data-plane.sh`, `host add` preflight (PF3) and PrepHost all refuse such a host on the default `kvm` tier. `bin/byoh-virt probe` (and PF3) names the fix for the exact type (switch the option on for c8i/m8i/r8i; move other Nitro types to C8i/M8i/R8i or `.metal`; move Xen types such as t2/m4 to a Nitro type), and the type can still run the experimental `container` or `emulated` tier (both run on a t3.xlarge in e2e1, [VERIFY.md](../VERIFY.md) §7), or the `pvm` tier (next row) ([NO_KVM.md](../NO_KVM.md)). Moving to an m8i of the same size is the better answer: similar per-vCPU price (UNVERIFIED, NO_KVM.md §7) at full KVM speed. |
| m6i/m7i, **xlarge or larger** (2xlarge to run two VMs or to test tenancy), without nested virtualization, with PVM (`--virt-tier pvm --install-pvm-kernel --accept-fallback`) | Experimental. Guest boot verified by hand on m6i.large (L4-T1, 2026-10-16); the product path **passed** on m6i.2xlarge (L4-T2, run pvm1, 2026-10-17, [VERIFY.md](../VERIFY.md) §8) | Real Cloud Hypervisor VMs on a PVM host kernel, without hardware virtualization: CPU 97%, memory about 100%, 4k random I/O 93%, syscalls 48%, fork+exec 32% of the host in L4-T2. An m6i.large (one core) fails `verify_tier_capacity`; an m6i.xlarge fits one `pvm-2`. t3 only if the probe passes: PVM refuses CPUs that Meltdown affects (`pti=off`), so a t3 on a Skylake 8175M is refused and one on a Cascade Lake 8259CL passes (Intel's published Meltdown status; the probe on a t3 is UNVERIFIED), and you cannot choose which you get; t3 CPU credits also apply, so it is not near-native. Secure Boot must be off (the default for Ubuntu AMIs on AWS, UNVERIFIED for every AMI). See §2.1a |

Changing `cpu_options` needs a stopped instance (provider docs, UNVERIFIED here). Choose the type before you register.

### 2.1a PVM on a plain m6i/m7i (experimental)

Use this only when you need VM isolation on an instance type without nested virtualization; an m8i
with nested virtualization is faster and needs no custom kernel ([NO_KVM.md](../NO_KVM.md) §6, §7).
The control plane installs a third-party PVM host kernel on the instance and boots it with `pti=off`.
GRUB's default stays the stock kernel, so a PVM boot that fails returns to stock at the next stop
and start of the instance.

1. Pick m6i/m7i **xlarge or larger** (`m6i.2xlarge` for two `pvm-2` VMs), Ubuntu 24.04, nested
   virtualization off. Keep the EC2 serial console enabled for the account: it is the recovery path
   when even the stock kernel does not come back (TROUBLESHOOTING.md §2.2).
2. On the instance: `sudo scripts/byoh/bootstrap-data-plane.sh --tier pvm` (read-only checks: x86_64,
   no `vmx`/`svm`, Secure Boot off, Meltdown "Not affected", GRUB; it creates the `kvm` group).
3. On the control plane, pin the kernels in the location, then add the host:

   ```bash
   ubicloud-admin site rates <site> --family pvm --from standard --multiplier <X>
   ubicloud-admin site set <site> --virt-tiers kvm,pvm --accept pvm \
     --pvm-host-deb <URL> --pvm-host-deb-sha256 <hex> \
     --pvm-guest-kernel <URL> --pvm-guest-kernel-sha256 <hex> \
     --pvm-guest-config <URL> --pvm-guest-config-sha256 <hex>
   ubicloud-admin site grant <site> --project <ubid>     # keep the site hidden: pvm is single-project
   ubicloud-admin host add --site <site> ... --virt-tier pvm --install-pvm-kernel --accept-fallback
   ```

   The code has no default pin. The cocoonstack/pvm v0.1.0 release that L4-T1 booted is listed in
   [NO_KVM.md](../NO_KVM.md) §6.7 as an example: **third party; Januscape fix inclusion UNVERIFIED;
   for testing only, not a recommended production pin.**
4. `host add` follows the bring-up: `patch`, then the "pvm install" phase (the kernel install, up to
   45 minutes), one reboot into the PVM kernel, `verify_pvm_boot`, then `accepting`. Customers create
   `pvm-2/4/8/16` VMs with boot image `ubuntu-noble` through the API or `ubi`.

The whole flow is scripted as L4-T2, `BYOH_REAL_E2E=1 scripts/byoh/test/real/pvm-e2e.sh all`, against
one throwaway m6i.2xlarge (`scripts/byoh/test/aws-e2e` role `pvme`). It passed in run pvm1 on 2026-10-17
([VERIFY.md](../VERIFY.md) §8): `host add` reached `accepting` in 184 s, a `pvm-2` VM answered SSH 26 s after
create, and lifecycle, host reboots, stock-return, delete, billing and uninstall all passed. The guest-kernel
pin rollout did not run (no second guest build; UNVERIFIED).

### 2.2 Network

- **One VPC per environment.** Defaults: `vpc_cidr = 10.98.0.0/16`, `subnet_cidr = 10.98.1.0/24`, one AZ (`ap-south-1a`).
- **Pool addresses** are secondary private IPs on the data plane's primary ENI. Pick them inside `subnet_cidr`, outside AWS's reserved addresses (the first four and the last one of the subnet; provider docs, UNVERIFIED here) and away from the instances' primary IPs.
- **`--main-ip`** is the data plane's **primary private IP** (output `data_private_ip`). It is never in a pool.
- **Source/destination check** is set to `false` by the module (`main.tf`, `source_dest_check = false`). Strictly, `fabric` does not need it off, because every pool IP is assigned to the ENI (NETWORKING §9.1, C4). Turning it back on has never been tested (UNVERIFIED). Keep the module's value until it has been tested on a canary.
- **IPv6:** none. Hosts are registered in `ula` mode with a /64 from the location's `ula48`. Public IPv6 through an ENI /80 prefix is a P4 spike (PLANNED).

### 2.3 Quotas (provider docs, UNVERIFIED here)

| Quota | AWS default | Why it matters |
|---|---|---|
| Elastic IP addresses per Region | 5 | One EIP per `nat` pool address. The module allocates 3 per workspace. A second workspace with 3 EIPs needs an increase (Service Quotas, `L-0263D0A3`). |
| VPCs per Region | 5 | Each workspace creates its own VPC and internet gateway. The account's default VPC counts too. |
| IPv4 addresses per network interface | Depends on the instance type; for example, c8i.2xlarge allows 30 | This caps pool size per host. The module does not check it. Look it up with `aws ec2 describe-instance-types --instance-types m8i.2xlarge --query 'InstanceTypes[].NetworkInfo.Ipv4AddressesPerInterface'`. |
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances, vCPU (`L-1216C47A`; the module README calls it the bare-metal quota) | 5 vCPU on new accounts | Not bare-metal only: it covers the recommended m8i.2xlarge (8 vCPU) plus the t3 control plane (2 vCPU), which already exceed 5. `m5d.metal` needs 96. |

Every public IPv4 address is billed, whether it is an EIP or an instance's auto-assigned public IP, and whether it is associated or idle (provider docs, UNVERIFIED here). NETWORKING §9.1 gives about $0.005/h per address [EXT]. This repo has no other cost figures.

### 2.4 Control plane reachability

- The control plane runs in the same VPC (`t3.medium` by default; the live environment uses `t3.large`). It reaches the data plane and the VMs' pool addresses directly over the VPC, so `--cp-reach onhost`.
- The data plane security group allows **all traffic from the control plane's security group** (rhizome over SSH, `wait_sshable` to pool IPs).
- A control plane outside the VPC is not covered by this module. It would need `--cp-reach public` and a security group rule for its address. UNVERIFIED.

---

## 3. Step by step

### 3.1 Provision with terraform (operator workstation)

Prerequisites:
- Terraform ≥ 1.5. The AWS provider `~> 6.0` is pinned by the module and is needed for `nested_virtualization`.
- AWS credentials in the environment. Never put them in tfvars.

Use **one workspace and one gitignored `<name>.tfvars` per environment.**
- `.gitignore` covers `*.tfvars` and `.generated/`.
- Workspace `company-mumbai` is the live environment. **Do not apply in it before M7**: its security group has drifted, and its state does not match the live EIPs (VERIFY.md §3).
- Workspace `canary` is reserved for the gate (VERIFY.md §2).

```bash
cd terraform/aws-byoh
terraform init
terraform workspace new mysite            # or: terraform workspace select canary
$EDITOR mysite.tfvars
terraform plan  -var-file=mysite.tfvars
terraform apply -var-file=mysite.tfvars
```

`mysite.tfvars`:

```hcl
aws_region        = "ap-south-1"
availability_zone = "ap-south-1a"
vpc_cidr          = "10.98.0.0/16"
subnet_cidr       = "10.98.1.0/24"

operator_ssh_cidr = "<your public IP>/32"   # required since M4; never 0.0.0.0/0
web_ui_cidr       = "<your public IP>/32"   # required since M4; ports 3000 and 443 on the control plane

# The variables.tf defaults (m5d.metal, nested off) are stale.
data_plane_instance_type         = "m8i.2xlarge"
data_plane_nested_virtualization = true
data_root_size_gb                = 120

# Each gets an EIP and becomes a fabric + nat pool address.
byoh_secondary_private_ips = ["10.98.1.128", "10.98.1.129", "10.98.1.130"]
# Optional: no EIP, fabric + internal (VPC only, egress via the host NAT).
byoh_internal_private_ips  = ["10.98.1.140"]

# Location name printed by byoh_location_create_command (default byoh-aws-<workspace>).
byoh_location_name = "byoh-aws-mysite"

# Leave false until host_guard exists (section 3.10).
data_plane_open_ingress = false
```

The module creates:
- the VPC, subnet, internet gateway and route table;
- two security groups (§3.10);
- an Ed25519 key pair `ubi-byoh-test-key-<workspace>`;
- the control plane and data plane instances, with the secondary IPs on the data plane's primary ENI;
- one EIP per `byoh_secondary_private_ips` entry, each associated 1:1 with its private IP;
- `.generated/<workspace>/pools.yaml` and `.generated/<workspace>/byoh_ssh_key{,.pub}`.

`terraform output` prints `handoff_instructions`, `byoh_location_create_command` (§3.5), `host_add_command` (§3.7), `data_private_ip`, `data_eni_id`, `byoh_eip_to_private_ip` and `pools_yaml_path`.

`operator_ssh_cidr` and `web_ui_cidr` have no default since M4: a tfvars file that leaves either out stops `plan` with "No value for required variable".

The private key is also stored in `terraform.tfstate`. Treat the state file as a secret (CLAUDE.md §9).

`user_data` has `ignore_changes`, so editing the first-boot scripts later never replaces a registered host. Other changes still can:

- **AMI drift.** `data.aws_ami.ubuntu_2404` uses `most_recent = true`, and `ami` is not in `ignore_changes`. Once Canonical publishes a newer noble AMI, any later `plan` shows both instances as **must be replaced**, even if you changed nothing. This is the most likely trigger. Known gap until the module adds `ami` to `ignore_changes` or pins the AMI ID: never apply such a plan to a registered host.
- An `~ update in-place` on `instance_type` or `cpu_options` stops and starts the instance. `plan` does not say "stop/start", so treat every in-place change to `aws_instance.data` as a host restart that drops every VM's memory.

**Read every `plan` for `must be replaced` and for in-place changes to `aws_instance.data` before applying to a registered host.**

### 3.2 Data plane bootstrap

On AWS, `terraform/aws-byoh/user-data-data.sh` replaces `scripts/byoh/bootstrap-data-plane.sh`. On first boot it:

1. installs `openssh-server` and `ruby-bundler`;
2. copies the key pair's public key into `/root/.ssh/authorized_keys` and sets `PermitRootLogin prohibit-password`. The control plane then logs in as root with `.generated/<workspace>/byoh_ssh_key`, and no manual key step is needed.
3. applies the cloud-init secondary-IP fix (§3.3);
4. sets forwarding and `proxy_arp` sysctls;
5. touches `/var/log/user-data.done`.

User-data does **not** run the virtualization check from `bootstrap-data-plane.sh`. Check it by hand before registering:

```bash
ssh -i .generated/<ws>/byoh_ssh_key ubuntu@<data_public_ip>
test -f /var/log/user-data.done && echo user-data ok
ls -l /dev/kvm && grep -cw vmx /proc/cpuinfo && grep -cw pdpe1gb /proc/cpuinfo
ip -br -4 addr          # only the primary IP (e.g. ens5 10.98.1.x/24) and lo
```

The control plane can do the KVM part for you, with more detail (the KVM capabilities
cloud-hypervisor needs, the instance type's rule and the fix): `host add` preflight (PF3) does it, or
`bin/byoh-virt probe --main-ip <data_private_ip> --ssh-key <key>` (packaged: `sudo ubicloud-admin run byoh-virt probe ...`).
The probe needs `ruby` on the host, which `bootstrap-data-plane.sh` installs (user-data installs `ruby-bundler`).
PF3 ran on AWS in e2e1 (m8i nested, t3.xlarge and t3.large; [VERIFY.md](../VERIFY.md) §7).

Running `bootstrap-data-plane.sh` on top of user-data is harmless. Its marker steps are idempotent, and it also does the KVM check. The script is self-contained: copy it to the host (scp) or clone the repo.

### 3.3 The cloud-init secondary-IP fix (contract C5)

The EC2 datasource of cloud-init writes **every** ENI secondary IP into `/etc/netplan/50-cloud-init.yaml`. The host then owns the pool addresses. Traffic for a VM's address is answered by the host itself: `wait_sshable` passes against the host's sshd, and customers get `Permission denied (publickey)`. This was seen live in 2026-10. `user-data-data.sh` prevents it:

- `/etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg` sets `datasource.Ec2.apply_full_imds_network_config: false`, which holds for every later boot;
- it strips `addresses:` from `50-cloud-init.yaml`;
- it sets `promote_secondaries=1` and runs `ip addr del` for every non-primary address on the first boot.

**Verified:** after deploy and after a host reboot, `ip -br -4 addr` shows only the primary IP (2026-10-11).

Second line of defence, since a092f1b8b: if a pool address is ever local on the host again, VM setup on a BYOH host fails with `<ip> is a local address of this host, so the host answers for the VM. ...` instead of passing falsely. This is covered by unit specs only, UNVERIFIED on a real host.

`scripts/byoh/providers/aws-routed-network-setup.sh` (the non-terraform path) does **not** apply this fix. It is broken and retired (PLATFORMS.md, finding 15). Do not use it.

### 3.4 Control plane

Follow [SETUP.md §4](../SETUP.md). The commands below use the development bootstrap, which the live environment runs. For the packaged layout, run `scripts/byoh/install.sh` instead ([INSTALL.md](../INSTALL.md)): `--tls tunnel` with a Cloudflare tunnel, or `--tls acme`. ACME needs port 80 open to `0.0.0.0/0`, because Let's Encrypt validates from addresses it does not publish, and 443 open to everyone who should reach the UI. `web_ui_cidr` (meant to be your /32) limits 3000 and 443 and opens no port 80, so widen 443 and add a port 80 rule outside `web_ui_cidr` (UNVERIFIED). On AWS:

```bash
scp -i .generated/<ws>/byoh_ssh_key .generated/<ws>/pools.yaml .generated/<ws>/byoh_ssh_key ubuntu@<ctrl_public_ip>:
ssh -i .generated/<ws>/byoh_ssh_key ubuntu@<ctrl_public_ip>
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
export UBI_BASE_URL=http://<ctrl_public_ip>:3000     # before the bootstrap: it writes BASE_URL only into a new .env.rb
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
export PATH=$HOME/.local/bin:$HOME/.local/share/mise/installs/ruby/4.0.7/bin:$PATH
cd ~/ubicloud
```

- `~/.local/bin` (mise) must be on PATH for any later `bundle install` (verified live, 2026-10-13).
- Leave `bin/monitor` off (`UBI_START_MONITOR` unset). EBS volumes have no SMART data and only `nvme-Amazon_Elastic_Block_Store_*` by-id links, so upstream health checks misjudge the host (PLATFORMS.md F5).
- `BASE_URL` defaults to the first address of `hostname -I`, which is the **private** IP. The `UBI_BASE_URL` line above fixes that when you open the UI from outside the VPC. The bootstrap writes `BASE_URL` only when it creates `.env.rb` (`||=`); on an existing `.env.rb`, edit the line by hand.
- Which branch carries the code this page describes: [README.md](README.md) "Which branch".

### 3.5 Create the location

Print the command for this VPC:

```bash
terraform output -raw byoh_location_create_command     # on the workstation
```

It expands to:

```bash
sudo ubicloud-admin site add byoh-aws-mysite \
  --display "AWS ap-south-1 (BYOH)" \
  --underlay 10.98.0.0/16 \
  --overlay 172.20.0.0/14 \
  --cp-reach onhost \
  --cp-source <ctrl private IP>/32 \
  --mgmt-allow <ctrl private IP>/32,<operator_ssh_cidr> \
  --ula-underlay none \
  --rates-from hetzner-fsn1
```

- **Packaged control plane** (`install.sh`): `site add` writes the rates to `/var/lib/ubicloud/billing_rates.d`, the `BILLING_RATES_EXTRA_DIR` of `/etc/ubicloud/env`, and restarts `ubicloud.target`, so web, respirate and monitor load them.
- **Development control plane** (`bootstrap-dev-ctrl-plane.sh`): there is no `ubicloud-admin` on PATH. From `~/ubicloud`, run `packaging/bin/ubicloud-admin --dev site add ...` without `sudo`, or `bundle exec bin/byoh-location add ...` with the same options. The rates go to the `BILLING_RATES_EXTRA_DIR` of `.env.rb` (`$HOME/ubicloud-billing-rates.d`); restart `puma` and `respirate` yourself (below). `bin/byoh-location show` prints the `Rate file` it uses. Before M4 the output printed `/etc/ubicloud/billing_rates.d` and an `export` of it, which the services never read; the live environment uses `/home/ubuntu/ubicloud-billing-rates.d`.
- With `operator_ssh_cidr = 0.0.0.0/0`, the output warns and leaves the operator out of `--mgmt-allow`. VMs behind the host NAT are denied every `mgmt_allow` network, so a world-open CIDR there would cut VMs off from the internet.
- `--ula48` is random by default. Pass one only to fit an existing host's `net6`, as the live window did (`--ula48 fd1b:3821:6123::/48`).

Then restart the services so they load the rates, check the location, and grant your project once the account exists (§3.8).

Packaged control plane (`site add` already restarted the services):

```bash
sudo ubicloud-admin site show byoh-aws-mysite
sudo ubicloud-admin site grant byoh-aws-mysite --project pj...
```

Development control plane, from `~/ubicloud`, without `sudo`:

```bash
tmux kill-session -t puma; tmux kill-session -t respirate
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
packaging/bin/ubicloud-admin --dev site show byoh-aws-mysite        # or: bundle exec bin/byoh-location show ...
packaging/bin/ubicloud-admin --dev site grant byoh-aws-mysite --project pj...
```

`create` and `show` print preflight warnings. On a default control plane, expect:

- "CONTROL_PLANE_OUTBOUND_CIDRS includes 0.0.0.0/0, ::/0, so Postgres and Kubernetes firewalls allow SSH from anywhere". This is a security setting, not information: `config.rb` defaults the variable to `0.0.0.0/0,::/0`. Add `ENV["CONTROL_PLANE_OUTBOUND_CIDRS"] ||= "<ctrl private IP>/32"` to `.env.rb` and restart the services. (If you set it and leave a `--cp-source` CIDR out, the warning becomes "cp_source_cidrs ... is not in CONTROL_PLANE_OUTBOUND_CIDRS".)
- "BASE_URL is ...; set it to the URL customers use" only when `BASE_URL` is unset or a localhost address. A private 10.98.x `BASE_URL` does not warn, so check it yourself (§3.4).

### 3.6 pools.yaml

Terraform writes this file. The equivalent YAML (EIPs are placeholders; documentation ranges such as 203.0.113.0/24 are refused) is:

```yaml
version: 2
ipv6_mode: ula
routed_networks:
  - cidr: 10.98.1.128/32
    delivery: fabric
    exposure: nat
    external:
      10.98.1.128: <EIP 1>
  - cidr: 10.98.1.129/32
    delivery: fabric
    exposure: nat
    external:
      10.98.1.129: <EIP 2>
  - cidr: 10.98.1.130/32
    delivery: fabric
    exposure: nat
    external:
      10.98.1.130: <EIP 3>
  - cidr: 10.98.1.140/32          # only with byoh_internal_private_ips
    delivery: fabric
    exposure: internal
```

`uplink: ens5` may be added. It is informational and never used.

**Building the file from AWS instead of terraform.** Use this for the live host, for EIPs associated by hand, or after drift. `bin/byoh-pool export --external-map` reads the raw JSON of `aws ec2 describe-addresses`. It maps each `PrivateIpAddress` to its `PublicIp`, and skips EIPs that are not associated. The host must already be registered:

```bash
# workstation: limit to the data plane ENI, so an identical 10.98.1.x in another workspace's VPC cannot collide.
# The live host (workspace company-mumbai): never run terraform there (VERIFY.md §3); take the ENI ID from AWS:
#   aws ec2 describe-instances --instance-ids <data instance id> --query 'Reservations[].Instances[].NetworkInterfaces[0].NetworkInterfaceId' --output text
# Any other workspace: $(terraform output -raw data_eni_id)
aws ec2 describe-addresses --filters Name=network-interface-id,Values=<data ENI ID> --output json > eips.json
scp -i .generated/<ws>/byoh_ssh_key eips.json ubuntu@<ctrl_public_ip>:
# control plane
bundle exec bin/byoh-pool export --host vh... --set delivery=fabric,exposure=nat --external-map eips.json > live-pools.yaml
$EDITOR live-pools.yaml       # review the notes printed by export
bundle exec bin/byoh-pool annotate --host vh... --pool-file live-pools.yaml
```

- Under `nat`, an address without an EIP turns a /32 into `exposure: internal`, or becomes `reserve` inside a block. `export` prints a note for each.
- The live window built its file from an unfiltered `describe-addresses`, which is safe only when one VPC uses those private IPs.
- **Verified** live: `annotate` followed by `verify` reported 0 failures (2026-10-13).
- The `network-interface-id` filter is from the AWS CLI docs (UNVERIFIED here).

### 3.7 Register

**With `host add` (M4).** `terraform output -raw host_add_command` prints the commands for this workspace:

1. On the workstation, the `--expect-host-key` flags parsed from the SSH host key fingerprints that cloud-init prints to the data plane's console (`aws ec2 get-console-output --latest`). Terraform cannot know the keys, which the instance makes at first boot. The parse is UNVERIFIED on current AMIs; if it prints nothing, leave `EXPECT` empty and compare the fingerprints `host add` shows by hand.
2. On the workstation, `scp` of `pools.yaml` and the EC2 key to the control plane.
3. On the control plane:

   ```bash
   EXPECT='--expect-host-key SHA256:... --expect-host-key SHA256:...'    # from step 1
   sudo ubicloud-admin host add --site byoh-aws-mysite --ssh ubuntu@<data_private_ip> \
     --ssh-key ~/byoh_ssh_key --pool-file ~/pools.yaml $EXPECT --no-wait \
     && shred -u ~/byoh_ssh_key \
     && sudo ubicloud-admin host watch <data_private_ip>
   ```

   The three steps are chained. If `host add` fails (a failing preflight, an SSH or host key error, or `EXPECT` left as printed), the key stays on the control plane for a retry, and the watch does not run.

`host add` runs preflight with the pools (PLATFORMS.md §6), installs its own root key, registers the host pinned to the host keys, and `host watch` follows the bring-up to `accepting` and runs `pool verify`. `host add` deletes its staged copy of the EC2 key after the prepare phase, and `--no-wait` lets you shred yours before the watch. The EC2 key is not only the `ubuntu` login, though: `user-data-data.sh` also copies it into root's `authorized_keys` for the `register-byoh-host` path below, and `host add` keeps every root key but its own. The output's optional step 4, run from the workstation after `host add` succeeds, removes the EC2 key from root's logins and leaves it as the `ubuntu` login. It rewrites the file only when `host add`'s key (tagged `ubicloud-byoh`) would remain. On a development control plane, use `packaging/bin/ubicloud-admin --dev` from `~/ubicloud` without `sudo`. None of this has run on AWS yet (UNVERIFIED; the M4 canary in VERIFY.md).

**With `register-byoh-host`** (as validated in 2026-10; the user-data copies the EC2 key into root's `authorized_keys`). On the control plane, from `~/ubicloud`:

```bash
bundle exec bin/register-byoh-host \
  --location byoh-aws-mysite \
  --main-ip <data_private_ip> \
  --pool-file ~/pools.yaml \
  --ssh-key ~/byoh_ssh_key \
  --default-boot-image ubuntu-noble \
  --yes
```

- `--main-ip` is the **private** primary IP, not `data_public_ip`.
- `ubuntu-noble` is the default image for VMs that name none. Add `--default-boot-image ubuntu-jammy` only if customers will pick jammy explicitly.
- There is no `--provider` flag.
- The host reboots once. Watch the labels with `tail -f /tmp/respirate.log`, and the state with `psql -U clover -d clover_test -c "SELECT allocation_state FROM vm_host"` or `bundle exec bin/byoh-pool verify --host vh...`, until `allocation_state = accepting`. That took about 4 minutes on m8i.2xlarge (verified 2026-10-11).

Then check:

```bash
bundle exec bin/byoh-pool verify --host vh...                                       # no FAIL lines
bundle exec bin/byoh-pool list --host vh...                                         # nat rows show their EIPs
ssh -i ~/byoh_ssh_key root@<data_private_ip> ip -br -4 addr                         # only the primary
ssh -i ~/byoh_ssh_key root@<data_private_ip> nft list table inet byoh_egress        # loaded
```

### 3.8 Create VMs

1. Open `http://<ctrl_public_ip>:3000/create-account` from an address inside `web_ui_cidr`. The verification email is in `/tmp/puma.log`.
2. `bin/byoh-location grant` your project (§3.5), and add an SSH key.
3. Create a VM in **AWS ap-south-1 (BYOH)** (the `--ui-name`):
   - IPv4 Exposure `internet` takes a `nat` address, so the Public IPv4 is the EIP.
   - `internal` takes an `internal` address. It exists only with `byoh_internal_private_ips`.
   - IPv4 off gives a VM with no IPv4 and egress through the host NAT.

   CLI equivalents (`ubi` against a BYOH control plane is UNVERIFIED; see SETUP.md §9 for `UBI_URL`/`UBI_TOKEN`):

   ```bash
   ubi vm byoh-aws-mysite/vm1 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"
   ubi vm byoh-aws-mysite/vm2 create -e internal -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"
   ubi vm byoh-aws-mysite/vm3 create -6 -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"
   ```

4. SSH to a `nat` VM with `ssh ubi@<EIP>`. **With the default security group (§3.10), this works only from `operator_ssh_cidr`, and only on port 22.**

### 3.9 Gate (VERIFY.md profile for AWS)

Run `scripts/byoh/verify/m2-gate.sh` on the control plane with these AWS settings. The full gate needs exactly 3 `byoh_secondary_private_ips` and 1 `byoh_internal_private_ips` (VERIFY.md G0): G8 needs `GATE_VM_C`, a VM with `ip4_exposure internal`, which only an `internal` pool can place.

```bash
export GATE_LOCATION=byoh-aws-mysite GATE_HOST=vh... GATE_MAIN_IP=<data_private_ip>
export GATE_HOST_KEY=~/byoh_ssh_key GATE_VM_KEY=~/.ssh/id_ed25519
export GATE_IPV6_MODE=ula GATE_EXPECT_MONITOR=0 GATE_VM_A_EXPOSURE=nat
export GATE_VM_A=vm... GATE_VM_B=vm... GATE_VM_C=vm... GATE_VM_D=vm...
export GATE_CTRL_PRIV=<ctrl private IP> GATE_UNDERLAY_PROBE=<another VPC host with SSH open> GATE_SMTP_PROBE=<internet host on TCP 25>
scripts/byoh/verify/m2-gate.sh g1 g2 g3 g4 g5        # setup and registration
scripts/byoh/verify/m2-gate.sh all                   # after VM-A..D exist
export GATE_NEW_EXTERNAL=<new EIP>                   # g11 exits 2 without it
scripts/byoh/verify/m2-gate.sh g11                   # after associating the new EIP and running byoh-pool remap
```

AWS-only gate steps:
- G0: terraform apply in `canary`.
- G11: `aws ec2 associate-address` for a new EIP, then `bin/byoh-pool remap --host H --ip <pool IP> --external <new EIP>`.
- G17: `terraform destroy`, then check that `aws ec2 describe-addresses` lists none of the canary EIPs.

---

### 3.10 Security groups, IMDS and src/dst check

**Security groups.** The module creates two:

| Group | Ingress | Notes |
|---|---|---|
| `ubi-byoh-test-sg-<ws>` (control plane; no suffix in `company-mumbai`) | 22 from `operator_ssh_cidr`; 3000 and 443 from `web_ui_cidr`; all traffic from itself | Egress open |
| `ubi-byoh-test-data-sg-<ws>` (data plane; no suffix in `company-mumbai`) | 22 from `operator_ssh_cidr`; all traffic from the control plane group; **with `data_plane_open_ingress = true` only**, all traffic from `0.0.0.0/0` | Egress open |

Security groups apply per ENI. The host's own sshd and the VMs' EIPs therefore sit behind the same rules.

- **Default (`false`).** Customers cannot reach their VMs' EIPs. Only the operator's /32 can reach port 22, and only the control plane can reach anything else.
- **Open (`true`).** Ubicloud's per-VM firewall becomes the only filter, as on a provider network. But the host has no input firewall until `host_guard` (NETWORKING §6.2, PLANNED P2), so the host's key-only sshd faces the internet.

NETWORKING §6.3 sets the rule: open ingress only after `host_guard`. Until then, an AWS site is a lab, not a customer-facing site. The optional split-ENI hardening (separate SG for the pool ENI) is UNVERIFIED.

**IMDS.** On every BYOH host, the host's egress table drops VM connections to `169.254.0.0/16`, `168.63.129.16`, `fd00:ec2::254` and `fd20:ce::254`.
- **Verified** for IPv4 on 2026-10-13 (G9: metadata timed out, link-local counter 0 → 5).
- The `fd00:ec2::254` drop was added in 9d85a6e3c and is covered by unit specs only.

The module does not yet set `metadata_options { http_tokens = "required", http_put_response_hop_limit = 1 }` on the data plane (PLANNED P2). You can set it yourself:

```bash
aws ec2 modify-instance-metadata-options --instance-id $(terraform output -raw data_instance_id) \
  --http-tokens required --http-put-response-hop-limit 1
```

`user-data-data.sh` already uses IMDSv2 tokens. The effect on cloud-init and on the running host is UNVERIFIED here, so try it on a canary first.

**src/dst check:** see §2.2. Keep `false` until it has been tested with the check on.

---

## 4. Problems and solutions

Common, platform-neutral problems are in [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) and [NETWORKING.md §11](../NETWORKING.md). These are specific to AWS:

| Symptom | Cause | Fix |
|---|---|---|
| `bootstrap-data-plane.sh`: `/dev/kvm is missing`; or PrepHost fails with `/dev/kvm is not a character device` | Instance type without nested virtualization, or `data_plane_nested_virtualization` left `false` (the default) | Use m8i/c8i/r8i with `data_plane_nested_virtualization = true` (AWS provider ≥ 6), or a `.metal` type. Changing `cpu_options` needs a stopped instance; do it before registering. `bin/byoh-virt probe` or `host add` preflight (PF3) prints the rule for the exact type; without KVM, the `container`, `pvm` or `emulated` tier (§2.1a, [NO_KVM.md](../NO_KVM.md)); §4 and §7 there for the fix and the cost. |
| `bin/byoh-virt probe`: `tier: none`, `platform: aws_xen` | A Xen-based type (t2, m4 and older) | Move to a Nitro type: C8i/M8i/R8i with nested virtualization, or `.metal`. The DMI strings that identify Xen types are UNVERIFIED |
| Customers get `Permission denied (publickey)` on a VM; `wait_sshable` passed anyway | ENI secondary IPs configured on the host NIC by cloud-init: the host answers instead of the VM (C5) | `ip -br -4 addr` on the host. Check `/etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg` exists, strip `addresses:` from `/etc/netplan/50-cloud-init.yaml`, `ip addr del <ip>/<len> dev ens5`. Never use `aws-routed-network-setup.sh`. |
| VM create fails: `<ip> is a local address of this host, so the host answers for the VM` | Same cause, caught by the a092f1b8b check | As above, then recreate the VM |
| `ssh ubi@<EIP>` times out, while egress from the VM works | Data plane SG: `data_plane_open_ingress = false` and the client is outside `operator_ssh_cidr`, or the port is not 22 | Test from `operator_ssh_cidr`. Open ingress only after `host_guard` (§3.10). `bin/byoh-pool trace <EIP>` shows which VM owns the address. |
| `ssh ubi@<EIP>` from the control plane itself times out | Traffic to an EIP leaves through the internet gateway and returns with the control plane's **public** IP as source, which the SG reference does not match. EIP hairpin from inside the VPC is UNVERIFIED (NETWORKING §13). | Reach the VM at its pool IP (`cp_reach: onhost`), through the netns ProxyCommand (VERIFY.md §1.4), or from the operator's /32 |
| `terraform apply` fails with `AddressLimitExceeded` | EIP quota (default 5 per Region; provider docs, UNVERIFIED here) | Fewer `byoh_secondary_private_ips`, use `byoh_internal_private_ips`, or request a quota increase |
| `terraform apply` in a new workspace fails with `VpcLimitExceeded` | Each workspace creates a VPC; the default is 5 per Region including the default VPC | Destroy an unused workspace, or request an increase |
| Assigning secondary IPs fails, or more IPs than expected are refused | Per-ENI IPv4 limit of the instance type; the module does not check it | `aws ec2 describe-instance-types --instance-types <type> --query 'InstanceTypes[].NetworkInfo.Ipv4AddressesPerInterface'` |
| `export --external-map` turns a /32 into `exposure: internal`, or prints `reserve` notes | That private IP has no associated EIP in `eips.json`: it is not associated, or the JSON came from another region/account | `aws ec2 associate-address --allocation-id <eipalloc> --network-interface-id <eni> --private-ip-address <ip>`, export again, review, `annotate` |
| UI, API or load balancer DNS still show the old EIP after re-associating one in AWS | The database is not updated by AWS changes | `bin/byoh-pool remap --host H --ip <pool IP> --external <new EIP>` (gate G11) |
| Wrong EIP shown for a pool IP after `annotate` | `describe-addresses` was unfiltered and another VPC (another workspace) uses the same private IP | Filter by `network-interface-id` (§3.6), export again, `annotate` |
| VM waits for capacity ("no space left") | All `nat` addresses are taken (gate G10 expects this); `-e internal` with no `byoh_internal_private_ips`; or no boot image | Add a secondary IP with an EIP (terraform), then `bin/byoh-pool add --host H --pool <ip>/32,delivery=fabric,exposure=nat,external=<ip>:<EIP>`; check `byoh-pool list` |
| Every VM create fails with "No capacity left" on a host registered before M1 | vhost-block-backend v0.2.2; new VMs need `version_code >= 401` (verified live, 2026-10-13) | In `bin/pry`: `VmHost.all.each { Prog::Storage::SetupVhostBlockBackend.assemble(it.id, Config.vhost_block_backend_version, allocation_weight: 100) }` |
| Host goes `unavailable`, or health pages about SMART/clocksource | `bin/monitor` running against EBS (PLATFORMS.md F5) | Stop `bin/monitor` (`tmux kill-session -t monitor` if the bootstrap started it), then in `bin/pry`: `VmHost["vh..."].update(allocation_state: "accepting")` |
| VM create fails resolving a billing rate; `show` reports missing coverage | `BILLING_RATES_EXTRA_DIR` differs between the shell that ran `create` (the pre-M4 terraform output exported `/etc/ubicloud/billing_rates.d`) and `.env.rb` | Use the `.env.rb` directory, rerun `bin/byoh-location rates --location <name> --rates-from hetzner-fsn1`, restart the services |
| VMs cannot reach the control plane or other VPC hosts | By design: `--underlay`, `--cp-source` and `--mgmt-allow` are in `deny4` (G9b) | Expected. `--egress-allow` is stored but nothing reads it yet (PLANNED). The only lever is to leave a range out of `--underlay`, `--cp-source` and `--mgmt-allow`. |
| Outbound SMTP (port 25) from VMs fails | `egress_smtp` defaults to false (G9b) | `bin/byoh-location set --location <name> --egress-smtp` if you accept the abuse risk |
| `bundle install` fails: `No such file or directory - mise` | `~/.local/bin` not on PATH (verified live, 2026-10-13) | `export PATH=$HOME/.local/bin:$PATH` |
| Verification email link points at a private IP or `localhost:9292` | `BASE_URL` is the private IP from `hostname -I`, or an old `.env.rb` | Set `BASE_URL` in `.env.rb` to the URL you browse to, then restart `puma` |
| `terraform plan` shows `aws_instance.data` (and the control plane) must be replaced, although you changed nothing | AMI drift: `most_recent = true` picked a newer Canonical noble AMI, and `ami` is not in `ignore_changes` (§3.1). User-data edits are ignored. | Do not apply on a registered host: a replacement wipes it. Known gap: add `ami` to `ignore_changes` or pin the AMI ID in the module. An `~ update in-place` on `instance_type` or `cpu_options` is a stop/start, which drops every VM's hugepage-backed memory: drain first, or build a new host. |
| Admin "Hardware Reset" leaves the host strand stuck | No BMC on EC2 | Use the admin reboot (G14). For console access use the EC2 serial console or SSM, if you have set them up (the module sets up neither). |

---

## 5. Teardown

Before destroying, delete the VMs, then the host, in Ubicloud, or the control plane keeps a host that no longer exists. Delete the VMs in the UI (or `ubi vm <loc>/<name> destroy`), then in `bin/pry` run `VmHost["vh..."].incr_destroy`, which waits until the host has no VMs. If the control plane is in the same workspace, it is destroyed too.

```bash
terraform -chdir=terraform/aws-byoh workspace select mysite
terraform -chdir=terraform/aws-byoh destroy -var-file=mysite.tfvars
aws ec2 describe-addresses --region <aws_region from mysite.tfvars> \
  --filters Name=tag:Project,Values=ubicloud-byoh-test --output table     # no leftover EIPs from this module
```

- Idle EIPs are billed, so check for leftovers. Earlier ad-hoc environments (10.99.x) may have left orphaned EIPs and instances (CLAUDE.md §9, UNVERIFIED).
- `.generated/<workspace>/` and `terraform.tfstate*` hold private keys. Delete them or keep them as secrets.

---

## 6. Status

**Tested.** AWS EC2 in ap-south-1 is the only platform verified end to end:
- **2026-10-16, run e2e1** ([VERIFY.md](../VERIFY.md) §7): `install.sh` in production mode with `--tls acme`, account, reboot, release switch, backup and restore; `site add` and `host add` on m8i.2xlarge nested to `accepting` (G-M4-1) and the M2 gate G1-G5, G7-G9b, G12-G14; PF3 on t3; the `container` and `emulated` tiers on t3.xlarge; the PVM go/no-go on m6i.large.
- **2026-10-17, run pvm1** ([VERIFY.md](../VERIFY.md) §8): the `pvm` tier end to end on m6i.2xlarge, and `bin/ubi` against the API host `api.<host>`.
- **2026-10-11, m8i.2xlarge, nested virtualization:** register → `accepting` in about 4 minutes, VM create and destroy, host reboot recovery, EIP ingress, egress, DNS, apt and web login (CLAUDE.md §10a).
- **2026-10-13, live M1 + M2 window, code 17d383a9c:** gate G5-G9b passed (VERIFY.md §5):
  - EIP shown in API and billing, and SSH via the EIP works;
  - a VM without IPv4 has DNS, apt and `curl -4` egress through the host IP;
  - metadata is blocked;
  - control plane, underlay and SMTP are blocked from VMs.
- **Earlier:** m5d.metal (tag `aws-mumbai-working-v1`).

**Not yet run:**
- the canary gate G0-G17 in the `canary` workspace;
- the failures that the code-gap commits after 29fe8c799 catch were never provoked on a host: the local-address check (a092f1b8b), the `fd00:ec2::254` drop (9d85a6e3c) and the virtualization check in `bootstrap-data-plane.sh` (105b6439b). The code ran in e2e1; these paths are covered by unit specs only;
- G6, G10 and G11, the F5 monitor soak (G-M4-3), and the PVM guest-kernel pin rollout.

**Known gaps:**
- No `host_guard`, so `data_plane_open_ingress` must stay `false`. VMs are reachable from outside only by the operator /32, on port 22.
- `metadata_options` is not set by the module.
- src/dst check off, never tested on.
- No public IPv6; the ENI /80 prefix is a P4 spike.
- Per-ENI IP limit not validated by terraform.
- EIP hairpin from inside the VPC UNVERIFIED.
- `bin/monitor` unusable on EBS (F5).
- Instance-store NVMe ignored (STOR-3).
- Single AZ, single control plane. A development control plane restarts nothing after a reboot; a packaged one does (e2e1).
- `variables.tf` defaults (m5d.metal, nested off) are stale; set the type and `data_plane_nested_virtualization` yourself. The `terraform.tfvars.example` comment that `.metal` is required is stale too.
- `aws-routed-network-setup.sh` is broken and retired.
- Not run on AWS (UNVERIFIED): the probe on m8i with nested off and on a Xen type (NO_KVM.md §14, L2-T2, L2-T9); PF3 on m6i ran only as part of the PVM `host add`. e2e1 and pvm1 ran L1-T2, L3-T1, L4-T1, L4-T2 and L5 (NO_KVM.md §14).
- Changes to EIPs in AWS are not synced automatically; `bin/byoh-pool sync-aws` is PLANNED P7.
