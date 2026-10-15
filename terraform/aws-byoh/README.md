# terraform/aws-byoh — AWS BYOH test infrastructure

Declarative Terraform module that provisions a complete Ubicloud
**BYOH (generic provider) test environment** on AWS in a single region:

- Dedicated VPC + subnet + IGW + route table (isolated from your other infra)
- Security group with SSH + web UI + intra-SG allow rules
- Generated Ed25519 keypair (saved locally to `.generated/`, gitignored)
- Control plane instance (`t3.medium`, Ubuntu 24.04)
- Data plane instance (`m5d.metal` bare metal, Ubuntu 24.04) with:
    - `source_dest_check = false` — kernel can forward packets to VMs
    - 3 secondary private IPs on the ENI — the BYOH routable IP pool
    - Pre-installed `ruby-bundler` and root SSH pubkey login via user-data
    - optional `byoh_internal_private_ips`: more secondary private IPs with no EIP
- 3 Elastic IPs, each 1:1 associated with a secondary private IP
- `.generated/<workspace>/pools.yaml`, the pool file for `ubicloud-admin host add --pool-file` (or `bin/register-byoh-host --pool-file`)

> **Do not apply in `company-mumbai` until M7 (P2).** The live security
> group has drifted from `main.tf`, and the state does not match the live
> EIPs. For live hosts, build the pool file from AWS instead of from
> Terraform:
> `bin/byoh-pool export --host <ubid> --set delivery=fabric,exposure=nat --external-map <(aws ec2 describe-addresses --output json)`.

## Why Terraform, not bash?

Earlier iterations of the BYOH test used ad-hoc `aws ec2 ...` commands.
That worked but was non-declarative, hard to destroy cleanly, and
scattered state across operator memory + `/tmp/*.env` files. Terraform
replaces all of that with:

- **One `terraform apply`** to create everything, **one `terraform destroy`** to tear it down
- Declarative resource graph — terraform computes the correct order (VPC before subnet before instance, EIPs before associations, etc.)
- Drift detection via `terraform plan`
- Cleanup is free: even if a step fails mid-way, `terraform destroy` knows exactly what to remove

Everything on the **control plane software side** (Ruby, Postgres, clover, bundle install, npm, migrations) stays as idempotent bash scripts under `../../scripts/byoh/` — terraform only handles the AWS infrastructure layer.

## Prerequisites

- Terraform `>= 1.5`
- AWS credentials with permission to create VPC, EC2, EIP, KeyPair
- Bare metal instance quota (default new-account quota `L-1216C47A` is 5 vCPUs; `m5d.metal` is 96 vCPUs — request an increase if needed)
- EIP quota (default is 5 per region; request an increase via `aws service-quotas` if you want a larger pool)

## Usage

```bash
cd terraform/aws-byoh

# 1. Copy the example tfvars and edit it
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # set operator_ssh_cidr, web_ui_cidr, aws_region, etc.

# 2. Export AWS credentials (terraform.tfvars should NOT contain secrets)
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...

# 3. Init + apply
terraform init
terraform apply
```

**`operator_ssh_cidr` and `web_ui_cidr` are required (M4).** They no
longer default to `0.0.0.0/0`, so an existing `terraform.tfvars` or
`<name>.tfvars` that leaves either out now stops `plan` with "No value
for required variable". Set both, normally to your public IP as a
`/32`. To keep the old behaviour, set them to `"0.0.0.0/0"` explicitly
(SSH open to the world; `byoh_location_create_command` warns).

`terraform apply` takes ~5-10 minutes — most of it is the `m5d.metal`'s Nitro BMC POST. It prints a big `handoff_instructions` block at the end with the public IPs, SSH commands, and EIP mapping.

## Pools file

`terraform apply` writes `.generated/<workspace>/pools.yaml` (output
`pools_yaml_path`), a version 2 pool file:

- every `byoh_secondary_private_ips` entry is a `/32` with
  `delivery: fabric`, `exposure: nat` and `external` mapping it to its EIP;
- every `byoh_internal_private_ips` entry is a `/32` with
  `delivery: fabric`, `exposure: internal` and no EIP. VMs created with
  `ip4_exposure=internal` land there: reachable only from inside the VPC,
  with outbound traffic through the host NAT;
- `ipv6_mode: ula`, because the VPC has no IPv6.

With the default `byoh_internal_private_ips = []`, the AWS resources are
the same as before; only the local `pools.yaml` file is added.

`terraform output -raw byoh_location_create_command` prints the
`sudo ubicloud-admin site add` command for this VPC: underlay = the VPC
CIDR, `cp_source` = the control plane's private `/32`, `mgmt_allow` =
that `/32` plus `operator_ssh_cidr`, and billing rates copied from
`hetzner-fsn1`. On a packaged control plane, `site add` writes them to
`/var/lib/ubicloud/billing_rates.d` and restarts `ubicloud.target`. It
warns when `operator_ssh_cidr` is `0.0.0.0/0`, and leaves that CIDR out
of `--mgmt-allow`, because VMs behind the host NAT are denied the
`mgmt_allow` networks.

`terraform output -raw host_add_command` prints how to add the data
plane with `ubicloud-admin host add` (ROADMAP §6.3, form A):

1. On the workstation, the `--expect-host-key` flags, parsed from the
   SSH host key fingerprints cloud-init prints to the data plane's
   console (`aws ec2 get-console-output`; this parse is UNVERIFIED on
   current AMIs). Terraform cannot know the host keys: the instance
   makes them at first boot.
2. On the workstation, `scp` of `pools.yaml` and the EC2 key from
   `.generated/<workspace>/` to the control plane.
3. On the control plane, `sudo ubicloud-admin host add --site ... --ssh
   ubuntu@<data private IP> --ssh-key ~/byoh_ssh_key --pool-file
   ~/pools.yaml $EXPECT --no-wait`, then `shred -u ~/byoh_ssh_key`, then
   `sudo ubicloud-admin host watch <data private IP>`. `host add` deletes
   its own staged copy of the key after the prepare phase; `--no-wait`
   lets the operator's copy go before the bring-up watch too.

**Development control plane.** `user-data-ctrl.sh` installs only
prerequisites; if you then run `bootstrap-dev-ctrl-plane.sh` rather
than `install.sh`, there is no `ubicloud-admin` on `PATH`. Run
`packaging/bin/ubicloud-admin --dev` from `~/ubicloud`, without `sudo`,
in place of `sudo ubicloud-admin` in both outputs, and restart `puma`
and `respirate` yourself after `site add`.

Neither output has been run against AWS (UNVERIFIED; the M4 AWS canary
in `docs/byoh/VERIFY.md`). `terraform fmt` and `validate` were not run
on these files either.

## Outputs

Running `terraform output` after apply:

```
byoh_eip_to_private_ip = {
  "13.xxx.xxx.xxx" = "10.98.1.128"
  "13.yyy.yyy.yyy" = "10.98.1.129"
  "35.zzz.zzz.zzz" = "10.98.1.130"
}
byoh_internal_ip_pool        = []
byoh_ip_pool                 = ["10.98.1.128", "10.98.1.129", "10.98.1.130"]
byoh_location_create_command = <sudo ubicloud-admin site add ...>
ctrl_public_ip               = "13.aaa.aaa.aaa"
data_public_ip               = "52.bbb.bbb.bbb"
data_private_ip              = "10.98.1.101"
pools_yaml_path              = "./.generated/<workspace>/pools.yaml"
ssh_private_key_path         = "./.generated/<workspace>/byoh_ssh_key"
handoff_instructions         = <long multi-line string with exact next steps>
host_add_command             = <scp, sudo ubicloud-admin host add ..., shred, host watch>
```

Registered with `--pool-file`, a VM's IPv4 is shown to the customer as
its EIP, and SSH, Postgres and load balancer DNS use the EIP.

## What happens next (after terraform apply)

Terraform has done the AWS side. Now the operator logs into the
control plane and runs the Ubicloud software-side setup:

```bash
# From your workstation:
ssh -i terraform/aws-byoh/.generated/byoh_ssh_key ubuntu@<ctrl_public_ip>

# On the control plane:
git clone -b byoh-driver <github-url> ~/ubicloud
# Packaged (production) control plane; flags in docs/byoh/INSTALL.md:
sudo bash ~/ubicloud/scripts/byoh/install.sh --version v0.1.0 --url https://<host> ...
# Or a development control plane; follow docs/byoh/QUICKSTART.md:
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
```


Then run `terraform output -raw byoh_location_create_command` and
`terraform output -raw host_add_command` (above). `QUICKSTART.md` walks
through the rest: the web UI, a project, an SSH key and a VM.

## Teardown

```bash
terraform destroy
```

Kills everything this module created: instances, EIPs, SG, RT, IGW,
subnet, VPC, keypair. Does not touch anything in other VPCs, other
tags, or other regions.

## State file

`terraform.tfstate` is **gitignored** and stays local. For a long-lived
deployment, configure an S3 backend with DynamoDB locking by adding
a `backend "s3"` block to `main.tf`. For a single-operator test env
the default local state is fine.
