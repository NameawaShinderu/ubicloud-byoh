# BYOH compute: capacity, tiers and the plan to get there

This page is for operators who run BYOH hosts and for developers who change the allocator, rhizome or billing.
It explains how CPU, memory and disk are booked today, why hosts look "full" long before the hardware is busy, and what we are changing.

**How to read the labels**

| Label | Meaning |
|---|---|
| [TODAY] | True on `byoh-driver` @ e6f5e328e. A `file:line` is given where the claim depends on code |
| [PLANNED Pn] | Not built yet. `Pn` is the phase in [Implementation phases](#12-implementation-phases-compute). Other pages call these **CMP-Pn**; [ROADMAP.md](ROADMAP.md) §3.4 maps them to milestones (P0 → M0/M1, P1 → M5, P2 → M9, P3 → M11, P4 → M12) |
| UNVERIFIED | Not checked on a real host. Each one names the GATE (test) that settles it |
| EXTERNAL | General KVM / cloud-hypervisor (CH) / Linux knowledge, not checked against this repo |

Line numbers drift. Re-read the file before relying on one.
See also: [NETWORKING.md](NETWORKING.md) (networking) · [ROADMAP.md](ROADMAP.md) (build order; the browser console, serial text only, is §4) · [PLATFORMS.md](PLATFORMS.md) (per-platform support, host preflight, fix groups F1-F10) · [QUICKSTART.md](QUICKSTART.md).

---

## 1. Why a 32 GiB host was "full" after 3 VMs [TODAY]

The limit is the accounting policy, not the hardware.
Example host: AWS m8i.2xlarge (8 threads, 4 cores, 32 GiB), nested virtualization.

| # | Cause | Code | Effect on the m8i host |
|---|---|---|---|
| 1 | 26 of 32 GiB are pinned as 1 GiB hugepages at boot | `prog/setup_hugepages.rb:14`: `total_mem_gib*42/43 - 5` = 31 − 5 = 26 | That memory can't be shared, ballooned or overcommitted (EXTERNAL: hugetlbfs) |
| 2 | Every VM takes hugepages 1:1 with its memory | `scheduling/allocator.rb:222,305,505` | 2× standard-2 = 16 pages |
| 3 | A new burstable slice books memory for the whole slice, not for the VM | `allocator.rb:84-94,484` (`memory_gib_for_vcpus(cpus.count)` = 2 threads × 4 = 8 GiB) | A 2 GiB burstable VM books 8 GiB and a whole core. 6 GiB is booked but unused |
| 4 | CPUs 0-1 are marked `spdk` on a host that has no SPDK, and are not counted in `used_cores` | `prog/vm/host_nexus.rb:158`, `model/vm_host.rb:173-178`; fixed upstream at `origin/main:prog/vm/host_nexus.rb:136-139` | "3 of 4 cores used" really means 3 of 3. A 4th slice raises `fail "failed to allocate cpus"` (`allocator.rb:519`). The rescue at `prog/vm/metal/nexus.rb:91-92` only matches "no space left", so the strand error-loops instead of waiting for capacity |
| 5 | Disks are reserved at full size, but they are sparse files that read the boot image in place | `allocator.rb:170-174,745-760`; `rhizome/host/lib/storage_volume.rb:654-663`; `model/metal/vm.rb:151` (`copy_on_read=false`) | 136 of 241 GiB "available" while `df` shows 4% used |
| 6 | Nothing measures real usage | `rhizome/host/lib/vm_stats.rb:17` (no memory); score uses reservations only (`allocator.rb:337-366`); `bin/monitor` is not started by the bootstrap | Placement is blind to what VMs actually use |

How to see it on a control plane (from `bin/pry`):

```ruby
h = VmHost.first
h.values.slice(:total_cores, :used_cores, :total_cpus, :total_hugepages_1g, :used_hugepages_1g, :accepts_slices)
StorageDevice.where(vm_host_id: h.id).select_map([:name, :total_storage_gib, :available_storage_gib])
VmHostCpu.where(vm_host_id: h.id).select_map([:cpu_number, :spdk, :vm_host_slice_id])
```

On the host, `ls -ls /var/storage/*/*/disk.raw`: the first column is the real allocated size.

---

## 2. Product tiers

| | **Dedicated** (`standard`, upstream path) | **Flexible** (`flexible`, new; BYOH default) | **Flexible-Burstable** (`flexible` + "CPU limit 50%") |
|---|---|---|---|
| Status | [TODAY] | [PLANNED P1] | [PLANNED P1] |
| For | Databases, latency-sensitive work. Postgres, K8s and runners keep using it | General purpose, web, dev/test | Idle or low-duty VMs, lowest price |
| Shapes | Catalog `standard-{2..60}`, 4 GiB per vCPU (`lib/option.rb:92-95`) | Free-form, see §3 | Free-form, vCPU 1-4 |
| Memory | 1 GiB hugepages, preallocated, never overcommitted | Shared memory (`shared=on`) + THP. Balloon only after GATE G1 | Same as Flexible |
| CPU placement | **Disjoint** cpuset slice (see note below) | One shared flex-pool cpuset per host | Same pool |
| CPU limits | `CPUQuota = vcpus×100%` | `CPUQuota = vcpus×100%` (hard cap), `CPUWeight = 100×vcpus` | `CPUQuota = vcpus×50%` + `cpu.max.burst` 50%, `CPUWeight = 50×vcpus` |
| CPU charged to the pool | Whole cores | `vcpus×100` cpu% | `vcpus×50` cpu% |
| Guest topology | Upstream SMT topology | `1:N:1:1` (1 thread per core), so any vCPU count works and the `BUG:` paths in `model/metal/vm.rb:36-62` are never reached | Same |
| Disk | Thin data layer; physical guard applies (§6) | Thin; physical guard applies | Same |
| IO limits | None (upstream) | Always on. Bandwidth `min(100·vcpus, 400)` MB/s, IOPS `min(1500·vcpus, 10000)`. Illustrative; final values from G3 | Half of Flexible |
| OOM priority | Protected (`OOMScoreAdjust=-500`) | Killable (`+300`) | Killed first (`+500`) |
| Stop | Keeps all reservations and billing (upstream) | Optional "stop and release" (§8) | Same |
| Billing | `VmVCpu` × vcpus (upstream) | `VmVCpu` + `VmMemory` (per GiB) + `VmStorage` (per GiB per disk) | Same types, lower rates |

**Dedicated is disjoint, not exclusive.** [TODAY] `rhizome/host/lib/slice_setup.rb:41,51` writes `AllowedCPUs` and sets `cpuset.cpus.partition=member`, not `root`.
- VM slices never overlap each other.
- Host daemons (`system.slice`), IRQs and vhost backends can still run on those CPUs.
- There is no per-vCPU pinning.
- Do not market it as "exclusive cores". Making slices partition roots is a [PLANNED P5] option, not a promise.

**Legacy burstable** (`burstable-1/2`) [TODAY]: existing VMs keep running on their hugepage slices.
[PLANNED P1] New burstable demand goes to Flexible-Burstable. The legacy family is hidden in the **option filter** (`helpers/vm.rb:182-186`), and its `VmVCpu` rate is **kept**:
- `create_billing_record` looks the rate up by family and location (`prog/vm/metal/nexus.rb:211`). Removing it would make every burstable create or recreate raise.
- Postgres hobby sizes map to burstable (`lib/option.rb:257-258`).

---

## 3. Sizing rules (Flexible and Flexible-Burstable) [PLANNED P1]

| Field | Rule |
|---|---|
| vCPU | Integer 1-32 (burstable 1-4), and at most the host's flex-pool threads |
| Memory | 512 MiB to 128 GiB in 256 MiB steps; 0.5-8 GiB per vCPU |
| Boot disk | 10-2000 GiB in 1 GiB steps, and at least the boot image size |
| Data disks | Up to 4, 10-2000 GiB each. One `VmStorage` billing record per disk (existing pattern, `prog/vm/metal/nexus.rb:215-223`) |
| Ceilings | `vcpus_max`, `memory_mib_max` stored at create (default = the shape). Unused until CPU hotplug ships, so VMs never need recreating for it |
| Balloon floor | `memory_min_mib`. **Before G1 passes: floor = memory (no balloon).** After G1: default 50% of memory, never below 512 MiB |
| Display name | `flexible-3c-6g`, `flexible-1c-512m` |

Dedicated stays catalog-only. Custom dedicated shapes would have to be 1 or an even vCPU count (SMT topology) and are not planned.

Legacy readers keep working because `memory_gib = ceil(memory_mib/1024)` is still written.

---

## 4. Memory semantics

### Dedicated [TODAY]
Hugetlb memory. Never ballooned or swapped, and not touched by flexible pressure.

### Flexible pool [PLANNED P1]
One pool per host, stored as a `vm_host_slice` row with `kind='flex_pool'`.

**Host reserve (corrected).** The original design subtracted only a flat 4 GiB. That 4 GiB was silently shared by zram, per-VM CH + backend RSS and host page cache, so at ratio 1.0 the host was already overcommitted at about 20 VMs. The pool now subtracts all of them:

| Term | Value | Source |
|---|---|---|
| `usable_gib` | `floor(total_mem_gib × 42/43)` | same safety ratio as `prog/setup_hugepages.rb:14` |
| `hugepage_target_1g` | 0 on profile `flexible` | §9 |
| `host_reserved_mem_gib` | 4 (resized after G0) | host daemons, page cache |
| `zram_max_mib` | `min(4096, 12% of RAM)` | zram can hold this much real RAM when full (conservative) |
| `vm_overhead_mib` | 128 per VM (G0 fallback value; measured in G0) | CH RSS + backend RSS, **charged per VM at admission** |

- `physical_memory_mib = (usable_gib − hugepage_target_1g − host_reserved_mem_gib) × 1024 − zram_max_mib`
- `total_memory_mib = floor(physical_memory_mib × mem_overcommit_ratio)`
- Each flex VM is charged `memory_mib + vm_overhead_mib` to `used_memory_mib` and `memory_min_mib + vm_overhead_mib` to `used_min_memory_mib`. Overhead is never overcommittable.
- On `mixed` hosts, each **dedicated** VM's `vm_overhead_mib` is charged to the pool too, because CH and backend RSS of hugepage VMs come out of non-hugepage memory.

**Admission invariants** (CHECK constraints + one guarded UPDATE):
1. Σ(`memory_mib` + overhead) ≤ `total_memory_mib` (the overcommitted cap).
2. Σ(`memory_min_mib` + overhead) ≤ `physical_memory_mib` (every floor physically fits).

**What invariant 2 does and does not guarantee.** It guarantees the floors fit in RAM. It does **not** yet guarantee that inflating balloons frees host memory. UNVERIFIED until G1:
- `deflate_on_oom` lets the guest take balloon pages back, overriding the controller.
- EXTERNAL: on `shared=on` memfd memory, freed pages only leave the host if CH punches holes (`MADV_REMOVE` / fallocate). `MADV_DONTNEED` alone keeps shmem resident, and the vhost-user backend maps the same memory and can fault pages back in.
- G1 must show `memory.current` drops **and** stays down while the backend does IO.
- Until G1 passes, `mem_overcommit_ratio` is pinned at 1.00 and floor = memory, so no claim of balloon relief is made.

### Ratio ladder [PLANNED]

| Stage | `mem_overcommit_ratio` |
|---|---|
| P1, before G1 | 1.00 |
| P3, G1 + G1b pass | 1.25 |
| 2 weeks of PSI/RSS data with no HostMemoryPressure page | 1.50 (maximum) |

Only admins change it (CHECK 1.0-2.0), through `bin/set-host-ratios` (§10). Every change is audited with `Clog`; a shrink below current use is refused by the CHECK.

### Reclaim ladder for flexible VMs

| Step | Mechanism | Status |
|---|---|---|
| 1 | Free-page reporting keeps RSS near the guest working set | [PLANNED P3], needs G1 |
| 2 | Host balloon controller inflates down to `memory_min` | [PLANNED P3], needs G1 |
| 3 | zram swap | [PLANNED P1] |
| 4 | Per-VM `MemoryMax`, so only the leaking VM dies | [PLANNED P1] **only if G2 passes** (see below) |
| 5 | Kernel OOM order: burstable (+500), flexible (+300), host daemons (0), dedicated CH (−500), vhost-block-backend (−900, last, because losing it kills the guest's disk) | [PLANNED P1] |

**`MemoryMax` and shmem charging.** EXTERNAL: shmem pages are charged to the cgroup that first faults them. If the backend faults guest pages first, they are charged to the backend's unit, not to the CH unit. Then:
- A per-VM `MemoryMax` on the CH unit doesn't bound that VM.
- With the backend at −900, the kernel picks another VM as victim.

Mitigation: backends stay **one unit per VM** (§5), so charge at least lands on the same VM's units. G2 decides whether `MemoryMax` goes on the CH unit, on CH + backend together, or not at all. If G2 fails, there is no per-VM `MemoryMax`, and safety rests on the corrected reserve above plus the OOM order and zram.

### Other memory facts
- **Soft live RAM** [PLANNED P3]: move the balloon target between `memory_min` and boot size while running. Above boot size needs virtio-mem [PLANNED P5, gated].
- **KSM: not available.** vhost-user disks force `shared=on`; KSM only merges private anonymous pages (EXTERNAL).
- **Honest limit:** overcommit only pays off when guests don't touch all their RAM. Guest page cache counts as used until the balloon reclaims it. The biggest lever is bigger hosts.

---

## 5. CPU semantics

### Dedicated [TODAY]
Slices come from the lowest free CPUs (`select_cpuset`, `allocator.rb:511-522`), whole cores, charged to `vm_host.used_cores`.

### Flex pool [PLANNED P1]

| Rule | Detail |
|---|---|
| Cpuset | Highest-numbered non-reserved CPUs, `cpuset.cpus.partition=member` |
| SMT siblings | Pair by `lscpu` core id. UNVERIFIED on m8i (N / N+4 numbering?). Ties to portability F4 |
| Pool size | `total_cpu_percent = pool_threads × 100 × cpu_overcommit_ratio`. The ratio is applied in exactly one place |
| VM charge | `cpu_percent_limit`: vcpus×100 (flexible), vcpus×50 (burstable). Release at `prog/vm/metal/nexus.rb:528` already subtracts `cpu_percent_limit`, unchanged |
| Host accounting | **Every core with a thread in the pool (or host-reserved) is added to `vm_host.used_cores`.** Otherwise the dedicated SQL filter (`allocator.rb:223`) admits hosts that `select_cpuset` then rejects, and `NoCapacity` shows wrong numbers |
| Ratio | `cpu_overcommit_ratio` 2.0 at P1, 3.0 after G3 + 2 weeks. CHECK 1.0-8.0 |

### Host CPU reservation (corrected)
- [PLANNED P0] Generic hosts without SPDK get `io_cpu_count = 0` (port of upstream IO-CPU accounting). This frees the 4th core for dedicated slices on m8i.
- [PLANNED P1] On the `flexible` and `mixed` profiles, `io_cpu_count = 0` would put host daemons, IRQs, control-plane sshd, `metrics-collector` and every backend on CPUs that are 2-3× overcommitted. So:
  - Hosts with **fewer than 16 threads keep 1 thread out of the flex pool** (`host_reserved_cpu_threads = 1`). Hosts with 16+ threads reserve 0.
  - G3 also measures sshd connect latency and `metrics-collector` lag under a noisy flex VM.

### vhost-block-backend CPU (corrected)
[TODAY] The backend runs in the VM's slice but outside the VM's `CPUQuota` (`storage_volume.rb:42,201`).

[PLANNED P1] For flexible VMs the earlier idea of one shared `ubicloud-flexio.slice` is dropped, for two reasons:
- **Slice names can't contain dashes.** `slice_setup.rb:31` fails with `"BUG: unit name cannot contain a dash"`. EXTERNAL: in systemd a dash means hierarchy, so `ubicloud-flexio.slice` would be a child of `ubicloud.slice`, not of the pool.
- **One shared IO slice lets one VM's IO starve every other VM's IO CPU.** Backend CPU would not be tied to the VM that causes it.

Instead:
- The pool slice is named without a dash: `flexpool.slice` (`model/vm_host_slice.rb:47` builds `name + ".slice"`).
- Each flexible VM's backend unit gets `Slice=flexpool.slice`, its own `CPUQuota` (illustrative `min(vcpus,4) × 50%`, sized in G3) and the IOPS limits.
- Backend CPU is accounted inside the pool and bounded per VM.
- The dedicated path is unchanged (upstream).

---

## 6. Storage

| Item | Status | Detail |
|---|---|---|
| Thin data layer | [TODAY] | Sparse `disk.raw`; shared boot image read in place |
| Full-size accounting | [TODAY] | `available_storage_gib` drops by the full disk size (`allocator.rb:745-760`) |
| `storage_device.overcommit_ratio` | [PLANNED P1] | `available_storage_gib` keeps its meaning (provisionable headroom) but against `total × ratio`. CHECK `available <= total` (`migrate/20240419_add_constratins_for_volume_device.rb:11`) becomes `available <= ceil(total × ratio)`. Allocator storage queries unchanged |
| Physical guard, **all tiers** | [PLANNED P1] | At admission: `physical_free_gib − 0.1 × request ≥ max(RESERVED_STORAGE_GIB, 15% of total)`. Applies to dedicated too, because dedicated volumes share the same `/var/storage` and could fill it |
| Ballast | [PLANNED P1] | Non-sparse `/var/storage/.ballast`, 2% of the device, created with `fallocate` at host prep |
| `LearnStorage` guard | [PLANNED P0] | Refuse to run if any `vm_storage_volume` references the device; its upsert overwrites reservations (`prog/learn_storage.rb:44-52`) |
| Disk resize | [PLANNED P3] | Cold grow only, no shrink. Needs G6 |

**Why the guard covers every tier.** The physical guard, the veto and the 85% freeze originally applied to flexible only, which let dedicated admissions (the "predictable" tier) fill the shared disk and cause ENOSPC. Alternative considered: keep ratio 1.0 for dedicated volumes with separate accounting. We chose the guard for all tiers because it needs one code path and no second counter.

### Storage ratio ladder

| Stage | Ratio |
|---|---|
| P1 default | 1.5 |
| G4 (disk-full drill) passes + 2 weeks | 2.0 |
| G5 (discard verified on ubiblk v0.4.2) | 3.0 |

UNVERIFIED / EXTERNAL: AES-XTS turns zeros the guest writes into allocated ciphertext, so without discard, disks only grow.

### Physical thresholds on `/var/storage` [PLANNED P1, complete in P2]

| Used | Action (all tiers) |
|---|---|
| 80% | Warning page (HostStorageWarn) |
| 85% | `placement_state='frozen'` for new VMs and disk grows |
| 92% | Critical page. Runbook: delete the ballast, then cold-move the largest thin VM |

---

## 7. Scheduling and capacity management

**Rule:** hard admission is always reservation-based (pools × ratios). Measured usage can only **veto** a host, never admit past the reservation.

### `Prog::Vm::HostUsageMonitor` [PLANNED P1 minimal, P2 full]
One strand per host, every 60 s.

**Data source (corrected).** It must **not** read `/home/rhizome/host/metrics/done`. Once `bin/monitor` runs (P2), `lib/metrics_target_methods.rb:65` deletes scraped files from `done/`, so the monitor would find it empty, treat data as stale and freeze the host after 30 min.
Instead it runs `curl -s localhost:9100/metrics` over the existing sshable and parses node_exporter text directly. UNVERIFIED: node_exporter's listen address on BYOH hosts, and that the `pressure` and `filesystem` collectors are on (EXTERNAL: on by default).

It writes:

| Column | Meaning |
|---|---|
| `vm_host.measured_mem_available_mib`, `measured_psi_mem_avg60`, `measured_psi_cpu_avg60`, `metrics_at` | Host health |
| `vm_host.score_offset` | Placement penalty |
| `vm_host.admission_blocked_reason`, `placement_state`, `placement_state_reason` | Rails |
| `storage_device.physical_free_gib`, `physical_at` | Physical guard |
| `vm_storage_volume.physical_used_gib` | Per-disk real usage (P2) |

### Veto
Host excluded if frozen, or if any of:
- `measured_mem_available_mib < host reserve + 25% of request` (flexible requests)
- PSI mem some avg60 > 10 (flexible requests)
- the physical-disk guard fails (**all tiers**)

### Stale data
| Age | Action |
|---|---|
| 10-30 min | Caps only, +0.5 score penalty (fail-open, bounded) |
| > 30 min | `placement_state='frozen'` (reason `stale`) for that host only, page `UsageMetricsStale`. Unfreezes automatically when data is fresh |

### Score [PLANNED P1]
- Upstream terms kept; per-pool utilization terms added.
- `score_offset = 2·psi_mem + 1·psi_cpu + 1·(1 − mem_avail/total) + 0.5·max(0, disk_phys_used − 0.6)`.
- The 0.72 target-utilization term (`config.rb:212`) is kept, so placement packs toward a target instead of filling one host.

### Other
- **`placement_state`**: `open` / `draining` / `frozen`. Set by operators or by rails (with a reason). [PLANNED P1]
- **`NoCapacity` page** names the blocking dimension: cores, hugepages, flex-cpu, flex-mem, storage-provisioned, storage-physical, `admission_blocked_reason`. [TODAY] it reports only `used_cores` (`prog/vm/metal/nexus.rb:104-105`). [PLANNED P0]
- **Rebalancing**: the monitor recommends flexible VMs to cold-move off hosts under sustained pressure; an admin runs the ported `MoveVm`. [PLANNED P4]. Automatic moves only after the maintenance-window port [PLANNED P5].

### Slice queries must filter on `kind` [PLANNED P1]
`select_existing_slice` filters only on `family` and `enabled`, and the `slice_utilization` CTE (`allocator.rb:200-208`) picks `is_shared: true` slices. Either could put legacy burstable VMs into the flex pool. **Every** legacy slice query, `destroy_slice` (`prog/vm/metal/nexus.rb:562-583`) and `verify_hugepages` (`host_nexus.rb:285-296`) gets an explicit `kind='vm'` filter, with a spec for each.

---

## 8. Stop and release [PLANNED P1]

Flexible VMs can be stopped with "release compute": CPU and RAM are freed, only storage is billed, and the VM is re-admitted on start.

**Stranding risk.** Storage is local, so a released VM can only start on the same host. If the host filled up meanwhile, it can't start, and there is no move until P4. Rules:

| Rule | Detail |
|---|---|
| Start has priority | While any released VM on a host is waiting to start, new flexible admissions on that host are vetoed (`admission_blocked_reason='released_vm_waiting'`) |
| Clear state | The VM shows "waiting for capacity" in UI/API with the blocking dimension; retried every 60 s; page after 30 min |
| Offer gate | "Stop and release" is not offered when the host's flex pool is above 80% committed (CPU or memory) |

---

## 9. Host capacity profiles and m8i numbers

| Profile | Hugepages | Use | Status |
|---|---|---|---|
| `dedicated` | Upstream formula | Default for non-generic hosts | [TODAY] (implicit) |
| `flexible` | 0 | Default for new BYOH registrations | [PLANNED P1] |
| `mixed` | N, rest flexible | Hosts serving both tiers | [PLANNED P1] |

Changing the profile needs a reboot and is refused if the new hugepage target is below `used_hugepages_1g`.

**Grub token bug (must fix first).** [TODAY] `prog/setup_hugepages.rb:16` *appends* `hugepages=…` (and the size tokens) every time it runs. A profile change would add a second token instead of replacing the first; which one the kernel uses is UNVERIFIED (portability #23 says the first stays in effect). [PLANNED P0] Write an idempotent `/etc/default/grub.d/90-ubicloud-hugepages.cfg` (portability F3) or strip old tokens before appending, with a spec.

### m8i.2xlarge, profile `flexible` (corrected numbers)

Inputs:
- Threads: 8, minus 1 host-reserved (§5) = **7 pool threads**. CPU pool = 1400% at ratio 2.0, 2100% at 3.0.
- Memory: usable 31 GiB − 4 GiB reserve = 27648 MiB, minus zram max 3932 MiB = **physical pool 23716 MiB (≈23.2 GiB)**. Each VM is also charged 128 MiB overhead.
- Storage: 241 GiB × 1.5 ≈ **361 GiB** provisionable, before the physical guard.

| Shape | Today | P1 (mem 1.0, cpu 2.0) | P3 (mem 1.25, cpu 2.0) | P3 (mem 1.5, cpu 3.0) |
|---|---|---|---|---|
| 2 vCPU / 8 GiB | 3 (standard-2) | 2 (memory) | 3 (memory) | 4 (memory) |
| 2 vCPU / 4 GiB | n/a | 5 (memory) | 7 (CPU and memory) | 8 (memory) |
| 1 vCPU / 2 GiB | 1 per 8 GiB slice | 10 (memory) | 13 (memory) | 16 (memory) |
| burstable 1 vCPU / 2 GiB | ~4 per slice/core | 10 (memory; CPU allows 28) | 13 | 16 |
| 1 vCPU / 1 GiB | n/a | 14 (CPU) | 14 (CPU) | 21 (CPU) |
| 1 vCPU / 512 MiB | n/a | 14 (CPU) | 14 (CPU) | 21 (CPU) |

Notes:
- The earlier design figures (6 / 13 / 16 in P1) ignored zram, per-VM overhead and the reserved thread. Specs must assert the corrected counts (5 / 10 / 14).
- The 2c/8g row is **worse** than today at P1. That is the honest cost of not pinning 26 GiB of hugepages while also reserving for zram and overhead. A host that only runs 8 GiB VMs should stay on `dedicated`.
- Storage: with 20 GiB boot disks, storage binds at 18 VMs (361 / 20); with 10 GiB disks it never binds in this table.

### Mixed example (`hugepage_target_1g=16`, 2 dedicated cores)
- 2× standard-2 on hugepages.
- Flex pool: (31 − 16 − 4) × 1024 − 3932 = 7332 MiB, minus 256 MiB overhead for the 2 dedicated VMs = 7076 MiB usable.
- Threads: 8 − 4 (dedicated) − 1 (reserved) = 3 pool threads = 600% at ratio 2.0.
- Fits 1× 2c/4g + 1× 1c/2g, or 3× 1c/2g. On a 32 GiB host, `mixed` is barely useful; it is meant for 128 GiB+ hosts.

---

## 10. Guardrails

| Area | Guardrail | Phase |
|---|---|---|
| Database | CHECK on every counter: slice `used<=total`, floors ≤ physical, storage ≤ total × ratio, ratios in range. Guarded UPDATEs that raise `NoSpaceLeft` on 0 rows | P1 |
| Drift | Nightly `bin/check-capacity-drift` compares `used_*` with per-VM sums; pages on drift | P2 |
| Ratio changes | `bin/set-host-ratios`: one transaction, `SELECT … FOR UPDATE` on the `vm_host` row then its `storage_device` rows (same order the allocator locks), refuses if `physical_at` is older than 5 min, recomputes pool totals (CHECK refuses shrink below use), adjusts `available += total × Δratio`, audits with `Clog` | P1 |
| Alerts | HostMemoryPressure, HostSwapActive, HostOOM, HostStorageWarn/Critical, UsageMetricsStale, FlexPoolNearFull, NoCapacity (by dimension) | P1-P2 |
| Alerts (balloon) | BalloonControllerDown (heartbeat), BalloonStuck | P3 |
| OOM | Kill detected from kernel log and `memory.events` in `perform_health_checks` (`model/vm_host.rb`, near the kernel-log scan at `:342-347`). VM marked `unavailable` so the nexus restarts it; HostOOM paged | P2 |
| Invoices | `lib/billing_rate.rb:47-48` prints `VmVCpu` as `"#{family}-#{amount} Virtual Machine"`, so flexible 3c/6g would read "flexible-3 Virtual Machine". Flexible families print `"3 vCPU (flexible)"`, plus a `VmMemory` line `"6 GiB memory"` and one line per disk | P1 |
| Quota | `helpers/vm.rb:91` uses `parsed_size.nil? ? 2`, so a custom shape is quota-checked as 2 vCPU. Fixed **in the same PR** as custom shapes (step 7 below) | P1 |
| Rollout | Flag `Config.flexible_tier_enabled`; per-host profile and ratios (1.0 = off); canary on the AWS host; soak rule below | P1 |

**Soak rule (corrected).** The P1 soak deliberately fills the host, which by design fires FlexPoolNearFull, NoCapacity and HostStorageWarn. "No pages" therefore counts only **P1 (critical) pages other than capacity-full pages**: HostOOM, HostMemoryPressure, HostStorageCritical, UsageMetricsStale, BalloonStuck, strand exceptions, I/O errors. A phase widens beyond the canary after **7 days with none of those**.

---

## 11. Feature matrix

| Feature | Today | Planned |
|---|---|---|
| Fixed catalog sizes | [TODAY] | Kept for Dedicated |
| Custom vCPU / RAM (MiB) / disk, up to 4 data disks | No | [PLANNED P1] |
| Memory billing; memory and storage quotas | No (`VmVCpu` only; `config/default_quotas.yml`) | [PLANNED P1] |
| Thin storage accounting + physical guard (all tiers) + ballast | No | [PLANNED P1]; alarms complete in P2 |
| Shared CPU pool + CPU overcommit | No (disjoint slices only) | [PLANNED P1] |
| Stop-and-release (flexible) | No; a stopped VM keeps everything | [PLANNED P1] |
| Per-VM usage metrics + customer graphs | No | [PLANNED P2] |
| OOM detection with auto-restart; drift checker | No | [PLANNED P2] |
| Balloon + free-page reporting + memory overcommit | No | [PLANNED P3], gated on G1/G1b |
| Soft live RAM | No | [PLANNED P3] |
| Cold resize CPU/RAM; cold disk grow | No (not upstream either) | [PLANNED P3]; disk needs G6 |
| Browser console (serial text only; no graphical console, CH has no display device) | `serial.log` on the host only | See [ROADMAP.md](ROADMAP.md) §4 (M1, M6, M11) |
| Templates / images; offline backups | Partial; needs ubiblk ≥ v0.4 (`config.rb:164` = v0.2.2) | [PLANNED P4] |
| Cold migration / host drain | No (upstream `MoveVm`) | [PLANNED P4] |
| Partition-root dedicated slices | No (`member`) | [PLANNED P5] option |
| CPU hotplug (`--cpus max=`) | No | [PLANNED P5] |
| Live RAM grow above boot size (virtio-mem) | No | [PLANNED P5], gated; vhost-user mem-table updates UNVERIFIED |
| KSM | Not possible on vhost-user `shared=on` (EXTERNAL) | Never |
| Cross-host live migration | CH doesn't migrate local block storage (EXTERNAL) | Not planned |

---

## 12. Implementation phases (compute)

**Rules for every phase**
- Each phase ships on its own.
- The dedicated path stays upstream-shaped; existing allocator specs pass untouched.
- **Coverage budget.** Upstream requires 100% line and 100% branch coverage per file (`spec/coverage_helper.rb`). Every `flexible_tier_enabled` check doubles the branches to cover, and flag-off code paths in steps 4-6 still need full specs. Budget roughly **+40% spec effort** on flagged steps, keep flag checks in as few places as possible (allocator entry, assemble, rhizome param), and run the full `rake` (coverage + frozen_spec) per PR, not only targeted specs. Phase 0 makes `rake` green first.

### Gates (run on a scratch VM on the AWS canary; a failed gate keeps its feature off)

| Gate | Check | Unlocks | If it fails |
|---|---|---|---|
| G0 | Per-VM overhead (CH RSS + backend RSS) at 1, 5, 10 VMs | Real `vm_overhead_mib`, `host_reserved_mem_gib` | Keep 4 GiB + 128 MiB/VM + zram max |
| G2 | Which cgroup is charged for shmem the backend faults; `MemoryMax` behaviour; guest OOM with deflate; host-pressure kill order | P1 per-VM `MemoryMax`; P3 systemd-oomd | No per-VM `MemoryMax`; rely on reserve, OOM order, zram |
| G3 | Noisy flex VM (`stress-ng --cpu` + fio at limits). Dedicated sysbench p99 moves ≤ 5%; other flex VM fair share ≤ 10%; sshd connect and `metrics-collector` lag stay normal | P1 IO and backend CPU limits; CPU ratio > 2.0 | Lower limits; ratio stays 2.0; reserve a 2nd thread |
| G4 | Fill `/var/storage` to 86% and 93%: freeze, pages, guest ENOSPC behaviour, ballast recovery | Storage ratio > 1.5 | Cap ratio at 1.2 |
| G1 / G1b | `shared=on` + balloon + free-page reporting lower `memory.current` **and it stays down while the backend does IO**; `fio --verify=crc32c` clean for 1 h of inflate/deflate; backend doesn't crash | P3 balloon; memory ratio > 1.0 | Flexible ships without balloon; ratio pinned at 1.0 |
| G5 | Guest `fstrim` lowers `st_blocks` of `disk.raw` (ubiblk v0.4.2) | Storage ratio 3.0 | Stay at 2.0 |
| G6 | Cold disk grow keeps data. Note: `storage_volume.rb:162-175` only *creates* encrypted metadata; there is **no** metadata-extension code yet, so G6 includes writing it | P3 disk grow | CPU/RAM resize only |

### Phase 0: correctness and immediate relief (~1 week, no new product surface)

| # | Change | Files | Spec |
|---|---|---|---|
| 1 | `display_size` returns `"#{family}-#{vcpus}c-#{mem}"` when no catalog match. Lands first; `serializers/vm.rb:10`, `views/vm/index.erb:23`, `views/vm/overview.erb:9` raise NoMethodError otherwise | `model/vm.rb:151-159` | `spec/model/vm_spec.rb` |
| 2 | Typed `Scheduling::Allocator::NoSpaceLeft` (port 0a8bb6324). `select_cpuset` raises it; nexus rescues the class; `Sequel::CheckConstraintViolation` in `update` re-raised as `NoSpaceLeft` (portability F2) | `allocator.rb:519`, `prog/vm/metal/nexus.rb:91` | 4-core host with 2 IO CPUs: 4th slice → NoSpaceLeft, not RuntimeError |
| 3 | IO-CPU accounting: port `origin/main:prog/vm/host_nexus.rb:133-139` and upstream migrations `20260831_add_io_to_vm_host_cpu.rb`, `20260831_backfill_vm_host_cpu_io.rb`. Generic override: `io_cpu_count = 0` when no `spdk_installations` **and** `accepts_slices` (`model/metal/vm.rb:126-131` pins backends to IO CPUs on non-slice hosts). Backfill migration `migrate/20261012000000_byoh_io_cpu.rb` for generic hosts with no slice on CPUs 0-1 | `prog/vm/host_nexus.rb`, `model/vm_host.rb` | host_nexus spec + migration spec. m8i: 4 usable cores |
| 4 | Right-size new burstable slices: `allocator.rb:484` → `memory_gib: @request.memory_gib`. Grow-on-reuse needs **three** changes: (a) SQL prefilter `allocator.rb:205-208,214-216` admits a slice short on memory if the host has free hugepages for the delta; (b) `VmHostSliceAllocation#is_valid` (`allocator.rb:429-435`) checks host hugepages for the delta instead of returning `true`; (c) one guarded UPDATE grows slice `total_memory_gib` and host `used_hugepages_1g`. Slices are grow-only; empty-slice destroy returns the grown total; `verify_hugepages` stays consistent | `scheduling/allocator.rb` | grow on reuse; prefilter admits; `is_valid` rejects when hugepages short; race into CHECK; destroy returns grown total |
| 5 | Upstream allocator ports: `score_offset` (050355d94), `RESERVED_STORAGE_GIB` (0c9ee067b), IPv4 LEFT join (8e295c4d2), CandidateHosts diagnostics (dc550c385), hugepage MemAvailable clamp + ≥ 2 GiB check (`origin/main:prog/setup_hugepages.rb:15-30`) | allocator, setup_hugepages | upstream specs |
| 6 | Idempotent grub hugepage tokens (drop-in file or strip-then-append) | `prog/setup_hugepages.rb:16` | run twice → one token |
| 7 | `LearnStorage` refuses if any `vm_storage_volume` references the device | `prog/learn_storage.rb` | spec |
| 8 | `NoCapacity` page lists every dimension | `prog/vm/metal/nexus.rb:104-105` | spec |

Rollout: deploy; check `vm_host.used_cores` and `io` rows on the AWS host; create/destroy ×20 with no counter drift.

### Phase 1: Flexible tier (~3 weeks; mem ratio 1.0, no balloon)

**Migrations**

`migrate/20261015000000_flexible_tier.rb`:

| Table | New columns |
|---|---|
| `vm_host` | `capacity_profile` (dedicated/flexible/mixed, default `dedicated`); `hugepage_target_1g int NULL`; `host_reserved_mem_gib int NOT NULL DEFAULT 4`; `host_reserved_cpu_threads int NOT NULL DEFAULT 0`; `vm_overhead_mib int NOT NULL DEFAULT 128`; `zram_max_mib int NOT NULL DEFAULT 0`; `mem_overcommit_ratio numeric(4,2) DEFAULT 1.0` (CHECK 1.0-2.0); `cpu_overcommit_ratio numeric(4,2) DEFAULT 2.0` (CHECK 1.0-8.0); `flex_cpu_count int NULL`; `placement_state` (open/draining/frozen); `placement_state_reason`; `admission_blocked_reason`; `measured_mem_available_mib`, `measured_psi_mem_avg60`, `measured_psi_cpu_avg60`, `metrics_at` |
| `vm_host_slice` | `kind text NOT NULL DEFAULT 'vm'` (CHECK vm/flex_pool); partial unique index, one `flex_pool` per host; `physical_memory_mib`, `total_memory_mib`, `used_memory_mib`, `used_min_memory_mib bigint DEFAULT 0`; CHECKs `used_memory_mib <= total_memory_mib`, `used_min_memory_mib <= physical_memory_mib`, both ≥ 0 |
| `vm` | `memory_backing text NOT NULL DEFAULT 'hugepages'`; `memory_mib`, `memory_min_mib`, `vcpus_max`, `memory_mib_max int NULL`; `compute_released_at timestamptz NULL` |

`memory_backing` is a column because the existing `hugepages:` flag lives only in the strand frame (`prog/vm/nexus.rb:13,172` → `prog/vm/metal/nexus.rb:177`) and the allocator rewrites `family` (`allocator.rb:292`).

`migrate/20261016000000_thin_storage.rb`: `storage_device.overcommit_ratio numeric(4,2) DEFAULT 1.0`, `physical_free_gib`, `physical_at`; swap the CHECK at `migrate/20240419_add_constratins_for_volume_device.rb:11` to `available_storage_gib <= ceil(total_storage_gib*overcommit_ratio)`; `vm_storage_volume.physical_used_gib numeric`.

**Control plane**

| Area | Change |
|---|---|
| `lib/option.rb` | `VmFamily` gains `memory_backing`, `custom_shape`; families `flexible` and `flexible-burstable` (UI: a "CPU limit 50%" toggle); `FlexibleLimits`; `Option.custom_vm_size(...)` with `cpu_percent_limit`, burst, `io_limits`, `vring_workers = [vcpus, 4].min` |
| `lib/validation.rb` | `validate_custom_vm_shape`; storage range check instead of `storage_size_options.include?` (`:99-105`); size bounds and 4-disk limit in `validate_storage_volumes` (`:145-164`) |
| `prog/vm/nexus.rb:4-110` | Assemble from a shape. **Reuse the existing `hugepages: false` parameter** (it already yields `shared=on` at `vm_setup.rb:790`); also persist `memory_backing`, memory and min. Validate the `VmMemory` rate |
| `model/metal/vm.rb` | `params_json` adds `mem_mib`, `oom_score_adj`, `memory_max` (only if G2); topology `"1:#{vcpus}:1:1"` for shared backing |
| `scheduling/allocator.rb` | `Request#flexible?`; flexible branch beside `:194-224` joining the `flex_pool` slice, filtering on cpu%, MiB (+overhead), floors, `placement_state='open'`, `admission_blocked_reason IS NULL`, veto, physical guard; no hugepage or `used_cores` debit per VM; skip family overwrite at `:292` and the `["standard"]` filter (`prog/vm/metal/nexus.rb:75`); `FlexPoolAllocation#update` guarded UPDATE → NoSpaceLeft on 0 rows; **`kind='vm'` on every legacy slice query**; **physical guard on the dedicated path too**; score terms |
| Host `used_cores` | Pool creation adds every core with a pool or host-reserved thread to `used_cores` |
| `model/vm_host_slice.rb:42` | `set_allowed_cpus(..., ratio: 1)` |
| `prog/vm/metal/nexus.rb` | Release (`:525-531`): flex pool → decrement MiB counters, cpu% unchanged; `destroy_slice` (`:562-583`) skips `flex_pool`; billing (`:203-249`) adds `VmMemory` with `amount = memory_mib/1024.0` (`numeric`, `migrate/20230805_billing_records.rb:12`); `stop_and_release` / `start_reallocate` labels with the §8 rules |
| `prog/setup_hugepages.rb` | `vm_host.hugepage_target_1g || formula`; target 0 writes `hugepages=0`; then create/resize the pool row and `flexpool.slice` |
| `verify_hugepages` | Accept 0; sum only `kind='vm'` slices |
| New `prog/setup_flex_host.rb` | Budded like SetupNodeExporter (`host_nexus.rb:125`): `shmem_enabled=advise` (persisted), zram `min(4 GiB, 12% RAM)` and record `zram_max_mib`, `vm.swappiness=10`, ballast |
| New `prog/vm/host_usage_monitor.rb` (minimal) | node_exporter over ssh (`localhost:9100`), MemAvailable, PSI, `/var/storage` free, stale/freeze rail, 80/85/92% pages |
| `lib/byoh_registration.rb` | Profile `flexible` by default; a real BYOH Location instead of `HETZNER_FSN1_ID` (`host_nexus.rb:6`) |
| Billing | `config/billing_rates.yml` rates for `VmVCpu`/`VmMemory`/`VmStorage` on the flexible families (flexible 2c/8g < standard-2); **keep the legacy burstable rate**; `lib/billing_rate.rb:43-84` invoice labels (§10); `lib/content_generator.rb:31-53` price display |
| Quotas | `config/default_quotas.yml`, `model/project.rb:152-176`: `VmMemoryGib`, `VmStorageGib`; `helpers/vm.rb:91-92` checks all three with the real vCPU count |
| Option filter | Hide legacy `burstable` on generic locations in `helpers/vm.rb:182-186` |
| UI / API / CLI | `helpers/vm.rb:23-112,182-196`, `views/vm/create.erb` (vCPU stepper, MiB slider, disk table, live price); `views/vm/overview.erb` "Stop and release"; `openapi/openapi.yml:1961-1966,3376-3398` (`vcpus`, `memory_mib`, `family`, `storage_volumes[]`, `POST /vm/{id}/stop {release_compute}`); `serializers/vm.rb`; `cli-commands/vm/post/create.rb` (`--vcpus --memory --family --disk`) |
| Admin | `bin/set-host-ratios` with the locking in §10 |

**Rhizome**

| File | Change (flexible only unless stated) |
|---|---|
| `rhizome/host/lib/vm_setup.rb:646-800` | `--memory size=#{mem_mib}M,shared=on,thp=on`; skip hugetlbfs mount (`:212-218`); unit `Slice=flexpool.slice`, `CPUQuota`, `CPUWeight`, `OOMScoreAdjust`, `MemoryMax` only if G2. Dedicated CH units get `-500` |
| `rhizome/host/lib/storage_volume.rb:201,255-275` | Backend `OOMScoreAdjust=-900` (all tiers). Flexible: `Slice=flexpool.slice`, per-backend `CPUQuota`, IOPS lines |
| `rhizome/host/lib/slice_setup.rb` | `flexpool` slice (no dash), `CPUWeight` support. The dash guard at `:31` stays |

**Specs** (in addition to each row above)
- `spec/scheduling/allocator_spec.rb`: m8i fixture asserting **5 / 10 / 14** (§9); pool full; veto; stale vs frozen; no hugepage debit; dedicated blocked by physical guard; legacy burstable never lands in the pool (`kind`); concurrent allocation hits the guarded UPDATE; release-symmetry property test (random allocate, stop-release, destroy → all counters back to 0).
- `spec/lib/option_spec.rb` (even-vCPU invariant for catalog only), `spec/lib/validation_spec.rb` (0, 1, 3, 33 vCPU; 256 MiB; disk below image; 5 disks).
- `spec/model/metal/vm_spec.rb`: topology for 3, 5, 7 vCPU.
- `spec/prog/vm/metal/nexus_spec.rb`: 3 billing records, pool never destroyed, stop-and-release priority and offer gate.
- `spec/prog/setup_hugepages_spec.rb` (target 0, mixed), `spec/prog/setup_flex_host_spec.rb`, `spec/prog/vm/host_usage_monitor_spec.rb` (fixture node_exporter text).
- `spec/lib/billing_rate_spec.rb` (labels), `spec/lib/invoice_generator_spec.rb`, quota specs, route/API specs.
- `rhizome/host/spec/vm_setup_spec.rb` (exact CH command and unit properties per tier), `slice_setup_spec.rb`, `storage_volume_spec.rb`; migration specs (constraint swap).

**Ten mergeable steps (Phase 0 + 1)**

| Step | Content | Customer effect |
|---|---|---|
| 1 | `display_size` fallback + NoSpaceLeft | None (safety) |
| 2 | IO-CPU port + generic `io_cpu_count=0` | m8i: 3 → 4 usable cores |
| 3 | Burstable right-size (all 3 grow-on-reuse changes) + upstream allocator ports + grub fix + LearnStorage guard | New burstable VMs book their own memory, not 8 GiB |
| 4 | Migrations + models + `bin/set-host-ratios` | None (flag off) |
| 5 | Allocator flexible branch, `kind` filters, pool `used_cores`, physical guard all tiers, release/destroy | None (flag off) |
| 6 | Rhizome: `flexpool.slice`, CH flags, unit properties, per-backend limits, setup-flex-host, hugepage profile | None (flag off) |
| 7 | Option, validation, assemble, topology `1:N:1:1`, **quota with real vCPU count** | None (flag off) |
| 8 | Billing (`VmMemory`, labels), memory/storage quotas, price display, option filter | None (flag off) |
| 9 | UI, API, CLI (shapes, MiB, multi-disk, stop-and-release) | Visible once flag is on |
| 10 | Minimal HostUsageMonitor + storage alarms + ballast, then canary cutover | Flag on for canary |

G0, G2, G3, G4 must pass between steps 6 and 10.

**Rollout on the live AWS host**
1. Deploy with `flexible_tier_enabled=false`, profile `dedicated`. Behaviour must not change.
2. Run G0, G2, G3, G4 on a scratch flexible test VM.
3. Cutover (one reboot via the HostNexus reboot path):

| | Option A (preferred if the 3 VMs are test VMs) | Option B (keeps the standard-2s) |
|---|---|---|
| Existing VMs | Delete or recreate all 3 | Recreate only burstable-1 as flexible |
| Profile | `flexible` (`hugepage_target_1g=0`) | `mixed` (`hugepage_target_1g=16`, `flex_cpu_count=4`) |
| Storage ratio | 1.5 | 1.5 |
| Check after | `verify_hugepages`; pool row ≈ 23716 MiB / 1400% | pool row ≈ 7332 MiB / 600% |

4. Enable the flag for the canary project.
5. Fill to §9 density (5× 2c/4g) and soak 72 h: no OOM, no I/O errors.
6. After 7 days with no non-capacity critical pages (§10), enable for the location.

### Phase 2: observability and safety (~2 weeks)
- `rhizome/host/bin/usage-probe` + timer: textfile collector for per-VM `memory.current`, `memory.stat`, `cpu.stat`, PSI, balloon size, per-volume `st_blocks`; `rhizome/host/bin/setup-node-exporter` gains `--collector.textfile.directory`.
- Full HostUsageMonitor: per-VM/per-volume columns, full `score_offset`, HostSwapActive, FlexPoolNearFull.
- `perform_health_checks`: OOM-kill scan → VM `unavailable` → HostOOM.
- `bin/check-capacity-drift` nightly.
- Start `bin/monitor` with `victoria_metrics_endpoint_override` (`config.rb:158`), dashboards only. Safe because HostUsageMonitor no longer reads `done/`.
- Customer usage graphs on `views/vm/overview.erb` (CPU %, RSS minus balloon, physical disk) via `VictoriaMetrics::Client#query_range` (`lib/victoria_metrics/client.rb:63`), following `routes/project/location/postgres.rb:634` (note: `:80` uses `query`, not `query_range`).
- CH 53.0 (port `origin/main:rhizome/host/lib/cloud_hypervisor.rb:127-131`) before the balloon work.
- Specs: probe parsing, OOM regex, drift checker, graph route.

### Phase 3: balloon, overcommit, resize (~3 weeks; needs G1, G1b, G6)
- `rhizome/host/bin/balloon-controller` + unit, 5 s loop; policy is a pure function (inflate proportional to `memory.current − min`, ≤ 256 MiB steps; deflate when relaxed); drives `ch-remote resize --balloon`; heartbeat + `.prom`. Set up by `prog/setup_balloon_controller.rb`.
- `vm_setup.rb`: `--balloon size=0,deflate_on_oom=on,free_page_reporting=on` for flexible.
- `memory_min_mib` default → 50%; canary ratio 1.25; 1.5 after 2 weeks of PSI data.
- systemd-oomd on `flexpool.slice` only, if G2 passes.
- Alerts BalloonStuck, BalloonControllerDown.
- Soft live RAM: `POST /vm/{id}/memory-target`.
- `prog/vm/metal/resize.rb` + `setup-vm reconfigure` (modelled on `vm_setup.rb:70-96`): stop → one transaction (delta accounting on the same host, `vm` columns, finalize old and create new billing records) → rewrite unit → disk grow (`truncate` + new ubiblk metadata extension, G6) → start. Capacity failure raises NoSpaceLeft and keeps the old shape. Spec: crash re-entry at every label.
- The serial/browser console moved to [ROADMAP.md](ROADMAP.md) §4 (console phase C3 ships in the same milestone, M11).

### Phase 4: Proxmox-style operations
- ubiblk v0.4.2 (`config.rb:164` → `origin/main:config.rb:182`, SHA in `rhizome/host/lib/vhost_block_backend.rb:8-15`, v2 TOML).
- Machine images and templates (port `origin/main:prog/machine_image/version_metal_nexus.rb`, MinIO store); offline scheduled backups.
- `MoveVm` + `RemoteStorageServer`, passing explicit `vcpus`, `memory_mib`, `memory_backing` instead of `display_size`. Also gives stranded released VMs (§8) a way out.
- Rebalance recommendations page.
- G5, then storage ratio 3.0.

### Phase 5: gated extras
- CPU hotplug using `vcpus_max`.
- virtio-mem after a vhost-user mem-table test.
- Partition-root dedicated slices (true exclusive cores), if a customer needs it.
- Automatic maintenance-window moves after the `20260914_vm_maintenance_period` port.
