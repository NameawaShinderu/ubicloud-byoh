#!/usr/bin/env bash
# L4-T1: the PVM go/no-go test (docs/byoh/NO_KVM.md sections 6.7 and 14).
#
# Answers one question on real hardware: does a PVM guest kernel boot
# under stock Cloud Hypervisor (v46 and v53, the versions rhizome pins)
# on a cloud VM WITHOUT hardware virtualization? The lab could only show
# the host side (kvm_pvm loads and /dev/kvm appears under QEMU TCG); the
# guest never printed there. Until this script reports GO, the `pvm` tier
# stays "detected, not offered": registration refuses it.
#
# Run it ONLY on a throwaway Ubuntu 24.04 x86_64 VM that you can
# power-cycle from the provider console, with Secure Boot off and no
# nested virtualization (for example GCP e2-standard-4 or AWS m6i.large).
# Never on a registered host or anything you care about: it installs an
# out-of-tree kernel and boots it with pti=off. It refuses to do anything
# unless BYOH_REAL_HOST=1.
#
#   sudo BYOH_REAL_HOST=1 ./pvm-go-no-go.sh preflight   # read-only checks
#   sudo BYOH_REAL_HOST=1 ./pvm-go-no-go.sh install     # kernel, one-shot boot entry
#   sudo reboot                                         # boots the PVM kernel ONCE
#   sudo BYOH_REAL_HOST=1 ./pvm-go-no-go.sh boot-test   # CH v46 and v53 guests; GO/NO-GO
#   sudo reboot                                         # back to the stock kernel
#   sudo BYOH_REAL_HOST=1 ./pvm-go-no-go.sh recovery-check
#   sudo BYOH_REAL_HOST=1 ./pvm-go-no-go.sh uninstall   # optional
#
# Exit codes: 0 pass (boot-test: GO), 1 fail (boot-test: NO-GO),
# 2 refused or usage error.
#
# The boot is one-shot: install pins the running stock kernel as GRUB's
# saved default BEFORE the PVM .deb runs update-grub, then arms
# `grub-reboot ubicloud-pvm`. If the PVM kernel hangs, power-cycle the
# instance from the provider console: it returns to the stock kernel.
# install refuses to arm the reboot unless grub-editenv shows both the
# next_entry and the stock saved_entry.
#
# Report: $PVM_WORK/report.txt. Send it back with GO or NO-GO; WP7's build
# (docs/byoh/NO_KVM.md section 15) starts only on a GO.
#
# Environment (defaults in brackets):
#   PVM_WORK           state, downloads and logs [/var/lib/byoh-pvm-test]
#   PVM_RELEASE_URL    release with the host .deb, guest vmlinux, guest
#                      config and SHA256SUMS
#                      [https://github.com/cocoonstack/pvm/releases/download/v0.1.0]
#   PVM_HOST_DEB       [linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb]
#   PVM_GUEST_KERNEL   [vmlinux-pvm-amd64]
#   PVM_GUEST_CONFIG   [guest-pvm-amd64.config]
#   PVM_HOST_DEB_SHA256, PVM_GUEST_KERNEL_SHA256
#                      optional extra pins, checked on top of SHA256SUMS
#                      (use them for your own builds of virt-pvm)
#   PVM_IMAGE_URL      guest disk image (with SHA256SUMS beside it)
#                      [https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img]
#   PVM_BOOT_TIMEOUT   seconds per Cloud Hypervisor run [900]
#   PVM_ALLOW_HW_VIRT  1 = run although the CPU shows vmx/svm (the result
#                      then says nothing about the no-hardware case) [0]
#
# The release is a third-party build (docs/byoh/NO_KVM.md section 6.2):
# fine for a throwaway test, never a default for registered hosts.
#
# UNVERIFIED: this script has never run on a real host. Only its refusal
# without BYOH_REAL_HOST=1 and its preflight inside a container were
# executed (they refuse).

set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,/^# executed/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "${BYOH_REAL_HOST:-0}" != 1 ]; then
  echo "pvm-go-no-go: refusing: this installs a custom kernel and reboots into it." >&2
  echo "Run it only on a throwaway VM, with BYOH_REAL_HOST=1 (see the header of $0)." >&2
  exit 2
fi

PHASE=${1:-}
case "$PHASE" in
  preflight | install | boot-test | recovery-check | uninstall) ;;
  *)
    echo "usage: BYOH_REAL_HOST=1 $0 preflight|install|boot-test|recovery-check|uninstall" >&2
    exit 2
    ;;
esac

PVM_WORK=${PVM_WORK:-/var/lib/byoh-pvm-test}
PVM_RELEASE_URL=${PVM_RELEASE_URL:-https://github.com/cocoonstack/pvm/releases/download/v0.1.0}
PVM_HOST_DEB=${PVM_HOST_DEB:-linux-image-6.12.33-pvm_6.12.33+pvm.g91e9c9be4472_amd64.deb}
PVM_GUEST_KERNEL=${PVM_GUEST_KERNEL:-vmlinux-pvm-amd64}
PVM_GUEST_CONFIG=${PVM_GUEST_CONFIG:-guest-pvm-amd64.config}
PVM_IMAGE_URL=${PVM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
PVM_BOOT_TIMEOUT=${PVM_BOOT_TIMEOUT:-900}
PVM_ALLOW_HW_VIRT=${PVM_ALLOW_HW_VIRT:-0}

# The cloud-hypervisor-static sums rhizome pins (rhizome/host/lib/cloud_hypervisor.rb,
# prog/download_cloud_hypervisor.rb; spec/lib/byoh_virt_tiers_pvm_spec.rb keeps them equal).
CH_SHA256_46="00b5cf2976847d2f21d2b7266038c8fc40bd14f2a542115055e9e214867edc9e"
CH_SHA256_53="448af3d4e59b22c2987f7df94c213ad40fb53a10d437e42b5ee6c4fce7c29ecc"
CH_VERSIONS="46.0 53.0"

PVM_ENTRY_ID=ubicloud-pvm
GRUB_DROPIN=/etc/default/grub.d/98-byoh-pvm-test.cfg
GRUB_SCRIPT=/etc/grub.d/42_byoh_pvm_test
ART=$PVM_WORK/artifacts
STATE=$PVM_WORK/state
REPORT=$PVM_WORK/report.txt
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VIRT_PROBE=${PVM_VIRT_PROBE:-$SCRIPT_DIR/../../../../rhizome/host/lib/virt_probe.rb}

FAILS=0
ok() { echo "  ok    $*"; }
bad() {
  echo "  FAIL  $*"
  FAILS=$((FAILS + 1))
}
note() { echo "  note  $*"; }
# expect "what" "fix" command...: ok when the command succeeds, else FAIL.
expect() {
  local what=$1 fix=$2
  shift 2
  if "$@"; then ok "$what"; else bad "$fix"; fi
}
die() {
  echo "pvm-go-no-go: $*" >&2
  exit 1
}
report() { echo "$*" | tee -a "$REPORT"; }

# saved_entry and next_entry from grubenv; empty when unset.
grubenv_get() { grub-editenv list 2>/dev/null | sed -n "s/^$1=//p"; }

state_get() {
  if [ -f "$STATE" ]; then sed -n "s/^$1=//p" "$STATE" | tail -1; fi
}
state_set() {
  mkdir -p "$PVM_WORK"
  touch "$STATE"
  sed -i "/^$1=/d" "$STATE"
  echo "$1=$2" >>"$STATE"
}

fetch() { # url dest
  [ -s "$2" ] || curl -fL --retry 3 -o "$2.part" "$1"
  [ -s "$2.part" ] && mv "$2.part" "$2"
  [ -s "$2" ] || die "download failed: $1"
}

# Every file must be listed in SHA256SUMS: `sha256sum -c --ignore-missing`
# alone passes when the file is not listed at all.
check_listed_sum() { # sums file
  local want got
  want=$(awk -v f="$2" '{n=$2; sub(/^\*/, "", n)} n == f {print $1}' "$1")
  [ -n "$want" ] || die "$2 is not listed in $(basename "$1")"
  got=$(sha256sum "$ART/$2" | cut -d' ' -f1)
  [ "$want" = "$got" ] || die "$2: sha256 $got, expected $want"
}

check_pin() { # file sha256-or-empty
  [ -z "$2" ] && return 0
  local got
  got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$2" ] || die "$(basename "$1"): sha256 $got, expected the pin $2"
}

secure_boot_on() {
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'
    return
  fi
  local v
  for v in /sys/firmware/efi/efivars/SecureBoot-*; do
    [ -e "$v" ] || return 1
    # 4 attribute bytes, then the value byte.
    [ "$(od -An -t u1 -j 4 -N 1 "$v" | tr -d ' ')" = 1 ]
    return
  done
  return 1
}

preflight() {
  FAILS=0
  echo "preflight (read-only):"
  expect "root" "run as root (sudo)" [ "$(id -u)" = 0 ]
  expect "x86_64" "PVM is x86_64 only, this is $(uname -m)" [ "$(uname -m)" = x86_64 ]
  expect "Ubuntu 24.04" "needs Ubuntu 24.04" grep -q '^VERSION_ID="24.04"' /etc/os-release
  if ! command -v systemd-detect-virt >/dev/null 2>&1; then
    bad "no systemd-detect-virt: cannot tell whether this is a container"
  elif systemd-detect-virt --container >/dev/null 2>&1; then
    bad "this is a container ($(systemd-detect-virt --container)); use a VM"
  elif [ -e /.dockerenv ] || [ -e /run/.containerenv ]; then
    bad "this is a container (/.dockerenv or /run/.containerenv); use a VM"
  else
    ok "not a container (systemd-detect-virt: $(systemd-detect-virt || true))"
  fi
  local hw
  hw=$(grep -cwE 'vmx|svm' /proc/cpuinfo || true)
  if [ "$hw" = 0 ]; then
    ok "no vmx/svm in /proc/cpuinfo"
  elif [ "$PVM_ALLOW_HW_VIRT" = 1 ]; then
    note "vmx/svm present; PVM_ALLOW_HW_VIRT=1, so a GO says nothing about hosts without hardware virtualization"
  else
    bad "vmx/svm present: this host has hardware virtualization; use L1 (or set PVM_ALLOW_HW_VIRT=1)"
  fi
  if [ "$(uname -r)" != "$(state_get kver)" ] && [ -e /dev/kvm ]; then
    bad "/dev/kvm exists on the stock kernel: KVM already works here (L1)"
  fi
  if secure_boot_on; then bad "Secure Boot is on: the PVM kernel is unsigned"; else ok "Secure Boot off"; fi
  local f
  for f in /etc/default/grub /etc/default/grub.d/*.cfg; do
    [ -f "$f" ] || continue
    if grep -qE '^GRUB_SAVEDEFAULT=["'\'']?true' "$f"; then
      bad "GRUB_SAVEDEFAULT=true in $f would make the PVM boot permanent"
    fi
  done
  for f in grub-editenv grub-reboot grub-set-default update-grub curl; do
    expect "$f" "missing $f" command -v "$f"
  done
  expect "/boot/grub/grub.cfg" "no /boot/grub/grub.cfg (GRUB is not the boot loader?)" [ -e /boot/grub/grub.cfg ]
  local melt
  melt=$(cat /sys/devices/system/cpu/vulnerabilities/meltdown 2>/dev/null || echo unknown)
  if [ "$melt" = "Not affected" ]; then
    ok "meltdown: Not affected"
  else
    note "meltdown: $melt. pti=off exposes host memory to guests: acceptable on this throwaway VM only; the product refuses such CPUs for PVM"
  fi
  local mem_kib avail_kib
  mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  expect "memory $((mem_kib / 1024)) MiB" "needs about 4 GiB of memory (2 GiB guest plus host)" [ "$mem_kib" -ge 3900000 ]
  mkdir -p "$PVM_WORK"
  avail_kib=$(df -Pk "$PVM_WORK" | awk 'NR == 2 {print $4}')
  expect "free disk $((avail_kib / 1024 / 1024)) GiB in $PVM_WORK" "needs about 8 GiB free in $PVM_WORK" [ "$avail_kib" -ge 8000000 ]
  [ "$FAILS" = 0 ]
}

stock_entry() {
  # The stock kernel's menu path, as update-grub wrote it.
  local title
  title="Ubuntu, with Linux $(uname -r)"
  grep -qF "menuentry '$title'" /boot/grub/grub.cfg || return 1
  if grep -q "^submenu 'Advanced options for Ubuntu'" /boot/grub/grub.cfg; then
    echo "Advanced options for Ubuntu>$title"
  else
    echo "$title"
  fi
}

# The drivers between each disk/NIC and the root of /sys/devices.
drivers_in_use() {
  local dev d
  for dev in /sys/class/net/*/device /sys/block/*/device; do
    [ -e "$dev" ] || continue
    d=$(readlink -f "$dev")
    while [ "$d" != /sys/devices ] && [ "$d" != / ]; do
      [ -e "$d/driver" ] && basename "$(readlink -f "$d/driver")"
      d=$(dirname "$d")
    done
  done | sort -u
}

# Does kernel $1 have driver $2, built in or as a module? The name is
# the sysfs driver name; a few differ from their module's name.
kernel_has_driver() {
  local kver=$1 drv m
  drv=$(echo "$2" | tr - _)
  case "$drv" in
    sd) drv=sd_mod ;;
    sr) drv=sr_mod ;;
  esac
  for m in "/lib/modules/$kver/modules.builtin" "/lib/modules/$kver/modules.dep"; do
    [ -f "$m" ] || continue
    if sed 's/:.*//' "$m" | sed 's,.*/,,; s/\.ko.*//' | tr - _ | grep -qx "$drv"; then
      return 0
    fi
  done
  return 1
}

install_phase() {
  preflight || die "preflight failed; nothing was changed"
  [ "$(uname -r)" != "$(state_get kver)" ] || die "already running the PVM kernel; run boot-test"
  : >"$REPORT"
  mkdir -p "$ART"

  echo "downloading $PVM_RELEASE_URL ..."
  local f
  for f in SHA256SUMS "$PVM_HOST_DEB" "$PVM_GUEST_KERNEL" "$PVM_GUEST_CONFIG"; do
    fetch "$PVM_RELEASE_URL/$f" "$ART/$f"
  done
  for f in "$PVM_HOST_DEB" "$PVM_GUEST_KERNEL" "$PVM_GUEST_CONFIG"; do
    check_listed_sum "$ART/SHA256SUMS" "$f"
  done
  check_pin "$ART/$PVM_HOST_DEB" "${PVM_HOST_DEB_SHA256:-}"
  check_pin "$ART/$PVM_GUEST_KERNEL" "${PVM_GUEST_KERNEL_SHA256:-}"

  # The guest kernel has no modules and no initramfs: rhizome's CIDATA
  # seed is vfat, and the image root is ext4 on virtio-blk.
  local c missing=""
  for c in VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1 PVM_GUEST X86_PIE VIRTIO_BLK VIRTIO_NET VIRTIO_PCI EXT4_FS SERIAL_8250_CONSOLE; do
    grep -qx "CONFIG_$c=y" "$ART/$PVM_GUEST_CONFIG" || missing="$missing $c"
  done
  [ -z "$missing" ] || die "guest kernel config lacks (=y):$missing"

  local pkg kver
  pkg=$(dpkg-deb -f "$ART/$PVM_HOST_DEB" Package)
  kver=${pkg#linux-image-}
  [ -n "$kver" ] && [ "$kver" != "$pkg" ] || die "$PVM_HOST_DEB is not a linux-image package ($pkg)"
  [ "$kver" != "$(uname -r)" ] || die "the running kernel is already $kver"

  # 1. Pin the running stock kernel before the .deb's update-grub runs:
  #    6.12-pvm sorts above noble's 6.8 and would become the top entry,
  #    which GRUB_DEFAULT=0 (or saved with no saved_entry) boots forever.
  echo 'GRUB_DEFAULT=saved' >"$GRUB_DROPIN"
  update-grub
  # shellcheck disable=SC2016 # a literal from grub.cfg
  grep -qF 'set default="${saved_entry}"' /boot/grub/grub.cfg || die "grub.cfg does not boot \${saved_entry}; check $GRUB_DROPIN is read"
  grep -q 'save_env next_entry' /boot/grub/grub.cfg || die "grub.cfg cannot clear next_entry (grubenv not writable here), so the boot would not be one-shot"
  local stock
  stock=$(stock_entry) || die "no grub entry for the running kernel $(uname -r)"
  grub-set-default "$stock"
  [ "$(grubenv_get saved_entry)" = "$stock" ] || die "saved_entry is not '$stock'"
  state_set stock "$stock"
  state_set stock_kver "$(uname -r)"
  state_set kver "$kver"
  state_set pkg "$pkg"

  # 2. The kernel, held so an apt upgrade never replaces it.
  apt-get install -y "$ART/$PVM_HOST_DEB"
  apt-mark hold "$pkg"
  [ -f "/boot/vmlinuz-$kver" ] || die "/boot/vmlinuz-$kver is missing after the install"
  [ -f "/boot/initrd.img-$kver" ] || die "/boot/initrd.img-$kver is missing after the install"
  [ "$(grubenv_get saved_entry)" = "$stock" ] || die "the .deb changed saved_entry; do not reboot"

  # 3. The PVM kernel must drive this instance's disks and NICs.
  #    A driver whose name maps to no module even in the running kernel
  #    (bus cores such as usb or pcieport) cannot be judged this way.
  local drv nodrv="" unmapped=""
  for drv in $(drivers_in_use); do
    if ! kernel_has_driver "$(uname -r)" "$drv"; then
      unmapped="$unmapped $drv"
    elif ! kernel_has_driver "$kver" "$drv"; then
      nodrv="$nodrv $drv"
    fi
  done
  [ -z "$nodrv" ] || die "kernel $kver lacks drivers this instance uses:$nodrv. Do not reboot into it; run uninstall."
  [ -z "$unmapped" ] || report "drivers not checked (no module of that name in either kernel):$unmapped"
  local rootfs
  rootfs=$(findmnt -no FSTYPE /)
  kernel_has_driver "$kver" "$rootfs" || die "kernel $kver lacks the root file system driver $rootfs"

  # 4. One entry carries pti=off; GRUB_CMDLINE_LINUX_DEFAULT stays as it is,
  #    so the stock recovery kernel keeps PTI.
  cat >"$GRUB_SCRIPT" <<EOF
#!/bin/sh
set -e
. /usr/share/grub/grub-mkconfig_lib
k=/boot/vmlinuz-$kver
[ -f "\$k" ] || exit 0
echo "menuentry 'Ubuntu, with Linux $kver (PVM go/no-go)' --id $PVM_ENTRY_ID {"
prepare_grub_to_access_device "\$(\${grub_probe} --target=device "\$k")" | sed 's/^/  /'
echo "  linux \$(make_system_path_relative_to_its_root "\$k") root=UUID=\${GRUB_DEVICE_UUID} ro \${GRUB_CMDLINE_LINUX} \${GRUB_CMDLINE_LINUX_DEFAULT} pti=off"
echo "  initrd \$(make_system_path_relative_to_its_root /boot/initrd.img-$kver)"
echo "}"
EOF
  chmod 755 "$GRUB_SCRIPT"
  update-grub
  [ "$(grep -c 'pti=off' /boot/grub/grub.cfg)" = 1 ] || die "pti=off must appear exactly once in grub.cfg"
  awk -v id="--id $PVM_ENTRY_ID" 'index($0, id) {e = 1} e && /pti=off/ {f = 1} e && /^}/ {e = 0} END {exit !f}' /boot/grub/grub.cfg ||
    die "pti=off is not in the $PVM_ENTRY_ID entry"
  grep -q "linux.*vmlinuz-$kver root=UUID=[0-9a-fA-F-]\{8,\} " /boot/grub/grub.cfg || die "the $PVM_ENTRY_ID entry has no root=UUID"
  grep -q 'pti=off' /proc/cmdline && die "the running stock kernel has pti=off; fix GRUB_CMDLINE_LINUX* first"

  # 5. Arm the one-shot boot and prove it.
  grub-reboot "$PVM_ENTRY_ID"
  [ "$(grubenv_get next_entry)" = "$PVM_ENTRY_ID" ] || die "next_entry is not $PVM_ENTRY_ID"
  [ "$(grubenv_get saved_entry)" = "$stock" ] || die "saved_entry is not the stock kernel"
  state_set armed "$(date -u +%FT%TZ)"

  report "installed $pkg; stock saved_entry: $stock"
  echo
  echo "Armed: the next boot (only) runs $kver with pti=off."
  echo "Now: sudo reboot, then: sudo BYOH_REAL_HOST=1 $0 boot-test"
  echo "If it does not come back within about 10 minutes, power-cycle the instance from the provider"
  echo "console: it returns to $(uname -r). That itself is a NO-GO for the host kernel on this platform."
}

# The same measurements on the host and in the guest: "name milliseconds".
write_bench() {
  cat >"$1" <<'EOF'
#!/bin/sh
ms() { echo $(($(date +%s%N) / 1000000)); }
run() {
  n=$1
  shift
  t0=$(ms)
  "$@" >/dev/null 2>&1
  echo "BYOH_PVM_BENCH $n $(($(ms) - t0))"
}
forks() { i=0; while [ $i -lt 2000 ]; do /bin/true; i=$((i + 1)); done; }
run cpu_sha256_1g sh -c 'dd if=/dev/zero bs=1M count=1024 | sha256sum'
run mem_dd_8g dd if=/dev/zero of=/dev/null bs=1M count=8192
run syscalls_400k dd if=/dev/zero of=/dev/null bs=1 count=200000
run fork_exec_2000 forks
d=${BENCH_DIR:-/var/tmp}
run disk_write_512m dd if=/dev/zero of="$d/byoh-pvm-bench" bs=1M count=512 oflag=direct
rm -f "$d/byoh-pvm-bench"
EOF
  chmod 755 "$1"
}

boot_test_phase() {
  local kver stock
  kver=$(state_get kver)
  stock=$(state_get stock)
  [ -n "$kver" ] || die "run install first"
  report "== boot-test $(date -u +%FT%TZ)"
  if [ "$(uname -r)" != "$kver" ]; then
    report "VERDICT: NO-GO (host): running $(uname -r), not $kver. If the instance needed a power cycle, the PVM host kernel did not boot here; save the provider's serial console log."
    exit 1
  fi
  report "host: $kver, cmdline: $(cat /proc/cmdline)"
  grep -qw 'pti=off' /proc/cmdline || die "pti=off is missing from /proc/cmdline"
  [ -z "$(grubenv_get next_entry)" ] || die "next_entry is still set; the boot was not one-shot"
  [ "$(grubenv_get saved_entry)" = "$stock" ] || die "saved_entry is no longer the stock kernel; a power cycle would not recover"
  report "one-shot: next_entry cleared, saved_entry still '$stock'"
  report "platform: $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) / $(cat /sys/class/dmi/id/product_name 2>/dev/null); cpu: $(sed -n 's/^model name\t*: //p' /proc/cpuinfo | head -1); vmx/svm: $(grep -cwE 'vmx|svm' /proc/cpuinfo || true)"

  modprobe -r kvm_intel kvm_amd 2>/dev/null || true
  modprobe kvm_pvm || die "modprobe kvm_pvm failed"
  [ -c /dev/kvm ] || die "/dev/kvm did not appear"
  report "/dev/kvm: $(stat -c '%A %U:%G %t,%T' /dev/kvm)"

  apt-get install -y ruby qemu-utils dosfstools mtools >/dev/null
  if [ -f "$VIRT_PROBE" ]; then
    local tier
    { cat "$VIRT_PROBE" && echo 'exit VirtProbe.main(ARGV)'; } | ruby - --json >"$PVM_WORK/virt-probe.json" || true
    tier=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["tier"]' "$PVM_WORK/virt-probe.json" 2>/dev/null || echo error)
    if [ "$tier" = pvm ]; then
      report "virt-probe: pvm (as expected)"
    else
      report "DETECTION MISMATCH: virt-probe says '$tier', expected pvm"
    fi
  else
    report "virt-probe: skipped ($VIRT_PROBE not found; copy the repo or set PVM_VIRT_PROBE)"
  fi

  local v sha
  for v in $CH_VERSIONS; do
    case $v in 46.0) sha=$CH_SHA256_46 ;; 53.0) sha=$CH_SHA256_53 ;; esac
    fetch "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v$v/cloud-hypervisor-static" "$ART/ch-$v"
    check_pin "$ART/ch-$v" "$sha"
    chmod 755 "$ART/ch-$v"
  done

  local img img_dir
  img=$(basename "$PVM_IMAGE_URL")
  img_dir=$(dirname "$PVM_IMAGE_URL")
  fetch "$PVM_IMAGE_URL" "$ART/$img"
  fetch "$img_dir/SHA256SUMS" "$ART/image-SHA256SUMS"
  check_listed_sum "$ART/image-SHA256SUMS" "$img"
  [ -s "$ART/base.raw" ] || qemu-img convert -O raw "$ART/$img" "$ART/base.raw"
  qemu-img resize -f raw "$ART/base.raw" 8G >/dev/null

  write_bench "$PVM_WORK/bench.sh"
  report "host bench:"
  BENCH_DIR=$PVM_WORK "$PVM_WORK/bench.sh" | tee "$PVM_WORK/bench-host.txt" | tee -a "$REPORT"

  local go=0
  for v in $CH_VERSIONS; do
    boot_guest "$v" && go=1
  done

  if [ "$go" = 1 ]; then
    report "VERDICT: GO (at least one Cloud Hypervisor version reached guest user space)"
  else
    report "VERDICT: NO-GO (no guest reached user space)"
  fi
  report "Next: sudo reboot (expect $(state_get stock_kver)), then: sudo BYOH_REAL_HOST=1 $0 recovery-check"
  echo "report: $REPORT"
  [ "$go" = 1 ]
}

# One guest under Cloud Hypervisor $1: direct kernel boot of the PVM
# vmlinux, the root on virtio-blk, a vfat CIDATA seed like rhizome's.
boot_guest() {
  local v=$1 dir=$PVM_WORK/guest-$1
  rm -rf "$dir"
  mkdir -p "$dir"
  cp --sparse=always "$ART/base.raw" "$dir/disk.raw"
  {
    echo '#cloud-config'
    echo 'password: ubuntu'
    echo 'chpasswd: {expire: false}'
    echo 'ssh_pwauth: false'
    echo 'write_files:'
    echo '  - path: /usr/local/sbin/byoh-pvm-bench'
    echo "    permissions: '0755'"
    echo '    content: |'
    sed 's/^/      /' "$PVM_WORK/bench.sh"
    echo 'runcmd:'
    echo "  - [sh, -c, 'exec >/dev/ttyS0 2>&1; echo BYOH_PVM_GUEST_UP \$(uname -r); dmesg | grep -i pvm | head -20; /usr/local/sbin/byoh-pvm-bench; echo BYOH_PVM_DONE; poweroff']"
  } >"$dir/user-data"
  printf 'instance-id: byoh-pvm-%s-%s\nlocal-hostname: byoh-pvm\n' "${v%%.*}" "$(date +%s)" >"$dir/meta-data"
  mkdosfs -n CIDATA -C "$dir/seed.img" 1024 >/dev/null
  mcopy -oi "$dir/seed.img" "$dir/user-data" "$dir/meta-data" ::

  report "== Cloud Hypervisor $v (timeout ${PVM_BOOT_TIMEOUT}s)"
  local t0 pid
  t0=$(date +%s)
  "$ART/ch-$v" -v --kernel "$ART/$PVM_GUEST_KERNEL" \
    --cmdline "console=ttyS0 root=/dev/vda1 rw" \
    --disk "path=$dir/disk.raw" "path=$dir/seed.img,readonly=on" \
    --serial "file=$dir/serial.log" --console off \
    --cpus boot=2 --memory size=2048M >"$dir/ch.log" 2>&1 &
  pid=$!
  local up="" login=""
  while kill -0 "$pid" 2>/dev/null; do
    if [ -z "$up" ] && grep -q BYOH_PVM_GUEST_UP "$dir/serial.log" 2>/dev/null; then up=$(($(date +%s) - t0)); fi
    if [ -z "$login" ] && grep -q 'login:' "$dir/serial.log" 2>/dev/null; then login=$(($(date +%s) - t0)); fi
    if grep -q BYOH_PVM_DONE "$dir/serial.log" 2>/dev/null; then
      sleep 30
      break
    fi
    if [ $(($(date +%s) - t0)) -ge "$PVM_BOOT_TIMEOUT" ]; then
      report "  timed out"
      break
    fi
    sleep 2
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -q BYOH_PVM_GUEST_UP "$dir/serial.log" 2>/dev/null && [ -z "$up" ] && up=$(($(date +%s) - t0))

  report "  serial bytes: $(stat -c %s "$dir/serial.log" 2>/dev/null || echo 0); login prompt: ${login:-never}s; user space: ${up:-never}s"
  grep -E 'BYOH_PVM_GUEST_UP|BYOH_PVM_BENCH|[Pp][Vv][Mm]' "$dir/serial.log" 2>/dev/null | head -40 | sed 's/^/  guest: /' | tee -a "$REPORT" || true
  if [ -n "$up" ]; then
    awk 'FNR == NR {h[$2] = $3; next} $1 == "BYOH_PVM_BENCH" && h[$2] > 0 {printf "  ratio %s: guest %d ms, host %d ms, guest at %.0f%% of host speed\n", $2, $3, h[$2], 100 * h[$2] / ($3 > 0 ? $3 : 1)}' \
      "$PVM_WORK/bench-host.txt" <(tr -d '\r' <"$dir/serial.log" | grep -o 'BYOH_PVM_BENCH.*') | tee -a "$REPORT"
    report "  CH $v: GO"
    return 0
  fi
  report "  CH $v: NO-GO. Last serial lines:"
  tail -n 30 "$dir/serial.log" 2>/dev/null | sed 's/^/    /' | tee -a "$REPORT" || true
  report "  CH log tail:"
  tail -n 15 "$dir/ch.log" | sed 's/^/    /' | tee -a "$REPORT"
  return 1
}

recovery_check_phase() {
  local kver stock_kver
  kver=$(state_get kver)
  stock_kver=$(state_get stock_kver)
  [ -n "$kver" ] || die "run install first"
  FAILS=0
  echo "recovery-check:"
  expect "running the stock kernel $stock_kver" "running $(uname -r), expected $stock_kver" [ "$(uname -r)" = "$stock_kver" ]
  expect "no pti=off" "pti=off on the stock kernel" sh -c "! grep -qw pti=off /proc/cmdline"
  expect "no next_entry" "next_entry is set" [ -z "$(grubenv_get next_entry)" ]
  local verdict=FAIL
  [ "$FAILS" != 0 ] || verdict=PASS
  report "recovery-check $(date -u +%FT%TZ): $verdict on $(uname -r)"
  [ "$FAILS" = 0 ]
}

uninstall_phase() {
  local kver pkg
  kver=$(state_get kver)
  pkg=$(state_get pkg)
  [ "$(uname -r)" != "$kver" ] || die "running the PVM kernel; reboot to the stock kernel first"
  rm -f "$GRUB_SCRIPT" "$GRUB_DROPIN"
  grub-editenv - unset next_entry
  if [ -n "$pkg" ] && dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-mark unhold "$pkg"
    apt-get purge -y "$pkg"
  fi
  update-grub
  grub-set-default 0
  echo "removed the PVM kernel and the grub changes; $PVM_WORK is kept (report: $REPORT)"
}

case "$PHASE" in
  preflight) preflight ;;
  install) install_phase ;;
  boot-test) boot_test_phase ;;
  recovery-check) recovery_check_phase ;;
  uninstall) uninstall_phase ;;
esac
