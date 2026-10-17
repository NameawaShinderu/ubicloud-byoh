# BYOH recipes

A recipe is the platform-specific part of a BYOH deployment, and nothing
else. Each one produces two things:

1. a **data-plane machine**: Ubuntu 24.04, one uplink address,
   outbound internet, a login you can `sudo` from, and KVM if at all
   possible (without it, one of the experimental `container`, `pvm` or
   `emulated` tiers: [../README.md](../README.md) §2,
   [QUICKSTART.md](../QUICKSTART.md) §5);
2. a **`pools.yaml`** that says which addresses VMs get and how they
   reach the machine ([POOL_OPERATIONS.md](../POOL_OPERATIONS.md) §1).

Then every platform runs the **same three commands** (ROADMAP §6.1 D7).
Nothing in the driver reads which recipe you used.

| Recipe | Machine | Pools | Status |
|---|---|---|---|
| [aws.md](aws.md) | EC2 nested-virtualization instance from `terraform/aws-byoh` | `fabric` + `nat` (ENI secondary IPs with EIPs), optional `fabric` + `internal` | Register path validated 2026-10; `host add` passed on AWS (G-M4-1, 2026-10-16) |
| [proxmox.md](proxmox.md) | A Proxmox VE guest VM (`--cpu host`) | `onlink` + `internal`, `onlink` + `nat` (pfSense 1:1), or `routed` via a static route | UNVERIFIED |
| [bare-metal.md](bare-metal.md) | A rented or owned physical server | `routed` + `public` (a routed block) | UNVERIFIED |
| [homelab.md](homelab.md) | A desktop or mini PC behind a home or office router | `onlink` + `internal`, or `routed` via a router static route | UNVERIFIED |

More platforms (GCP, Azure, OCI, colo, other hypervisors) are described
in [platforms/](../platforms/README.md); they end in the same three
commands.

---

## The three commands

On the control plane. `<...>` are your values.

```bash
# 1. Control plane, once (docs/byoh/INSTALL.md). From a clone of the repository:
sudo bash ~/ubicloud/scripts/byoh/install.sh --version v0.1.0 --source-git ~/ubicloud --ref HEAD \
  --url https://cloud.example.com --tls acme --admin-email ops@example.com --backup-recipient age1...

# 2. Site, once per site (a BYOH location: network profile, billing rates, access)
sudo ubicloud-admin site add <site> --display "<name customers see>" \
  --underlay <site CIDRs> --overlay 172.20.0.0/14 --cp-reach onhost|public \
  --cp-source <control plane IP as the site sees it>/32 --mgmt-allow <admin CIDRs> \
  --rates-from hetzner-fsn1

# 3. Host, once per machine
sudo ubicloud-admin host add --site <site> --ssh <user>@<host main IP> \
  --ssh-key <your login key> --pool-file pools.yaml
```

What `host add` does, in order ([OPERATIONS.md](../OPERATIONS.md) §4.2a,
`lib/byoh_host_add.rb`):

1. Checks the site, the pools and the control plane's own services.
2. Logs in as you, runs host preflight (PF1-PF21, [PLATFORMS.md](../PLATFORMS.md) §6) read-only, and reads the host's SSH host keys.
3. Shows what it will change and the host key fingerprints, and asks for a typed `yes` (or `--yes`, or `--expect-host-key SHA256:...`).
4. Installs its own root key, and allows root key login in sshd only if it is not already allowed.
5. Logs in as root with that key, pinned to the host keys it read (PF2).
6. Formats each `--storage-disk` (optional).
7. Registers the host and follows the bring-up (one reboot) until it accepts VMs, then runs `pool verify`.

Exit status: 0 when the host accepts VMs and `pool verify` has no FAIL;
1 a validation, preflight, host-key or SSH failure, or the host was
destroyed while it was being watched; 2 a usage error; 3 a
timeout, respirate not running, or a host outside its bring-up; 4 `pool
verify` failed; 130 interrupted. Running the same command again resumes;
it never registers a host twice ([TROUBLESHOOTING.md](../TROUBLESHOOTING.md) §2.3).

Useful extras:

- `sudo ubicloud-admin host preflight --site <site> --ssh ... --ssh-key ... --pool-file pools.yaml` runs step 2 alone and changes nothing.
- `--accept-check PF8-hybrid` (and `PF10-btrfs`, `PF16-docker`, `PF16-ufw`, `PF16-tailscaled`, `PF16-k3s`, `PF16-libvirtd`) accepts a failed check that is a choice rather than a defect. No other check can be accepted.
- `--storage-disk <by-id name>` formats a blank extra disk for VM storage. Host preflight's PF11 line names the blank disks it sees.
- `--registration-key FILE` gives `host add` the root key to install (unencrypted OpenSSH Ed25519) instead of generating one that lives only in the database. Keep it if you want to log in as root yourself or run `scripts/byoh/verify/m2-gate.sh` (`GATE_HOST_KEY`).
- `--uplink-ip IP` names the uplink address when the host has more than one default route.
- `--default-boot-image NAME` (repeatable) replaces the default, `ubuntu-noble`.
- `sudo ubicloud-admin host watch <host>` follows a bring-up again after Ctrl-C; the bring-up itself never stops.

On a **development control plane** (`bootstrap-dev-ctrl-plane.sh`, no
`/etc/ubicloud`), run the checkout's `packaging/bin/ubicloud-admin --dev`
from `~/ubicloud` without `sudo`, in place of `sudo ubicloud-admin`. It
restarts nothing: restart `puma` and `respirate` yourself after
`site add` ([OPERATIONS.md](../OPERATIONS.md) §4.2a).

`bin/register-byoh-host` stays as the low-level path, for a host whose
root login you have already set up ([SETUP.md](../SETUP.md) §8.2).

---

## What every recipe must give you

| Need | Why | Checked by |
|---|---|---|
| Ubuntu 24.04, x86_64 or aarch64 | LearnOs; only 24.04 takes VM slices | PF1 |
| A login with passwordless `sudo` (`ubuntu` on cloud images) | `host add` runs preflight and installs its root key through it | `host add` step 2 |
| `/dev/kvm` from real VT-x/AMD-V or nested virtualization, and a host-passthrough CPU model (`kvm` tier) | No KVM, no standard VMs (only the experimental `container`, `pvm` or `emulated` tiers of [NO_KVM.md](../NO_KVM.md), with `--virt-tier` and `--accept-fallback`, plus `--install-pvm-kernel` for `pvm`); a kvm64-class model hides `vmx`/`svm` and the CPU features x86-64-v2 guests need | PF3, never acceptable |
| At least 2 online CPUs and about 16 GiB of memory | Hugepages and host CPUs | PF-min-cpu, PF7 |
| `/var/storage` on ext4 or xfs | btrfs is UNVERIFIED (`PF10-btrfs`), ZFS is refused | PF10 |
| Exactly one IPv4 default route, and only the main IP on the uplink | Pool addresses on the host's own NIC steal VM traffic (contract C5) | PF17 |
| No pool containing the uplink IP, the main IP or the default gateway | The host would hand its own address to a VM | PF17, never acceptable |
| Outbound HTTPS to GitHub release downloads and the Ubuntu image mirrors, and HTTP to `cloud-images-archive.ubuntu.com` | PrepHost and boot image downloads | PF15 |
| A dedicated machine, not a hypervisor node, with no `rhizome` user | Bring-up deletes and recreates `rhizome`, disables SSH password logins, replaces the nftables ruleset and reboots | PF16-pve, PF16-rhizome-user, never acceptable |
| SSH (TCP 22) from the control plane to the main IP | Every host action is SSH (contract C0) | PF2 |

Keep recipe defaults apart: `terraform/aws-byoh` uses `10.98.0.0/16`,
[NETWORKING.md](../NETWORKING.md) §9.2 (an existing company LAN) uses
`10.80.0.0/24`, and the Proxmox recipe here uses `10.77.0.0/24`, so one
control plane can manage all three sites without overlapping underlays.
