# Ubicloud BYOH quickstart

The shortest path from two Ubuntu 24.04 machines to a running VM. It works the same on any platform. The details behind each step are in [SETUP.md](SETUP.md). The only platform-specific parts are how you create the machines and how pool addresses reach the host:

- AWS with terraform: the "AWS-specific (optional)" section below, and [platforms/aws.md](platforms/aws.md). **Validated.**
- Proxmox VE: [platforms/proxmox.md](platforms/proxmox.md) and [SETUP_PROXMOX.md](SETUP_PROXMOX.md). UNVERIFIED.
- Anything else: pick your platform in [platforms/README.md](platforms/README.md). UNVERIFIED.

When something goes wrong: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## You need

- **Control plane:** Ubuntu 24.04, 2 vCPU, 4 GB RAM or more, and a sudo user.
- **Data plane:** Ubuntu 24.04 with KVM and 1G pages. On a VM, that means nested virtualization and a host CPU model.
  - Memory must be a whole number of GiB on the published `byoh-driver`; 32 GiB is a good size.
  - It needs outbound internet.
  - It must be a dedicated machine; registration reboots it.
- **SSH** from the control plane to the data plane's management IP.
- **At least one pool**, unless every VM will be IPv6-only:
  - addresses that reach the data plane and are **not** configured on its NIC;
  - their `delivery` and `exposure` (SETUP.md §3).

---

## 1. Control plane

This is the development bootstrap (tmux, `clover_test`), which the live environment runs. A packaged control plane (systemd, TLS, backups) is installed with `scripts/byoh/install.sh` instead: [INSTALL.md](INSTALL.md).

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
export PATH=$HOME/.local/bin:$HOME/.local/share/mise/installs/ruby/4.0.7/bin:$PATH
cd ~/ubicloud
curl -sS -o /dev/null -w "HTTP %{http_code}\n" http://localhost:3000/login     # HTTP 200
```

## 2. Data plane

On the data plane:

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
```

On the control plane:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/byoh_data
ssh <admin user>@<data main IP> "sudo tee -a /root/.ssh/authorized_keys" < ~/.ssh/byoh_data.pub
ssh -i ~/.ssh/byoh_data root@<data main IP> true && echo ok
```

## 3. Location

```bash
bundle exec bin/byoh-location create --name byoh-site1 --ui-name "Site 1 (BYOH)" \
  --underlay <site CIDRs> --overlay 172.20.0.0/14 --cp-reach onhost \
  --cp-source <control plane IP>/32 --rates-from hetzner-fsn1
```

Restart the services so they load the rates:

```bash
tmux kill-session -t puma; tmux kill-session -t respirate
bash scripts/byoh/bootstrap-dev-ctrl-plane.sh    # restarts them; every other step is skipped
```

## 4. Pools and registration

Write `pools.yaml` for your site. Examples are in SETUP.md §7, SETUP_PROXMOX.md §6 and POOL_OPERATIONS.md §1. Then:

```bash
bundle exec bin/register-byoh-host --location byoh-site1 --main-ip <data main IP> \
  --pool-file pools.yaml --ssh-key ~/.ssh/byoh_data --default-boot-image ubuntu-noble --yes
```

Wait for `accepting`. That takes about 4 minutes on a nested-virtualization VM and 15-25 minutes on bare metal, including one reboot.

```bash
psql -U clover -d clover_test -c "SELECT allocation_state FROM vm_host"
bundle exec bin/byoh-pool verify --host vh...
```

## 5. First VM

1. Sign up at `http://<control plane>:3000/create-account`. The verification email is in `/tmp/puma.log`; if its link starts with `http://localhost:9292` (an `.env.rb` without `BASE_URL`), replace that part with `http://<control plane>:3000`.
2. Grant the project access to the location:
   ```bash
   bundle exec bin/byoh-location grant --location byoh-site1 --project pj...    # the project ubid, from the UI's /project/pj… address
   ```
3. Add an SSH key.
4. Create a VM in "Site 1 (BYOH)" with `ubuntu-noble`:
   - IPv4 exposure **internet** needs a `public` or `nat` pool.
   - **internal** needs an `internal` pool.
   - With IPv4 off, the VM needs no pool.
5. Connect with `ssh ubi@<address shown in the UI>`. The user is `ubi`, not `ubuntu`.

## 6. Check

```bash
GATE_LOCATION=byoh-site1 GATE_HOST=vh... GATE_MAIN_IP=<data main IP> \
  scripts/byoh/verify/m2-gate.sh g1 g2 g4 g5
```

[VERIFY.md](VERIFY.md) §1.4 lists the settings for the VM checks.

---

## AWS-specific (optional)

This is the validated path. It uses `terraform/aws-byoh` to create the machines, the network and the pools. Nothing else in the steps above changes. Everything AWS-only is listed in SETUP.md §12.

1. **Quota.** You need enough vCPU quota for the data plane and one free EIP per pool address. The default EIP quota is 5 per region.
2. **Terraform.** Run it on your workstation:
   ```bash
   cd terraform/aws-byoh
   terraform workspace new mysite          # one workspace + one mysite.tfvars per environment
   $EDITOR mysite.tfvars
   terraform apply -var-file=mysite.tfvars
   ```
   Set these variables:
   - `data_plane_instance_type = "m8i.2xlarge"` and `data_plane_nested_virtualization = true`. The defaults (m5d.metal, nested off) are stale.
   - `operator_ssh_cidr` and `web_ui_cidr` set to your /32. Both are required since M4.
   - `byoh_secondary_private_ips`, which get EIPs and become `nat`, and optionally `byoh_internal_private_ips`, which become `internal`.
3. **Outputs.** Terraform prints `handoff_instructions`. It also writes `.generated/<workspace>/pools.yaml` (`fabric` + `nat`, with the EIPs as `external`), and `byoh_location_create_command` prints the step 3 command for this VPC (`sudo ubicloud-admin site add ...`). `host_add_command` prints how to copy `pools.yaml` and the generated SSH key to the control plane and add the host with `ubicloud-admin host add` (platforms/aws.md §3.7; UNVERIFIED on AWS). On a development control plane, run `packaging/bin/ubicloud-admin --dev` from `~/ubicloud` in place of `sudo ubicloud-admin`.
4. **Data plane.** Terraform's `user-data-data.sh` replaces `bootstrap-data-plane.sh`, and it also applies the cloud-init secondary-IP fix. Check that `ip -br -4 addr` on the data plane shows only the primary IP. `--main-ip` is the data plane's **private** IP.
5. **Monitor.** Do not run `bin/monitor` for EBS-backed hosts, and run the gate with `GATE_EXPECT_MONITOR=0`.
6. **SSH.** A `nat` VM is reached at its EIP: `ssh ubi@<EIP>`.
7. **Teardown.** Run `terraform destroy -var-file=mysite.tfvars` in the same workspace. Then check that `aws ec2 describe-addresses` lists no leftover EIPs.

---

## Common problems

The full catalogue is [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

| Symptom | Fix |
|---|---|
| `bundle install` fails with "No such file or directory - mise" | Put `~/.local/bin` on PATH |
| `bundle` uses the system Ruby | Put `~/.local/share/mise/installs/ruby/4.0.7/bin` on PATH |
| `register-byoh-host` aborts on `--provider` | There is no such flag; use `--location` |
| Strands fail with `NetSsh::MissingMock` | `RACK_ENV=test` on a control plane. Use `development`. |
| VM waits for capacity | No free address of the requested exposure, or no boot image (`--default-boot-image`) |
| VM stuck at `wait_sshable` | The control plane cannot reach the VM's pool address; use `--cp-reach public` when it is off-site |
| `Permission denied (publickey)` on a VM | Use `ubi@`. On AWS, also check that the pool IPs are not on the host's NIC (C5). |

## See also

- [SETUP.md](SETUP.md): the full runbook.
- [platforms/README.md](platforms/README.md): one guide per platform.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): symptoms, causes and fixes.
- [SETUP_PROXMOX.md](SETUP_PROXMOX.md): Proxmox.
- [POOL_OPERATIONS.md](POOL_OPERATIONS.md): changing pools.
- [VERIFY.md](VERIFY.md): the gate and the live window.
- [NETWORKING.md](NETWORKING.md), [PLATFORMS.md](PLATFORMS.md), [ROADMAP.md](ROADMAP.md).
