# AWS end-to-end run (M3, M4, no-KVM ladder, PVM tier)

One run proves on real machines what the lab could only approximate:
the packaged control plane (M3), one-command host add (M4) and the
virtualization ladder (docs/byoh/NO_KVM.md). Results go to
docs/byoh/VERIFY.md, section "Real-infrastructure runs".

The AWS account is shared with production. Everything here is tagged
`Project=ubicloud-byoh-test` and `E2E=<run>`, and `down.sh` touches
nothing else. The run reuses an existing VPC, subnet and key pair.

## Machines

| Role | Type | Why |
|---|---|---|
| ctrl | t3.large, EIP | M3 install.sh, production mode, ACME on `<eip>.sslip.io` |
| kvm | m8i.2xlarge, nested virtualization, +50 GiB EBS, 2 secondary IPs, 1 EIP | L1 KVM host; M4 host add, `--storage-disk`, E1 canary, M2 gate |
| ct | t3.xlarge (no nested), 1 secondary IP, 1 EIP | L2 detection on AWS; L3 system containers |
| emu | t3.xlarge (no nested; an emulated host needs 2 cores), 1 secondary IP | L5 emulated |
| pvm | m6i.large (no nested) | L4 PVM go/no-go, `scripts/byoh/test/real/pvm-go-no-go.sh` |
| pvme | m6i.2xlarge (no nested), +80 GiB root | L4 PVM tier end to end, `scripts/byoh/test/real/pvm-e2e.sh` (4 cores and 32 GiB: two pvm-2 VMs; an m6i.large fails `verify_tier_capacity`) |

Data planes take no traffic from the internet (no host_guard yet, M7);
they reach the internet out and are reached through the control plane.

## Settings

```bash
export E2E_RUN=e2e1 E2E_VPC=vpc-... E2E_SUBNET=subnet-... \
  E2E_KEY_NAME=... E2E_KEY=path/to/private_key E2E_OPERATOR_CIDR=203.0.113.7/32
scripts/byoh/test/aws-e2e/up.sh            # or: up.sh ctrl kvm
scripts/byoh/test/aws-e2e/ssh.sh kvm 'uname -r'
scripts/byoh/test/aws-e2e/down.sh          # everything of the run; or: down.sh pvm
```

State (instance ids and addresses) is in `var/aws-e2e/<run>/state`.

## Phases

1. **M3 control plane** (ctrl): clone the branch, `install.sh --rack-env
   production --tls acme --url https://<eip>.sslip.io`, then
   `ubicloud-admin status`, `bin/byoh-config-check`, `byoh-account`, a
   real `sudo reboot` (all services back, no tmux), backup then restore.
2. **M4 + E1 on the KVM host** (kvm): `scripts/byoh/verify/m4-e2.sh`
   (site add, host add --ssh with host-key confirm, `--storage-disk` on
   the extra EBS, watch to `accepting`), then a VM booted in production
   mode from the public image mirror (E1), then the M2 gate.
3. **Ladder detection** (ct, emu, pvm, kvm): `bin/byoh-virt probe` on
   each; expect kvm nested on kvm and "none, aws, move to m8i/c8i/r8i"
   with the fallbacks on the others (NO_KVM.md section 14, L1/L2).
4. **L3 containers** (ct): host add `--virt-tier auto --accept-fallback`,
   a container VM, the L3-T1 checks of NO_KVM.md section 14, speed.
5. **L5 emulated** (emu): host add `--virt-tier emulated`, a VM, SSH,
   DNS, egress, stop/start, delete.
6. **L4 PVM go/no-go** (pvm): preflight, install, reboot, boot-test,
   reboot, recovery-check; the verdict decides whether WP7 is built.
7. **L4 PVM tier end to end** (pvme, after the go/no-go's GO): on the
   control plane, from the repository root, `BYOH_REAL_E2E=1
   scripts/byoh/test/real/pvm-e2e.sh all` with `PVM_E2E_HOST_SSH=ubuntu@<pvme
   private IP>`, the e2e key, a personal access token (`UBI_TOKEN`,
   `UBI_URL=https://<eip>.sslip.io/cli`) and `PVM_E2E_PROJECT` (the
   script's header lists every setting). It stops at the first phase that
   fails and resumes from any phase. Its one MANUAL step, `power-cycle`,
   asks for `aws ec2 stop-instances` and `start-instances` of the pvme
   instance (`PVM_E2E_INSTANCE`). Phases of `pvm-e2e.sh`, in order:
   `location`, `neg-sha`, `host-add`, `patch-kernel`, `host-check`, `vm`,
   `prod-path`, `bench`, `lifecycle`, `host-reboot`, `oob-reboot`,
   `power-cycle`, `tenancy`, `guest-pin-rollout`, `refusals`,
   `stock-return`, `delete`, `billing`, `teardown`. The report is
   `var/pvm-e2e/pvm-e2e-report.txt` on the control plane; the default pins
   are the cocoonstack/pvm v0.1.0 example (third party; Januscape fix
   inclusion UNVERIFIED; for testing only, not a recommended production
   pin). `guest-pin-rollout` needs a second guest kernel build
   (`PVM_E2E_GUEST2_URL`, `PVM_E2E_GUEST2_SHA256`) and is reported NOT RUN
   without one, as is the second-project grant of `tenancy` without
   `PVM_E2E_PROJECT2`; the report's last block lists every check that did
   not run, so a run that skipped any never reads as all green. Leave
   `bin/monitor` off and `PVM_E2E_SET_CHECKUP` unset: `oob-reboot`,
   `power-cycle` and `stock-return` then test that the pvm host notices a
   boot it did not ask for by itself (its wait compares the boot id every
   5 minutes). `neg-sha` registers the instance twice in a scratch
   location (a wrong host-deb sha256, then a wrong guest kernel sha256),
   about 15 minutes each. `scripts/byoh/test/pvm-e2e-stubs.sh` runs the
   script against a fake world (no host) to check its flow before the
   real run.
8. **Teardown**: `down.sh`; nothing of the run is left.
