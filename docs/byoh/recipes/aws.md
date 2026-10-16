# Recipe: an EC2 instance as a BYOH host (`terraform/aws-byoh`)

> **Status.** The machine, the pools and the C5 fix were validated with
> `bin/register-byoh-host` in ap-south-1 (2026-10-11 and 2026-10-13,
> [VERIFY.md](../VERIFY.md) §5). The `host add` path below has **not**
> run on AWS (UNVERIFIED): that is the M4 gate G-M4-1 (VERIFY.md §6),
> scripted in `scripts/byoh/verify/m4-e2.sh`. Terraform was not applied
> for M4. Never apply in the `company-mumbai` workspace (CLAUDE.md §8a).

The full guide is [platforms/aws.md](../platforms/aws.md). This page is
the short path: terraform makes the machine and `pools.yaml`, then the
three commands of [README.md](README.md).

## 1. Machine and pools

On your workstation, in a **fresh workspace** with its own tfvars
(platforms/aws.md §3.1):

```bash
cd terraform/aws-byoh
terraform workspace new mysite
$EDITOR mysite.tfvars       # operator_ssh_cidr and web_ui_cidr are required: your /32
terraform apply -var-file=mysite.tfvars
```

- `data_plane_instance_type = "m8i.2xlarge"` and
  `data_plane_nested_virtualization = true` (the defaults are stale).
- `byoh_secondary_private_ips`: ENI secondary IPs, each with an EIP; they
  become `fabric` + `nat` pool entries. `byoh_internal_private_ips`
  (optional) become `fabric` + `internal`.
- Terraform writes `.generated/mysite/pools.yaml` and the EC2 key pair
  `.generated/mysite/byoh_ssh_key`.

**The C5 fix is built in.** EC2's cloud-init datasource puts every ENI
secondary IP on the instance's NIC, so the host would answer for its own
VMs. `user-data-data.sh` turns that off
(`/etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg`,
`apply_full_imds_network_config: false`), strips `addresses:` from the
netplan and removes the secondary IPs (platforms/aws.md §3.3). Host
preflight checks the result on every platform: PF17 fails a pool address
that is local on the host, and `PF17-netplan` warns when the cloud-init
netplan gives the uplink more than one IPv4 address.

**AWS checks preflight does not make** (they were PF18 in the design;
the code stays platform-neutral). Run them by hand once:

```bash
# workstation
aws ec2 describe-network-interfaces --network-interface-ids $(terraform output -raw data_eni_id) \
  --query 'NetworkInterfaces[0].PrivateIpAddresses[].PrivateIpAddress'    # every pool IP is listed
aws ec2 describe-instances --instance-ids $(terraform output -raw data_instance_id) \
  --query 'Reservations[0].Instances[0].MetadataOptions'                  # HttpTokens, HttpPutResponseHopLimit
# data plane (ssh -i .generated/mysite/byoh_ssh_key ubuntu@<data public IP>)
test -f /etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg && test -f /var/log/user-data.done && echo user-data ok
ip -br -4 addr                                                            # only the primary IP
```

IMDSv2 with hop limit 1 (`aws ec2 modify-instance-metadata-options
--http-tokens required --http-put-response-hop-limit 1`) is advised and
not set by the module yet (platforms/aws.md §3.10). VMs cannot reach the
metadata address in any case: the host NAT drops `169.254.0.0/16`.

## 2. The three commands

`install.sh` on the control plane (the module's control-plane instance,
or any Ubuntu 24.04 machine in the VPC), then:

```bash
terraform output -raw byoh_location_create_command    # prints: sudo ubicloud-admin site add byoh-aws-mysite ...
terraform output -raw host_add_command                # prints the host add steps below
```

`host_add_command` prints, for this workspace (platforms/aws.md §3.7):

1. **Workstation:** an `aws ec2 get-console-output` line that prints
   `--expect-host-key SHA256:...` flags from the fingerprints cloud-init
   writes to the console at first boot. Terraform cannot know the keys;
   the parse is UNVERIFIED on current AMIs. If it prints nothing, leave
   `EXPECT` empty and compare the fingerprints `host add` shows by hand.
2. **Workstation:** `scp` of `pools.yaml` and the EC2 key to the control
   plane.
3. **Control plane:**

   ```bash
   EXPECT='--expect-host-key SHA256:... --expect-host-key SHA256:...'
   sudo ubicloud-admin host add --site byoh-aws-mysite --ssh ubuntu@<data private IP> \
     --ssh-key ~/byoh_ssh_key --pool-file ~/pools.yaml $EXPECT --no-wait \
     && shred -u ~/byoh_ssh_key \
     && sudo ubicloud-admin host watch <data private IP>
   ```

   `--main-ip` defaults to the `--ssh` host, the data plane's **private**
   IP, which is right on AWS.

**The EC2 key leaves the control plane after prepare.** `host add` uses
the EC2 key only to log in as `ubuntu`. It installs and keeps its own
root key, and `ubicloud-admin` deletes its staged copy of the EC2 key
when the prepare phase ends. `--no-wait` returns once the host is
registered, so the chained `shred -u` removes your copy before the
bring-up watch. If `host add` fails, the key stays for a retry and
nothing else runs.

4. **Optional, workstation:** user-data also put the EC2 key in root's
   `authorized_keys` (for the `register-byoh-host` path), and `host add`
   keeps every root key but replaces only its own tagged line. The
   output's step 4 removes the EC2 key from root's logins and leaves it as
   the `ubuntu` login; it changes nothing unless `host add`'s key (tagged
   `ubicloud-byoh`) remains.

Development control plane: `packaging/bin/ubicloud-admin --dev` from
`~/ubicloud` without `sudo`, and restart `puma` and `respirate` after
`site add`.

## 3. Afterwards

- A `nat` VM is reached at its EIP: `ssh ubi@<EIP>`. Security group
  ingress is the operator's /32 only until `host_guard` (M7).
- Leave the monitor off unless you are running the F5 soak
  (`scripts/byoh/verify/m4-f5-soak.sh`, VERIFY.md G-M4-3). Since M4 the
  health checks of a BYOH host fit EBS (no SMART, `nvme-Amazon_Elastic_Block_Store_*`
  ids, `kvm-clock`), but the 24-hour soak has not run.
- Stop the data plane when idle and `terraform destroy` the workspace when
  done; then check `aws ec2 describe-addresses` for leftover EIPs.
