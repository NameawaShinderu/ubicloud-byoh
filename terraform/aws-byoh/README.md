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
- 3 Elastic IPs, each 1:1 associated with a secondary private IP

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
$EDITOR terraform.tfvars   # set operator_ssh_cidr, aws_region, etc.

# 2. Export AWS credentials (terraform.tfvars should NOT contain secrets)
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...

# 3. Init + apply
terraform init
terraform apply
```

`terraform apply` takes ~5-10 minutes — most of it is the `m5d.metal`'s Nitro BMC POST. It prints a big `handoff_instructions` block at the end with the public IPs, SSH commands, and EIP mapping.

## Outputs

Running `terraform output` after apply:

```
byoh_eip_to_private_ip = {
  "13.xxx.xxx.xxx" = "10.99.1.128"
  "13.yyy.yyy.yyy" = "10.99.1.129"
  "35.zzz.zzz.zzz" = "10.99.1.130"
}
byoh_ip_pool         = ["10.99.1.128", "10.99.1.129", "10.99.1.130"]
ctrl_public_ip       = "13.aaa.aaa.aaa"
data_public_ip       = "52.bbb.bbb.bbb"
data_private_ip      = "10.99.1.101"
ssh_private_key_path = "./.generated/byoh_ssh_key"
handoff_instructions = <long multi-line string with exact next steps>
```

The `byoh_eip_to_private_ip` map is critical: when Ubicloud allocates
a VM one of the private IPs from the pool, SSH to the **matching EIP**
from anywhere on the internet.

## What happens next (after terraform apply)

Terraform has done the AWS side. Now the operator logs into the
control plane and runs the Ubicloud software-side setup:

```bash
# From your workstation:
ssh -i terraform/aws-byoh/.generated/byoh_ssh_key ubuntu@<ctrl_public_ip>

# On the control plane:
git clone <github-url> ubicloud
cd ubicloud && git checkout byoh-driver
./scripts/byoh/bootstrap-ctrl-plane.sh
# follow docs/byoh/QUICKSTART.md for the rest
```

The `QUICKSTART.md` walks through generating the ctrl→data SSH key,
installing it on the data plane, running `bin/register-byoh-host`,
opening the web UI, creating a project + SSH key + VM. Clean ~10-minute
procedure end-to-end.

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
