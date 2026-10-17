# Ubicloud BYOH quickstart

The shortest path from two Ubuntu 24.04 machines to a running VM, with the packaged control plane. It is the same on every platform; only how you create the machines and how pool addresses reach the host differ. The overview and the virtualization choice are in [README.md](README.md), the details behind each step in [SETUP.md](SETUP.md).

- AWS: the "AWS" section below and [platforms/aws.md](platforms/aws.md). **Validated.**
- Proxmox VE: [recipes/proxmox.md](recipes/proxmox.md), [platforms/proxmox.md](platforms/proxmox.md). UNVERIFIED.
- Anything else: [platforms/README.md](platforms/README.md). UNVERIFIED.

When something goes wrong: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## You need

- **Control plane:** Ubuntu 24.04 x86_64, about 4 GiB of memory, root through `sudo`, outbound internet, and a DNS name for it (for `--tls acme`, also `api.<name>`; `<ip>.sslip.io` names need no DNS work).
- **Data plane:** Ubuntu 24.04 x86_64, a dedicated machine (registration reboots it and takes it over), outbound internet, and only its main address on the NIC. KVM is best; without it see step 5.
- **SSH** from the control plane to the data plane, with a login there that has passwordless `sudo` (`ubuntu` on cloud images).
- **A pool**, unless every VM will be IPv6-only: addresses that reach the data plane and are **not** configured on its NIC, with their `delivery` and `exposure` (SETUP.md §3).
- An [age](https://age-encryption.org) public key for the backups, whose secret key lives off the machine.

---

## 1. Control plane

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
sudo bash ~/ubicloud/scripts/byoh/install.sh --version v0.1.0 \
  --source-git ~/ubicloud --ref HEAD \
  --url https://cloud.example.com --tls acme --admin-email ops@example.com \
  --backup-recipient age1...
sudo ubicloud-admin status
```

- `--tls` picks the front: `acme` (Let's Encrypt; ports 80 and 443 and public DNS), `provided --cert F --key F`, `tunnel` (cloudflared, `--cloudflared-token-file F`) or `none` (`--url http://localhost:3000`, reached over `ssh -L`). [INSTALL.md](INSTALL.md) §3.
- The front also serves the API on `api.<host>` (`--api-host` to change it, `--no-api` to leave it out). The `ubi` CLI needs it (step 6).
- `--rack-env production` is the default; boot images then come from the public Ubuntu mirror. The other flags: [INSTALL.md](INSTALL.md) §2.

## 2. First account

```bash
sudo ubicloud-admin account create --email you@example.com --name "Your Name"
```

It prints a generated password once (`--password-stdin` or `--password-file F` to give one) and `Created account ... with project pj... (Default)`. Keep the `pj...` ubid for step 3. No mail is needed.

## 3. Site

```bash
sudo ubicloud-admin site add byoh-site1 --display "Site 1 (BYOH)" \
  --underlay <site CIDRs> --overlay 172.20.0.0/14 --cp-reach onhost \
  --cp-source <control plane IP as the site sees it>/32 --mgmt-allow <admin CIDRs> \
  --rates-from hetzner-fsn1 --grant pj...
```

`--cp-reach public` when the control plane is not on the site network. The site stays hidden; `--grant` lets your project use it. `site add` restarts the services so they load the rates. Options: [SETUP.md](SETUP.md) §6.

## 4. Pools

Write `pools.yaml` for the site ([POOL_OPERATIONS.md](POOL_OPERATIONS.md) §1, examples in [recipes/](recipes/README.md) and SETUP.md §7), then check the host without changing it:

```bash
sudo ubicloud-admin host preflight --site byoh-site1 --ssh ubuntu@<host> \
  --ssh-key ~/.ssh/<your login key> --pool-file pools.yaml
```

Its PF3 line names the host's virtualization rung and, when KVM can be switched on, the fix.

## 5. Host

Pick one option ([README.md](README.md) §2 compares them). Every lower tier is experimental and single-project, and its VMs come in their own sizes.

**KVM** (PF3 passes):

```bash
sudo ubicloud-admin host add --site byoh-site1 --ssh ubuntu@<host> \
  --ssh-key ~/.ssh/<your login key> --pool-file pools.yaml
```

**No KVM, containers first** (`auto` picks the fallback the probe recommends, `container` before `emulated`; the site must offer it). Install the tier's packages on the host, offer the tier in the site, then add the host:

```bash
# on the host
sudo apt-get install lxc lxcfs uidmap xz-utils quota cryptsetup-bin e2fsprogs   # emulated: qemu-system-x86 ovmf
# on the control plane
sudo ubicloud-admin site rates byoh-site1 --family container --from standard --multiplier 1.0
sudo ubicloud-admin site set byoh-site1 --virt-tiers kvm,container --accept container
sudo ubicloud-admin host add --site byoh-site1 --ssh ubuntu@<host> \
  --ssh-key ~/.ssh/<your login key> --pool-file pools.yaml \
  --virt-tier auto --accept-fallback
```

For `emulated` alone, use `--family emulated`, `--virt-tiers kvm,emulated --accept emulated` and `--virt-tier emulated --accept-fallback`.

**No KVM, VM isolation required: PVM.** x86_64 only, a CPU that Meltdown does not affect, Secure Boot off. The control plane installs a third-party PVM host kernel that you pin by URL and sha256; the code has no default pin ([NO_KVM.md](NO_KVM.md) §6.7, which lists the example build used for testing):

```bash
sudo ubicloud-admin site rates byoh-site1 --family pvm --from standard --multiplier 1.0
sudo ubicloud-admin site set byoh-site1 --virt-tiers kvm,pvm --accept pvm \
  --pvm-host-deb <https URL> --pvm-host-deb-sha256 <hex> \
  --pvm-guest-kernel <https URL> --pvm-guest-kernel-sha256 <hex> \
  --pvm-guest-config <https URL> --pvm-guest-config-sha256 <hex>
sudo ubicloud-admin host add --site byoh-site1 --ssh ubuntu@<host> \
  --ssh-key ~/.ssh/<your login key> --pool-file pools.yaml \
  --virt-tier pvm --install-pvm-kernel --accept-fallback
```

`--pvm-guest-unchecked` replaces the guest-config pair when the guest kernel's config cannot be read. `site set` downloads each pin and checks its sha256. `scripts/byoh/bootstrap-data-plane.sh --tier pvm` on the host runs the same refusals read-only beforehand.

**What `host add` does:** preflight (read-only; a `fail` stops it before any change), shows the changes and the host's key fingerprints and asks for `yes`, installs its own root key, registers the host, follows the bring-up (one reboot; PVM: the kernel install and a second boot) until the host accepts VMs, then runs `pool verify`. About 4 minutes on a nested-virtualization VM, 15-25 on bare metal, and 184 s for PVM on an m6i.2xlarge (VERIFY.md §8). Exit 0 means done; Ctrl-C stops only the watch, and `sudo ubicloud-admin host watch <host>` resumes it. Exit codes: [TROUBLESHOOTING.md](TROUBLESHOOTING.md) §2.3.

## 6. First VM

**Web UI.** Log in at the `--url` with the account of step 2, add an SSH key, and create a VM in "Site 1 (BYOH)" with `ubuntu-noble`. With IPv4, exposure **internet** needs a `public` or `nat` pool and **internal** an `internal` pool; with IPv4 off the VM needs no pool. The web form offers only the standard (KVM) sizes.

**`ubi` CLI.** Create a personal access token in the web UI (the project's Tokens page), then, from any machine with Ruby and a clone of this repository:

```bash
export UBI_TOKEN=pat-... UBI_URL=https://api.cloud.example.com/cli
~/ubicloud/bin/ubi vm list
~/ubicloud/bin/ubi vm byoh-site1/vm1 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"
~/ubicloud/bin/ubi vm byoh-site1/vm1 ssh
```

Lower tiers take their own size and image: `-s container-2 -b ubuntu-noble-container`, `-s pvm-2 -b ubuntu-noble`, `-s emulated-2 -b ubuntu-noble`. `-e internal` asks for an internal address, `-6` for no IPv4. The VM user is `ubi`. Under `--tls none`, use `UBI_URL=http://api.localhost:3000/cli` over `ssh -L 3000:127.0.0.1:3000` ([INSTALL.md](INSTALL.md) §3.1).

---

## Development control plane

For labs, `scripts/byoh/bootstrap-dev-ctrl-plane.sh` runs the same code in tmux ([SETUP.md](SETUP.md) §4.2). Run `packaging/bin/ubicloud-admin --dev site|host|pool ...` from `~/ubicloud` without `sudo` in place of `sudo ubicloud-admin`, create the account at `http://<control plane>:3000/create-account` or with `bundle exec bin/byoh-account create --email ...`, and restart `puma` and `respirate` yourself after `site add` or `site rates`.

---

## AWS

This is the validated path. `terraform/aws-byoh` creates the machines, the network and the pools; the steps above do not change. AWS-only details: [platforms/aws.md](platforms/aws.md) and SETUP.md §12.

1. **Quota.** Enough vCPU quota for the data plane, and one free EIP per pool address (the default is 5 per region).
2. **Terraform**, on your workstation:
   ```bash
   cd terraform/aws-byoh
   terraform workspace new mysite          # one workspace and one mysite.tfvars per environment
   $EDITOR mysite.tfvars
   terraform apply -var-file=mysite.tfvars
   ```
   - KVM: `data_plane_instance_type = "m8i.2xlarge"` and `data_plane_nested_virtualization = true`. The defaults (m5d.metal, nested off) are stale.
   - PVM instead: an m6i/m7i **xlarge or larger** with nested virtualization off ([platforms/aws.md](platforms/aws.md) §2.1a).
   - `operator_ssh_cidr` and `web_ui_cidr` set to your /32.
   - `byoh_secondary_private_ips` get EIPs and become `nat`; optional `byoh_internal_private_ips` become `internal`.
3. **Outputs.** `byoh_location_create_command` prints step 3's `site add` for this VPC. `host_add_command` prints how to copy `.generated/<workspace>/pools.yaml` and the login key to the control plane and run step 5's `host add` with `--expect-host-key`. `handoff_instructions` lists the rest.
4. **Data plane.** Terraform's `user-data-data.sh` keeps the pool IPs off the NIC. Check that `ip -br -4 addr` on the data plane shows only the primary IP. The main IP is the data plane's **private** IP.
5. **Monitor.** Leave it off on EBS-backed hosts until the F5 soak has run (VERIFY.md G-M4-3).
6. **SSH.** A `nat` VM is reached at its EIP: `ssh ubi@<EIP>`.
7. **Teardown.** `terraform destroy -var-file=mysite.tfvars` in the same workspace, then check that `aws ec2 describe-addresses` lists no leftover EIPs.

---

## Common problems

The full catalogue is [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

| Symptom | Fix |
|---|---|
| `host add` stops at preflight | The `fail` line names the check and the fix; [TROUBLESHOOTING.md](TROUBLESHOOTING.md) §2.1a |
| PF3 fails: no usable KVM | Apply the printed fix, or pick a lower tier (step 5, [NO_KVM.md](NO_KVM.md)) |
| `host add` refuses a lower tier: the location does not offer it | Run the `rates` and `set` commands it prints, as `sudo ubicloud-admin site rates` and `site set` |
| `ubi` prints an HTML login page | `UBI_URL` points at the web host; use `https://api.<host>/cli` |
| VM waits for capacity | No free address of the requested exposure, no boot image of that name, or a lower-tier size on a site or host without that tier |
| VM stuck at `wait_sshable` | The control plane cannot reach the VM's pool address; `--cp-reach public` when it is off-site |
| `Permission denied (publickey)` on a VM | Use `ubi@`. On AWS, also check that the pool IPs are not on the host's NIC (C5) |
