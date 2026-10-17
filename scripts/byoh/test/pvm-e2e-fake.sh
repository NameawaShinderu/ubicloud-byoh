#!/bin/bash
# A fake world for scripts/byoh/test/real/pvm-e2e.sh (run by
# pvm-e2e-stubs.sh): one script installed under the names admin, bundle,
# ubi, ssh, sleep and pgrep. It keeps a fake control plane, PVM host and
# VM as files in $FAKE and answers the commands the e2e script sends them
# the way the real ones answer on the happy path (or as the FAKE_* knobs
# below say). It never reaches a real host: everything is files.
#
# Knobs (environment): FAKE_ACCEPT_WRONG_GUEST=1 makes set take a wrong
# guest sha256; FAKE_NEG_CHANGES_GRUB=1 makes the refused install touch
# GRUB; FAKE_STOCK_RETURN_STARTS_VM=1 starts the VM on a stock boot.
set -uo pipefail

F=${FAKE:?}
GOOD_GUEST=84dcf08143ce7e945a770ff1b6d25e0505c1da69d674831b470cabc139598acb
STOCK=7.0.0-1014-aws
PVM=6.12.33-pvm
HOST=vh0000000000000000000000ab
NEG=vh0000000000000000000000cd
VM=vm0000000000000000000000ef
STOCK_ENTRY="Advanced options for Ubuntu>Ubuntu, with Linux $STOCK"

get() { cat "$F/$1" 2>/dev/null || true; }
put() { printf '%s' "$2" >"$F/$1"; }
has() { [[ -e $F/$1 ]]; }
page_add() { grep -qx "$1" "$F/pages" 2>/dev/null || echo "$1" >>"$F/pages"; }
page_del() { [[ -f $F/pages ]] && sed -i "/^$1 /d" "$F/pages"; }
log() { printf '%s\n' "$*" >>"$F/calls"; }

init() {
  [[ -e $F/init ]] && return
  mkdir -p "$F"
  put kernel "$STOCK"
  put boot 1
  put vmboot 1
  put next_entry ""
  put saved_entry ""
  put guest_pin "$GOOD_GUEST"
  put mem 30000000
  : >"$F/pages"
  touch "$F/init"
}
init

# The host boots: the PVM kernel when the next boot is armed, else stock.
# The boot unit re-arms the next boot on a PVM boot (D2).
host_boot() {
  put boot $(($(get boot) + 1))
  if [[ $(get next_entry) == ubicloud-pvm ]] && has installed; then
    put kernel "$PVM"
    put next_entry ubicloud-pvm
  else
    put kernel "$STOCK"
    put next_entry ""
  fi
  rm -f "$F/vm_running"
}

# HostNexus after a boot: on its PVM kernel back to work with the VM
# started; on stock, ByohPvmBoot and no VM.
host_settle() {
  if [[ $(get kernel) == "$PVM" ]]; then
    put label wait
    put alloc accepting
    page_del ByohPvmBoot
    has vm && touch "$F/vm_running" && put vmboot $(($(get vmboot) + 1))
  else
    put label pvm_boot_failed
    put alloc draining
    page_add "ByohPvmBoot $HOST booted its stock kernel $STOCK, not the PVM kernel $PVM"
    [[ ${FAKE_STOCK_RETURN_STARTS_VM:-0} == 0 ]] || touch "$F/vm_running"
  fi
}

cmd_admin() {
  log "admin $*"
  case "$1 $2" in
    "site show")
      has "site-$3" || exit 1
      echo "Location      $3"
      if has "pins-$3"; then
        echo "Virt tiers    kvm, pvm (L4, experimental)"
        echo "PVM pins"
        echo "  guest kernel $(get guest_pin)"
      else
        echo "Virt tiers    kvm"
      fi
      ;;
    "site add") touch "$F/site-$3" && echo "Created location $3" ;;
    "site rates") echo "Wrote 0 rates copied from $3/standard (x1.0) to /x/$3.yml." ;;
    "site set")
      local args=" ${*:4} "
      [[ $args != *" --visible "* ]] || { echo "! location $3 offers pvm to one project only, so it cannot be visible" && exit 1; }
      [[ $args != *" pvm:multitenant "* ]] || { echo "! pvm:multitenant is not available yet" && exit 1; }
      if [[ $args == *" --pvm-guest-kernel-sha256 "* ]]; then
        local sha
        sha=$(sed -n 's/.* --pvm-guest-kernel-sha256 \([0-9a-f]*\) .*/\1/p' <<<"$args")
        if [[ $args != *--no-verify-download* && $sha != "$GOOD_GUEST" && $sha != "${FAKE_GUEST2:-x}" && ${FAKE_ACCEPT_WRONG_GUEST:-0} == 0 ]]; then
          echo "! guest kernel: sha256 mismatch" && exit 1
        fi
        touch "$F/pins-$3"
        if [[ $sha == "${FAKE_GUEST2:-x}" ]]; then
          put guest_pin "$sha"
          touch "$F/guest2_ready"
          [[ $(get vm_sha) == "$sha" ]] || page_add "ByohPvmGuestKernelStale $HOST has 1 pvm VMs on an older guest kernel than $sha"
        fi
      fi
      echo "Updated location $3."
      ;;
    "site grant") [[ $5 != "${FAKE_PROJECT2:-x}" ]] || { echo "! location $3 offers pvm to one project only" && exit 1; } ;;
    "site delete") rm -f "$F/site-$3" && echo "Deleted location $3." ;;
    "host add")
      local args=" $* "
      if [[ $args == *" --site ${FAKE_SCRATCH:-x} "* ]]; then
        put neg_label pvm_install_failed
        [[ ${FAKE_NEG_CHANGES_GRUB:-0} == 0 ]] || put saved_entry "$STOCK_ENTRY"
        touch "$F/neg"
        echo "Registered host $NEG in site ${FAKE_SCRATCH}."
      else
        echo "Registered host $HOST in site $4."
        put saved_entry "$STOCK_ENTRY"
        touch "$F/installed" "$F/host"
        put next_entry ubicloud-pvm
        host_boot
        put pvm_state committed
        host_settle
        echo "Host $HOST accepts VMs."
      fi
      ;;
    *) echo "fake admin: unhandled $*" >&2 && exit 97 ;;
  esac
}

host_kv() {
  if [[ $1 == "$NEG" ]]; then
    if ! has neg; then echo exists=0 && return; fi
    printf 'exists=1\nlabel=%s\nallocation_state=draining\nvirt_tier=pvm\npvm_state=failed\n' "$(get neg_label)"
    echo "page=ByohPvmInstall $NEG refused to install the PVM host kernel: sha256 mismatch"
    return
  fi
  has host || { echo exists=0 && return; }
  printf 'exists=1\nlabel=%s\nallocation_state=%s\nvirt_tier=pvm\npvm_state=%s\n' "$(get label)" "$(get alloc)" "$(get pvm_state)"
  printf 'host_kver=%s\nstock_kver=%s\nstock_entry=%s\n' "$PVM" "$STOCK" "$STOCK_ENTRY"
  printf 'guest_kernels=%s:ready%s\n' "$GOOD_GUEST" "$(has guest2_ready && echo ",${FAKE_GUEST2}:ready")"
  sed 's/^/page=/' "$F/pages"
}

vm_kv() {
  if ! has vm; then
    printf 'exists=0\nguest_kernel_row=0\n'
  else
    printf 'exists=1\nfamily=pvm\nstate=running\nguest_sha256=%s\nguest_console=hvc0\n' "$(get vm_sha)"
  fi
  if has vm_created; then
    echo "billing=VmVCpu pvm $(has vm && echo "open $(get vm_created) -" || echo "closed $(get vm_created) $(get vm_deleted)")"
    echo "billing=VmStorage pvm $(has vm && echo "open $(get vm_created) -" || echo "closed $(get vm_created) $(get vm_deleted)")"
  fi
}

cmd_bundle() {
  shift # exec
  log "bundle $*"
  case "$1" in
    scripts/byoh/verify/m2-checks)
      case "$2" in
        pvm-host) host_kv "$4" ;;
        pvm-vm) vm_kv ;;
        info) printf 'host_ip=10.0.0.5\nprivate_ip4=172.20.0.2\ninhost=vmab12cd\n' ;;
        *) exit 97 ;;
      esac
      ;;
    bin/byoh-virt)
      case "$2 ${3:-}" in
        "show --host") echo "  kernel packages before patch: linux-image-$STOCK; after: linux-image-$STOCK linux-image-7.0.0-1015-aws" ;;
        "probe --main-ip") echo "tier: pvm (L4, experimental)" && exit 3 ;;
        "pvm retry")
          put next_entry ubicloud-pvm
          host_boot
          host_settle
          echo "Asked host $HOST to arm one more PVM kernel boot and reboot it"
          ;;
        "pvm uninstall")
          host_boot
          rm -f "$F/installed"
          put kernel "$STOCK"
          put next_entry ""
          put pvm_state uninstalled
          put label pvm_uninstalled
          page_add "ByohPvmUninstalled $HOST had its PVM host kernel uninstalled and cannot run VMs"
          ;;
        *) exit 97 ;;
      esac
      ;;
    ruby)
      local code=${UBICLOUD_CONSOLE_CODE:-}
      log "console $code"
      case "$code" in
        *"\"$NEG\"].incr_destroy") rm -f "$F/neg" ;;
        *"\"$HOST\"].incr_destroy") rm -f "$F/host" ;;
        *".incr_reboot")
          host_boot
          host_settle
          ;;
        *".incr_checkup")
          page_add "LastBootIDDiscrepancy Recorded last_boot_id of $HOST differs from the actual boot_id"
          host_settle
          ;;
        *) exit 97 ;;
      esac
      ;;
    *) exit 97 ;;
  esac
}

cmd_ubi() {
  log "ubi $*"
  case "$3" in
    create)
      [[ " $* " != *" -b ubuntu-jammy "* ]] || { echo "! Invalid request: pvm VMs boot ubuntu-noble only (direct kernel boot), not ubuntu-jammy" && exit 1; }
      touch "$F/vm" "$F/vm_running"
      put vm_sha "$(get guest_pin)"
      put vm_created "$(date -u +%FT%TZ)"
      ;;
    show)
      has vm || exit 1
      local state=stopped
      has vm_running && state=running
      if [[ ${4:-} == -f ]]; then
        [[ $5 == id ]] && echo "id: $VM"
        [[ $5 == state ]] && echo "state: $state"
      else
        printf 'id: %s\nstate: %s\nvirt-tier: pvm (experimental) PVM\n  guest-kernel: %s sha256 %s config checked\n' "$VM" "$state" "$PVM" "$(get vm_sha)"
      fi
      ;;
    stop) rm -f "$F/vm_running" ;;
    start)
      touch "$F/vm_running"
      put vmboot $(($(get vmboot) + 1))
      if [[ $(get vm_sha) != "$(get guest_pin)" ]]; then
        put vm_sha "$(get guest_pin)"
        page_del ByohPvmGuestKernelStale
      fi
      ;;
    restart) put vmboot $(($(get vmboot) + 1)) ;;
    destroy)
      rm -f "$F/vm" "$F/vm_running"
      put vm_deleted "$(date -u +%FT%TZ)"
      ;;
    serial-log) printf '[    0.000000] Linux version %s\nUbuntu 24.04 LTS pvm-e2e-a hvc0\npvm-e2e-a login: \n' "$PVM" ;;
    *) exit 97 ;;
  esac
}

pvm_on() { [[ $(get kernel) == "$PVM" ]]; }
neg() { if "$@"; then return 1; else return 0; fi; }

cmd_ssh() {
  local dest="" vm=0 a
  local args=("$@") i
  for ((i = 0; i < ${#args[@]}; i++)); do
    a=${args[i]}
    case $a in
      -i | -o | -p) i=$((i + 1)) ;;
      -n) ;;
      *@*)
        dest=$a
        break
        ;;
    esac
  done
  [[ $dest == ubi@* ]] && vm=1
  local cmd="${args[*]:i+1}"
  log "ssh $dest $cmd"
  if ((vm)); then
    has vm_running || exit 255
    case "$cmd" in
      true) ;;
      *boot_id) echo "vmboot-$(get vmboot)" ;;
      "uname -r") echo "$PVM" ;;
      *MemTotal*) echo 8 ;;
      "sh -s") cat >/dev/null && printf 'BYOH_PVM_BENCH cpu_sha256_1g 1200\nBYOH_PVM_BENCH mem_dd_8g 900\n' ;;
      fio*) echo "8000 7900" ;;
      curl*speed_download*) echo "50000000.000" ;;
      getent* | curl* | *apt-get* | nohup*) ;;
      *) echo "fake ssh vm: unhandled $cmd" >&2 && exit 97 ;;
    esac
    return
  fi
  # ssh hands the remote shell one string; "! CMD" negates CMD there.
  if [[ $cmd == "! "* ]]; then
    if cmd_ssh "$dest" "${cmd#! }"; then return 1; else return 0; fi
  fi
  case "$cmd" in
    *boot_id) echo "boot-$(get boot)" ;;
    "uname -r") get kernel && echo ;;
    *"grub-editenv list"*) printf 'saved_entry=%s\nnext_entry=%s\n' "$(get saved_entry)" "$(get next_entry)" ;;
    "grub-editenv - unset next_entry") put next_entry "" ;;
    "systemctl reboot") host_boot ;;
    *"install-pvm-host-kernel status"*) echo true ;;
    "grep -qw pti=off /proc/cmdline") pvm_on ;;
    "stat -c '%A %U %G' /dev/kvm") echo "crw-rw---- root kvm" ;;
    "grep -q '^kvm_pvm ' /proc/modules") pvm_on ;;
    *"-p ActiveState"*) echo active ;;
    *"-p Result"*) echo success ;;
    "apt-mark showhold") has installed && printf 'linux-image-%s\nlinux-image-%s\n' "$PVM" "$STOCK" ;;
    "apt-mark showhold | grep -qx linux-image-$STOCK") has installed ;;
    "systemctl is-system-running") echo running ;;
    "ls /etc/grub.d"*) echo "00_header 10_linux$(has installed && echo " 42_ubicloud_pvm")" ;;
    *"dpkg-query"*"grep -i pvm"*) has installed && echo "linux-image-$PVM install ok installed" ;;
    *"dpkg-query"*"grep 'pvm.* installed'") has installed ;;
    *"dpkg-query"*) echo "linux-image-$STOCK" ;;
    "[ ! -e /etc/grub.d/42_ubicloud_pvm ]") neg has installed ;;
    *journalctl*) get boot && echo ;;
    "ls /boot"*) echo "vmlinuz-$STOCK vmlinuz-$PVM" ;;
    "[ -d /var/storage ]") ;;
    *"apt-get install"*) ;;
    fio*) echo "9000 8800" ;;
    curl*speed_download*) echo "60000000.000" ;;
    *MemAvailable*)
      if has vm_running; then echo $(($(get mem) - 7000000)); else get mem && echo; fi
      ;;
    "BENCH_DIR="*"sh -s") cat >/dev/null && printf 'BYOH_PVM_BENCH cpu_sha256_1g 1000\nBYOH_PVM_BENCH mem_dd_8g 850\n' ;;
    "pgrep -f cloud-hypervisor >/dev/null") has vm_running ;;
    "systemctl cat "* | "ip netns list"*) has vm ;;
    "[ ! -e /vm/"*) neg has vm ;;
    "[ ! -e /etc/systemd/system/"*) neg has installed ;;
    *) echo "fake ssh host: unhandled $cmd" >&2 && exit 97 ;;
  esac
}

# The e2e waits in sleep: a MANUAL step is done here (the power cycle).
cmd_sleep() {
  local work=${FAKE_WORK:?}
  if [[ ! -e $F/manual_done ]] && grep -q 'MANUAL stop the instance' "$work/pvm-e2e-report.txt" 2>/dev/null; then
    host_boot
    touch "$F/manual_done" "$work/manual-done"
  fi
  local n
  n=$(($(get sleeps) + 1))
  put sleeps "$n"
  ((n < 2000)) || {
    echo "fake sleep: the e2e waited 2000 times; it never ends" >&2
    kill -TERM "$PPID"
    exit 1
  }
}

case "$(basename "$0")" in
  admin) cmd_admin "$@" ;;
  bundle) cmd_bundle "$@" ;;
  ubi) cmd_ubi "$@" ;;
  ssh) cmd_ssh "$@" ;;
  sleep) cmd_sleep ;;
  pgrep) exit 1 ;;
  *) exit 97 ;;
esac
