# BYOH on Google Cloud and Microsoft Azure

**Status: UNVERIFIED.** Neither platform has been run end to end with BYOH. The only validated platform is AWS (m8i with nested virtualization, ap-south-1; [SETUP.md](../SETUP.md) §12). This page combines the platform-neutral steps that are proven on AWS with the GCP and Azure specifics from [NETWORKING.md](../NETWORKING.md) §9.7 and §9.8. Every statement about GCP or Azure behaviour comes from provider docs and is UNVERIFIED here. The links are under "Sources" at the end. No prices or quotas are given, because none were checked.

Every Ubicloud command and flag on this page exists in the M2 code (`bin/byoh-location`, `bin/register-byoh-host`, `bin/byoh-pool`, `scripts/byoh/*`). The `gcloud` and `az` commands come from provider docs. Check them against `--help` for your CLI version.

---

## 1. Fit

Use GCP or Azure when you already have an account there and want BYOH hosts without renting bare metal. The data plane is a cloud VM with nested virtualization, so VMs run as nested guests, as on the validated AWS m8i setup.

| Platform | Pool model (NETWORKING §3) | What customers see | IPv6 |
|---|---|---|---|
| GCP, variant A | `routed` + `public`: one external IP per **protocol forwarding** rule pointing at the host. GCP delivers packets with the destination unchanged. | The external IP itself, labelled Public IPv4 | `ula` |
| GCP, variant B | `fabric` + `internal`: an **alias IP range** on the host's NIC | The alias address, labelled Internal IPv4 (reachable only from the VPC) | `ula` |
| Azure | `fabric` + `nat`: **secondary IP configurations** on the host's NIC, each with a **Public IP** that Azure 1:1 NATs to it | The Public IP, labelled Public IPv4 | `ula` (Azure NATs IPv6) |
| Both | No pool at all: VMs without IPv4, whose outbound IPv4 goes through the host NAT | No IPv4 | `ula` |

Why GCP has no `fabric` + `nat` variant: the GCP alias-IP docs that were checked never map an external IPv4 to an alias IP. Protocol forwarding is the documented way to put a public IPv4 on one VM's traffic (NETWORKING §3.2).

IPv6 is `ula` on both platforms today. Registration accepts only an IPv6 /64, and GCP hands out a /96 (the GCP /96 spike is P4; NETWORKING §7.2). Do not declare an IPv6 pool. The host gets a /64 from the location's `ula48`.

Pick something else when:
- You need real IPv6 for customers.
- You need a public IPv4 that does not depend on cloud-specific constructs. Use rented bare metal with a routed block (NETWORKING §9.5).
- The host would have to share the machine with anything else. Registration takes the whole VM over.

---

## 2. Requirements

### 2.1 Host (both platforms)

| Requirement | GCP | Azure | Check on the host |
|---|---|---|---|
| Ubuntu 24.04 LTS, x86_64 | Image family `ubuntu-2404-lts-amd64`, project `ubuntu-os-cloud` | An Ubuntu 24.04 image (`az vm image list` shows the URN or alias) | `lsb_release -rs` |
| KVM through nested virtualization | `--enable-nested-virtualization` at create time. **Not** available on E2, memory-optimized or Arm types, nor on AMD series except N4D. The org policy `constraints/compute.disableNestedVirtualization` must not block it. Use N2 or C3 (provider docs). | A size whose docs list nested virtualization support, with **security type Standard**. Microsoft Q&A answers say Trusted Launch blocks nested virtualization on sizes older than v5, and that some AMD `as` sizes (E4as_v4) lack it. `Standard_D8s_v5` is a common choice (provider docs). | `ls /dev/kvm` |
| CPU flags | `vmx`, plus `pdpe1gb` for 1G hugepages | the same | `grep -Ewo 'vmx\|svm\|pdpe1gb' /proc/cpuinfo \| sort -u` |
| RAM | 32 GB or more (n2-standard-8 class). Hugepages leave at least 2 GiB `MemAvailable`. | 32 GiB or more (D8s_v5 class) | `free -g` |
| Memory reporting | `dmidecode` units in MB or a size that is not a whole GiB are accepted since a0259a997, which rounds down to whole GiB (unit specs only; UNVERIFIED on a real GCP or Azure host) | the same; Hyper-V guests are the usual case | `sudo dmidecode -t memory \| grep Size:` |
| Disk | VM disks live under `/var/storage` on the root filesystem. Make the boot disk large enough for boot images plus VM disks (`--boot-disk-size`). | The same (`--os-disk-size-gb`). **Never** use the ephemeral resource disk (`/mnt`, usually `/dev/sdb1`) for `/var/storage/devices/<n>`: Azure may wipe it. | `df -h /var/storage` |
| Disk health checks | Persistent Disk and Hyperdisk have no SMART. Leave `bin/monitor` off (PLATFORMS.md F5). | Managed disks: the same | — |
| Nothing else managing nftables | no Docker, ufw, k3s | the same | `nft list tables` |

`scripts/byoh/bootstrap-data-plane.sh` refuses a host without `/dev/kvm`, without `vmx`/`svm`, or without `pdpe1gb`, before you register it (105b6439b). PrepHost checks KVM again after registration.

On branch `no-kvm`, `bin/byoh-virt probe --main-ip <IP> --ssh-key <key>` on the control plane tells you
before registering whether the VM has usable KVM and, if not, the fix for GCP (`--enable-nested-virtualization`
on an Intel series or N4D, the org policy) or Azure (a Dv3/Ev3-or-newer size, security type Standard),
with a cost line: on GCP the nested option costs nothing extra, on Azure a Dv5/Ev5 of the same size is
about the same price (UNVERIFIED; [NO_KVM.md](../NO_KVM.md) §4, §7). Changing the type is almost always
better than the experimental `container` or `emulated` tiers that a VM without KVM can still run.
The probe's GCP and Azure rows are UNVERIFIED (never run on either).

### 2.2 Network

| Item | GCP | Azure |
|---|---|---|
| Host management address (`--main-ip`) | The host's internal IP on `nic0` | The private IP of the primary ipconfig (`ipconfig1`) |
| Pool addresses | A: regional external IPs, each behind a forwarding rule that targets the host. B: an alias range on `nic0`, from the subnet's primary range or a secondary range. | One secondary ipconfig per VM address, each with its own Standard Public IP |
| Forwarding | `--can-ip-forward` at create time (NETWORKING §9.7; whether protocol forwarding needs it is UNVERIFIED) | NIC IP forwarding on (NETWORKING §9.8). By Azure's definition it is needed only for addresses that are *not* in the NIC's ipconfigs, so `fabric` may work without it (UNVERIFIED). |
| Host egress (PrepHost, boot images, VMs without IPv4) | An external IP on the host, or Cloud NAT | A Public IP on the primary ipconfig, or a NAT gateway. Virtual networks created after 2025-09-30 have no default outbound access (provider docs). |
| Pool IPs **absent from the OS** (contract C5) | The guest agent adds alias ranges and forwarded IPs as local routes by default. Turn that off (§3.2). | cloud-init's Azure datasource configures secondary IPs by default (`apply_network_config_for_secondary_ips: true`). Turn that off (§3.2). |
| Edge filter | VPC firewall rules, which can match by destination | NSG on the NIC or subnet |
| MTU | VPC default 1460. Guests get 1400 through DHCP, which fits. | 1500. Guests get 1400. |

### 2.3 Control-plane reachability

Put the control plane **in the same VPC or VNet**, in its own small VM (Ubuntu 24.04, no nested virtualization needed). Then:

- `--main-ip` is the host's private IP, exactly as on AWS.
- `--cp-reach onhost` works: the control plane dials VMs at their pool address. That covers GCP alias addresses and Azure ipconfig addresses. For GCP variant A, the pool address is the external IP, so the control plane must be able to reach it (§4, row G3).
- `--cp-source` is the control plane's private /32.

The control plane VM needs **outbound internet** too: `install.sh` and the development bootstrap download Postgres, Ruby, Node and gems, and in GCP variant A the control plane dials the forwarding-rule IPs (row G3). Give it an external IP or Cloud NAT on GCP, and a Public IP or NAT gateway on Azure, where virtual networks created after 2025-09-30 have no default outbound access (provider docs, UNVERIFIED here).

A control plane outside the VPC (another cloud, an office) needs the host's management IP to be reachable from it. That means a VPN, or SSH to an external IP that the host does not hold on its NIC. Neither has been tried with BYOH, so it is UNVERIFIED and not covered here.

---

## 3. Step by step

The order is the same as [SETUP.md](../SETUP.md). Only the provisioning (§3.1), the C5 agent settings (§3.2), the pool addresses (§3.6) and the pools file differ by platform.

### 3.1 Provision the host

**GCP** (provider docs, UNVERIFIED here). Create the host **without** aliases first, so the guest agent has nothing to claim before §3.2:

```bash
gcloud compute instances create byoh-data-1 \
  --zone=<zone> --machine-type=n2-standard-8 \
  --enable-nested-virtualization --can-ip-forward \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --boot-disk-size=<size>GB \
  --subnet=<hosts subnet> --private-network-ip=<host private IP> \
  --tags=byoh-data \
  --metadata=ssh-keys="<admin>:$(cat ~/.ssh/<admin key>.pub)"
gcloud compute firewall-rules create byoh-host-ssh --network=<vpc> --direction=INGRESS \
  --action=ALLOW --rules=tcp:22 --source-ranges=<control plane private IP>/32,<operator IP>/32 \
  --target-tags=byoh-data
```

- `--metadata=ssh-keys=` gives the host an admin login for §3.4 (or use `gcloud compute ssh`, below). Without it, the instance has no user you can SSH in as.
- Use a **custom** VPC. The `default` VPC's `default-allow-ssh` rule allows TCP 22 from 0.0.0.0/0; if you must use it, delete that rule. A custom VPC has no implied allow-internal rule, which is why `byoh-host-ssh` is created here, before the §3.4 SSH test (provider docs, UNVERIFIED here).

**Azure** (provider docs, UNVERIFIED here):

```bash
az vm create -g <rg> -n byoh-data-1 \
  --image <Ubuntu 24.04 URN or alias> --size Standard_D8s_v5 \
  --security-type Standard \
  --vnet-name <vnet> --subnet <hosts subnet> --private-ip-address <host private IP> \
  --public-ip-address byoh-data-1-pip --nsg byoh-data-nsg \
  --os-disk-size-gb <size> \
  --admin-username <admin> --ssh-key-values ~/.ssh/<admin key>.pub \
  --nsg-rule NONE
az network nic update -g <rg> -n <host NIC name> --ip-forwarding true
```

`--nsg-rule NONE` keeps `az vm create` from adding its `default-allow-ssh` rule (TCP 22 from any source) to the new NSG, while the host has a public IP. If the NSG already has that rule, remove it: `az network nsg rule delete -g <rg> --nsg-name byoh-data-nsg -n default-allow-ssh` (provider docs, UNVERIFIED here). The NSG's default `AllowVnetInBound` still lets the control plane in. `az vm show -g <rg> -n byoh-data-1 --query 'networkProfile.networkInterfaces[0].id' -o tsv` gives the NIC. If the VNet has no default outbound access, also attach a NAT gateway to the subnet, or keep the Public IP above.

### 3.2 Keep pool addresses off the host (C5)

Do this **before** you assign any pool address in the cloud API, and before registration. Registration reboots the host once, and a cloud agent that adds pool IPs on that boot makes the host answer for its VMs.

**GCP.** In `/etc/default/instance_configs.cfg`:

```ini
[IpForwarding]
ip_aliases = false
target_instance_ips = false
```

Then restart the agent: `sudo ggactl_plugin coreplugin restart` with guest agent 20250901.00 or later, otherwise `sudo systemctl restart google-guest-agent` (provider docs). `ip_aliases` covers variant B. `target_instance_ips` covers the forwarding-rule IPs of variant A. The agent docs describe `target_instance_ips` as internal load balancing, so whether it also covers external protocol forwarding is UNVERIFIED. The check below catches it either way.

**Azure.** Create `/etc/cloud/cloud.cfg.d/99-ubi-byoh-no-secondary-ips.cfg`:

```yaml
datasource:
  Azure:
    apply_network_config_for_secondary_ips: false
```

This is the Azure counterpart of the AWS fix in `terraform/aws-byoh` `user-data-data.sh` (`apply_full_imds_network_config: false`). If a secondary IP already reached the netplan (`/etc/netplan/50-cloud-init.yaml`), remove it there and run `sudo ip addr del <pool IP>/<len> dev eth0`.

**Check on both**, now and again after the registration reboot:

```bash
ip -br -4 addr                 # only the main IP on the uplink
ip route show table local      # no pool address, no alias range, no forwarding-rule IP
```

Since a092f1b8b, VM setup on a BYOH host also refuses a VM whose IPv4 is local on the host ("… is a local address of this host, so the host answers for the VM"). So a regression shows up as a failed VM create, not as silent misrouting.

### 3.3 Data-plane bootstrap

On the host:

```bash
git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
bash ~/ubicloud/scripts/byoh/bootstrap-data-plane.sh
```

Which branch carries the code this page describes: [README.md](README.md) "Which branch". It stops on missing `/dev/kvm`, `vmx`/`svm` or `pdpe1gb`, then enables root public-key login and installs `ruby-bundler` and `netcat-openbsd`. It does not touch the network.

### 3.4 Control plane

Follow [SETUP.md](../SETUP.md) §4 on the control-plane VM, then install the host key ([SETUP.md](../SETUP.md) §5):

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/byoh_data
ssh -i ~/.ssh/<admin key> <admin>@<host private IP> "sudo tee -a /root/.ssh/authorized_keys" < ~/.ssh/byoh_data.pub
ssh -i ~/.ssh/byoh_data root@<host private IP> true && echo ok
```

The second line runs on the control plane with the **admin** private key, so that key must be on the control plane too. Cloud images give the admin user passwordless sudo, so no terminal is needed (provider defaults, UNVERIFIED here). If you would rather keep the admin key on your workstation, install the root key from there instead (provider CLIs, UNVERIFIED here) and run only the last line on the control plane:

```bash
gcloud compute ssh <admin>@byoh-data-1 --zone=<zone> --command "sudo tee -a /root/.ssh/authorized_keys" < byoh_data.pub
az vm run-command invoke -g <rg> -n byoh-data-1 --command-id RunShellScript \
  --scripts "echo '$(cat byoh_data.pub)' >> /root/.ssh/authorized_keys"
```

TCP 22 from the control plane to the host: GCP needs the `byoh-host-ssh` rule from §3.1; on Azure the NSG's `AllowVnetInBound` covers it.

### 3.5 Create the location

One location per site, here one per region and VPC/VNet. `--underlay` is the network the hosts live in; VMs may not open connections into it through the host NAT.

GCP:

```bash
bundle exec bin/byoh-location create --name byoh-gcp-<region> --ui-name "GCP <region> (BYOH)" \
  --underlay <every subnet range of the VPC, comma-separated; 10.128.0.0/9 for an auto-mode VPC> \
  --overlay 172.20.0.0/14 \
  --cp-reach onhost \
  --cp-source <control plane private IP>/32 \
  --mgmt-allow <control plane private IP>/32,<operator IP>/32 \
  --ula-underlay none \
  --rates-from hetzner-fsn1
```

Azure: the same, with `--name byoh-azure-<region>`, `--ui-name "Azure <region> (BYOH)"` and `--underlay <VNet address space>`.

- `--overlay` must not overlap the underlay. GCP auto-mode VPCs use 10.128.0.0/9, and the Azure portal defaults to 10.0.0.0/16, so 172.20.0.0/14 fits both.
- Restart `puma` and `respirate` so they load the copied rates, then `bundle exec bin/byoh-location show --location <name>`.
- Grant your project after creating the account (§3.10): `bundle exec bin/byoh-location grant --location <name> --project <pj… ubid>`.
- `--underlay` goes into `deny4` with `--cp-source` and `--mgmt-allow`. On GCP, list **every** subnet range of the VPC: with only the hosts subnet, VMs can still reach the VPC's other subnets.

The metadata services need no profile entry. The host egress table drops VM connections to 169.254.0.0/16 (GCP and Azure metadata at 169.254.169.254, which also covers `metadata.google.internal`), to 168.63.129.16 (Azure WireServer and Azure DNS, which is not link-local), and to `fd20:ce::254` (GCP IPv6 metadata) (9d85a6e3c, `rhizome/host/lib/byoh_egress_nat.rb`). This applies to forwarded VM traffic only. The host itself keeps using them, as its agents need.

### 3.6 Create the pool addresses and write pools.yaml

**GCP variant A: protocol forwarding (`routed` + `public`).** Per VM address (provider docs, UNVERIFIED here):

```bash
gcloud compute addresses create byoh-pool-1 --region=<region>
gcloud compute target-instances create byoh-data-1-ti --instance=byoh-data-1 --zone=<zone>
gcloud compute forwarding-rules create byoh-pool-1-fr \
  --load-balancing-scheme=EXTERNAL --region=<region> \
  --address=byoh-pool-1 --ip-protocol=L3_DEFAULT --ports=ALL \
  --target-instance=byoh-data-1-ti --target-instance-zone=<zone>
gcloud compute addresses describe byoh-pool-1 --region=<region> --format='value(address)'
```

The GCP overview says `L3_DEFAULT` forwards TCP, UDP, ICMP, ESP and more, and that the API requires all ports with it. The setup guide shows only a TCP/80 rule, so the combination above is UNVERIFIED. If it is refused, create one `TCP` and one `UDP` rule with `--ports=ALL` per address. ICMP and ESP are then not forwarded. One target instance serves every forwarding rule of the host.

```yaml
version: 2
uplink: ens4
ipv6_mode: ula
routed_networks:
  - cidr: <forwarding-rule IP 1>/32
    delivery: routed
    exposure: public
  - cidr: <forwarding-rule IP 2>/32
    delivery: routed
    exposure: public
```

GCP docs say a target-instance VM may open internet connections from the forwarding rule's IP, so VM egress keeps the VM's own address (C2). This is UNVERIFIED here.

**GCP variant B: alias range (`fabric` + `internal`).** Only after §3.2:

```bash
gcloud compute instances network-interfaces update byoh-data-1 --zone=<zone> \
  --aliases "<alias CIDR, e.g. 10.10.0.64/28>"
```

`--aliases` replaces the whole alias list, and a range from a secondary range is written `<range name>:<CIDR>` (provider docs).

```yaml
version: 2
uplink: ens4
ipv6_mode: ula
routed_networks:
  - cidr: <alias CIDR>
    delivery: fabric
    exposure: internal
```

`fabric` pools use every address of the block, by design. Add `reserve: [...]` only if GCP documents an address it keeps. Both variants can be in the same file.

**Azure (`fabric` + `nat`).** Per VM address, only after §3.2 (provider docs, UNVERIFIED here):

```bash
az network public-ip create -g <rg> -n byoh-pool-1-pip --sku Standard --version IPv4
az network nic ip-config create -g <rg> --nic-name <host NIC name> -n pool1 \
  --vnet-name <vnet> --subnet <hosts subnet> --private-ip-address <pool IP 1> \
  --public-ip-address byoh-pool-1-pip
az network public-ip show -g <rg> -n byoh-pool-1-pip --query ipAddress -o tsv
```

```yaml
version: 2
uplink: eth0
ipv6_mode: ula
routed_networks:
  - cidr: <pool IP 1>/32
    delivery: fabric
    exposure: nat
    external:
      <pool IP 1>: <Public IP 1>
  - cidr: <pool IP 2>/32
    delivery: fabric
    exposure: nat
    external:
      <pool IP 2>: <Public IP 2>
```

An ipconfig without a Public IP is a `fabric` + `internal` /32 instead.

Rules for both platforms ([POOL_OPERATIONS.md](../POOL_OPERATIONS.md) §1.3):
- The main IP is never inside a pool.
- IPv4 pools are /24 or smaller, with no host bits.
- A `nat` pool needs a globally routable external IP for every usable address.
- Placeholders from the documentation ranges (203.0.113.0/24 and similar) are refused.
- `uplink` is stored but not used.

### 3.7 Register the host

```bash
bundle exec bin/register-byoh-host \
  --location <location name> \
  --main-ip <host private IP> \
  --pool-file pools.yaml \
  --ssh-key ~/.ssh/byoh_data \
  --default-boot-image ubuntu-noble \
  --yes
```

`ubuntu-noble` is the default image for VMs created without `-b`. Add `--default-boot-image ubuntu-jammy` only if customers will pick jammy explicitly. Bring-up took about 4 minutes on a nested AWS VM and includes **one host reboot**. Watch the labels with `tail -f /tmp/respirate.log` and the state with `psql -U clover -d clover_test -c "SELECT allocation_state, os_version, total_cores, total_hugepages_1g FROM vm_host"` until `allocation_state` is `accepting` ([SETUP.md](../SETUP.md) §8). After the reboot, repeat the §3.2 checks.

### 3.8 Edge firewall

Allow **everything** to and from the pool addresses, including ESP for private networking. The customer firewall is enforced on the host (NETWORKING §6.1). Restrict only the host's management IP.

GCP (provider docs; ingress rules take `--destination-ranges`):

```bash
gcloud compute firewall-rules create byoh-pool-in --network=<vpc> --direction=INGRESS \
  --action=ALLOW --rules=all --source-ranges=0.0.0.0/0 \
  --destination-ranges=<forwarding-rule IP 1>/32,<forwarding-rule IP 2>/32 --target-tags=byoh-data
```

`byoh-host-ssh` (§3.1) is the only rule for the host's management IP. Check that no other rule (such as the `default` VPC's `default-allow-ssh`) opens it wider.

For variant B, the alias range needs to be allowed only from inside the VPC (`--source-ranges=<VPC CIDRs>`, `--destination-ranges=<alias CIDR>`).

Azure (the NSG sees the private address after Azure's NAT). Check that the NSG has no `default-allow-ssh` rule (§3.1):

```bash
az network nsg rule create -g <rg> --nsg-name byoh-data-nsg -n byoh-pool-in --priority 200 \
  --direction Inbound --access Allow --protocol '*' \
  --source-address-prefixes Internet --destination-address-prefixes <pool IP 1> <pool IP 2> \
  --destination-port-ranges '*'
az network nsg rule create -g <rg> --nsg-name byoh-data-nsg -n byoh-host-ssh --priority 210 \
  --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes <control plane private IP> <operator IP> \
  --destination-address-prefixes <host private IP> --destination-port-ranges 22
```

### 3.9 Verify the pools

```bash
bundle exec bin/byoh-pool verify --host vh...                           # 0 failed
ssh -i ~/.ssh/byoh_data root@<main IP> nft list table inet byoh_egress  # loaded
ssh -i ~/.ssh/byoh_data root@<main IP> ip -br -4 addr                   # only the main IP
```

`bundle exec bin/byoh-pool trace <IP>` shows which host, pool and VM an address belongs to.

### 3.10 Create VMs

As in [SETUP.md](../SETUP.md) §9:

```bash
ubi vm <location>/vm1 create -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"                # GCP A, Azure: internet IPv4
ubi vm <location>/vm2 create -e internal -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"    # GCP B: internal IPv4
ubi vm <location>/vm3 create -6 -b ubuntu-noble "$(cat ~/.ssh/id_ed25519.pub)"             # no IPv4, host NAT egress
```

An internet VM places only on a host with a free `public` or `nat` address, and an internal VM needs a free `internal` address. A GCP host with only variant B therefore takes no internet VMs.

### 3.11 Gate

Run `scripts/byoh/verify/m2-gate.sh` with the "other platforms" settings in [VERIFY.md](../VERIFY.md) §2.5:

| Setting | GCP | Azure |
|---|---|---|
| `GATE_VM_A_EXPOSURE` | `public` (variant A) | `nat` (default) |
| `GATE_IPV6_MODE` | `ula` | `ula` |
| `GATE_EXPECT_MONITOR` | `0` | `0` |
| G0 | the steps above, by hand | the steps above, by hand |
| G11 (remap) | Not applicable: `remap` is for `nat` pools. Test `add` and `remove --drain` of a forwarding-rule /32 instead. | Move the Public IP to the ipconfig in Azure first, then `bin/byoh-pool remap --host H --ip <pool IP> --external <new Public IP>`, then set `GATE_NEW_EXTERNAL=<new Public IP>` and run `g11` |
| G17 | delete the forwarding rules, target instance, addresses and VMs | delete the Public IPs, ipconfigs, NAT gateway and VMs |

A GCP site with only variant B has no VM-A or VM-D: run `m2-gate.sh g1 g2 g3 g4 g5 g7 g8 g9 g9b`, then G12-G15. G9 must show 169.254.169.254 blocked on both platforms. On Azure, also check by hand that `nc -w3 168.63.129.16 80` fails from a VM.

---

## 4. Problems and solutions

| # | Platform | Symptom | Cause | Fix |
|---|---|---|---|---|
| G1 | GCP | `bootstrap-data-plane.sh` stops: "/dev/kvm is missing" | Created without `--enable-nested-virtualization`, on E2/Arm/memory-optimized/AMD (not N4D), or the org policy `constraints/compute.disableNestedVirtualization` is enforced | Recreate on N2 or C3 with the flag. Ask the org admin about the policy. `bin/byoh-virt probe` (branch `no-kvm`) prints the same fix with the reason |
| G2 | GCP | VM SSH gives "Permission denied (publickey)", or `wait_sshable` passes but customers cannot log in; or VM create fails with "is a local address of this host" | The guest agent put the alias range or forwarding-rule IP into `table local` (C5) | §3.2. Then `ip route show table local` and `sudo ip route del local <range> dev ens4 table local` for each leftover (the agent tags them `proto 66`), and recreate the VM |
| G3 | GCP A | VM stuck at `wait_sshable` | `cp_reach: onhost` makes the control plane dial the forwarding-rule IP. Its traffic leaves through its own external IP or Cloud NAT, which the `byoh-pool-in` rule may not cover, or the control plane has no internet egress. | `nc -vz <forwarding-rule IP> 22` from the control plane. Give the control plane egress and allow its egress IP. |
| G4 | GCP A | Inbound works for TCP but not ping, or IPsec between hosts fails | Forwarding rules created with `--ip-protocol=TCP`/`UDP` instead of `L3_DEFAULT` | Recreate the rule with `L3_DEFAULT` if your project accepts it (§3.6) |
| G5 | GCP A | `gcloud compute forwarding-rules create` refuses the target | The rule and the target instance are in different regions, or the rule is global | Use a regional rule in the host's region, with `--target-instance-zone` |
| G6 | GCP B | Internal VM unreachable from the rest of the VPC | The alias range is not on the NIC (`--aliases` replaced the list), or the firewall does not allow the VPC to it | `gcloud compute instances describe byoh-data-1 --zone=<zone> --format='value(networkInterfaces[0].aliasIpRanges)'`; add a rule for the alias CIDR |
| G7 | GCP | Internal VM cannot reach other machines in the VPC | By design: the underlay (every VPC subnet, §3.5) is in `deny4`, so VM-opened connections into it are dropped | Expected (NETWORKING §6.5). There is no allow override today: `vm_egress_allow` (`--egress-allow`) is stored but nothing reads it (PLANNED). The only lever is to leave that range out of `--underlay`, `--cp-source` and `--mgmt-allow`. |
| G8 | GCP | Large transfers stall | Guest MTU above the 1460 path | Guests get 1400 through DHCP. Check that the guest image did not override it (`ip link` in the VM). |
| Z1 | Azure | `bootstrap-data-plane.sh` stops: "/dev/kvm is missing" | Trusted Launch on a size older than v5, or a size without nested virtualization (some AMD `as` sizes) | Recreate with `--security-type Standard` on a size that lists nested virtualization. The portal may switch the security type back when you change other Basics fields (Microsoft Q&A). B-series and A-series sizes have no nested virtualization; `bin/byoh-virt probe` (branch `no-kvm`) prints the fix for the size |
| Z2 | Azure | SSH to the VM reaches the host ("Permission denied (publickey)"), or VM create fails with "is a local address of this host" | cloud-init applied the secondary ipconfigs to `eth0`, often on the registration reboot | §3.2: the cloud-init drop-in, remove `addresses:` from the netplan, `ip addr del`, then recreate the VM |
| Z3 | Azure | PrepHost fails downloading cloud-hypervisor; boot images never download | No outbound access: VNet created after 2025-09-30 without a NAT gateway or Public IP | Attach a NAT gateway to the subnet, or a Public IP to the primary ipconfig |
| Z4 | Azure | VM shows its Public IP but inbound times out | The NSG rule names the Public IP instead of the private pool IP, or the Public IP is not associated with that ipconfig | NSG rules match the private address (§3.8); `az network nic ip-config list -g <rg> --nic-name <nic> -o table` |
| Z5 | Azure | VM egress fails for a `nat` VM | NIC IP forwarding off, and Azure drops the VM's source (UNVERIFIED whether `fabric` needs it) | `az network nic update ... --ip-forwarding true` |
| Z6 | Azure | A guest configured by hand to use Azure DNS (168.63.129.16) gets no answers | 168.63.129.16 is blocked for VMs (9d85a6e3c) | Expected. Keep the DHCP-provided resolver: the VM's dnsmasq forwards to public resolvers (NETWORKING §5.3). Site resolvers through the location's `dns_servers` are P2. |
| Z7 | Azure | Boot images or VM disks fill the disk, or VM disks vanish after a deallocate | Disks on the 30 GB-class default OS disk, or on the ephemeral resource disk | Larger `--os-disk-size-gb`. Mount managed data disks at `/var/storage/devices/<n>` **before** registration. Never use `/mnt`. |
| Z8 | Azure | Two interfaces with the same MAC (`eth0` and `enP…`) | Accelerated Networking adds a VF bonded under `hv_netvsc` | Usually harmless: the default route uses `eth0`, and the uplink MAC pin skips netplan entries keyed by `match`. Impact on BYOH is UNVERIFIED. If PrepHost fails around the netplan, recreate with `--accelerated-networking false`. |
| B1 | Both | LearnMemory fails "BUG: unexpected dmidecode unit" | Control-plane code before a0259a997 (LearnMemory is a control-plane prog, `prog/learn_memory.rb`) | Update the control-plane code and restart `respirate`; the strand retries. `install_rhizome` is not needed for this |
| B2 | Both | Host `unavailable` after a while | `bin/monitor` running against cloud disks without SMART | Stop the monitor (PLATFORMS.md F5) |
| B3 | Both | Strand stuck at `hardware_reset`, VMs shown "rebooting" | Admin "Hardware Reset" on a host without a BMC | Never click it here. A cloud console reset does not unstick the strand. Recovery (UNVERIFIED): [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) §8 |
| B4 | Both | "no space left on any eligible host" | No free address of the requested exposure (an internet VM on a GCP variant-B-only host), no `ubuntu-noble` image, or too few cores or hugepages | `bin/byoh-pool list --host vh...`; [SETUP.md](../SETUP.md) §11 |

Common problems that are not specific to GCP or Azure (bootstrap SSH, outbound internet, boot images, billing rates, `wait_sshable`) are in [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) and NETWORKING §11.

---

## 5. Status

**GCP: UNVERIFIED.** Nothing on this page has run on GCP. Known gaps:
- The C5 agent settings for protocol forwarding (`target_instance_ips`) are unverified.
- `L3_DEFAULT` with a target instance is unverified.
- No public IPv4 path exists for alias IPs.
- IPv6 is `ula` only until the /96 spike (P4).
- There is no terraform module yet (`terraform/gcp-byoh` is PLANNED, NETWORKING §14.7).

**Azure: UNVERIFIED.** Nothing on this page has run on Azure. Known gaps:
- Whether `fabric` pools need NIC IP forwarding is unknown.
- Accelerated Networking with BYOH is untested.
- IPv6 is `ula` only.
- There is no terraform module (`terraform/azure-byoh` is PLANNED).

Not run on either cloud (branch `no-kvm`, UNVERIFIED): the probe on GCP n2 with nested (NO_KVM.md §14 L1-T3) and on E2, Azure sizes with and without nested, and the PVM go/no-go on a GCP e2-standard-4 (L4-T1; it reported a GO on AWS m6i.large, NO_KVM.md §14) and the PVM tier end to end (L4-T2, branch `pvm-build`).

Code paths these pages rely on are covered by unit specs only (a0259a997, 9d85a6e3c, c73f96ddc, a092f1b8b, 105b6439b). The common flow (location, pools, registration, egress NAT, gate) is validated on AWS only.

Sources (provider docs, UNVERIFIED here): [GCP nested virtualization](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview), [enabling it](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/enabling), [GCP alias IP ranges](https://docs.cloud.google.com/vpc/docs/configure-alias-ip-ranges), [GCP guest agent](https://docs.cloud.google.com/compute/docs/images/manage-guest-agent), [GCP protocol forwarding](https://docs.cloud.google.com/load-balancing/docs/protocol-forwarding), [its setup](https://docs.cloud.google.com/load-balancing/docs/set-up-protocol-forwarding), [gcloud forwarding-rules create](https://docs.cloud.google.com/sdk/gcloud/reference/compute/forwarding-rules/create), [GCP metadata troubleshooting](https://docs.cloud.google.com/compute/docs/troubleshooting/troubleshoot-metadata-server), [Azure NIC settings and IP forwarding](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-network-interface), [Azure multiple IPs (CLI)](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/virtual-network-multiple-ip-addresses-cli), [Azure default outbound access](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access), [Azure nested virtualization Q&A](https://learn.microsoft.com/en-us/answers/a/1455869), [cloud-init Azure datasource](https://docs.cloud-init.io/en/latest/reference/datasources/azure.html), [WireServer CVE-2021-27075](https://intezer.com/?p=18365).
