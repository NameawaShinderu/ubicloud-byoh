#!/bin/bash
# The `ubicloud-host storage-disk` cases (M4 WP6). Run inside a throwaway
# ubuntu:24.04 container by storage-disk-fixtures.sh, never on a real
# host: every block device command is storage-disk-shim, and every file
# the script touches is under a per-case fixture root.
#
#   storage-disk-cases.sh HOST_SCRIPT SHIM
set -uo pipefail

HOST=$1
SHIM=$2
WORK=$(mktemp -d)
PASS=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# base: a root disk sda (sda1 holds /), a blank disk sdb and a blank
# disk sdc, by-id links for each.
base() {
  R=$WORK/$1
  rm -rf "$R"
  mkdir -p "$R"/{etc,shim,fake/{disk,mnt,block},dev/disk/by-id,sys/block/{sda,sdb,sdc}/holders}
  printf '# /etc/fstab\nLABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1\n' >"$R/etc/fstab"
  : >"$R/fake/log"
  : >"$R/fake/mounted"
  local c
  for c in lsblk findmnt blkid wipefs swapon blockdev dd mkfs.ext4 chattr mount multipath udevadm systemctl; do
    ln -s "$SHIM" "$R/shim/$c"
  done
  mkdir -p "$R/fake/disk/"{sda,sdb,sdc}
  echo "sda1 /" >"$R/fake/disk/sda/parts"
  echo gpt >"$R/fake/disk/sda/pttype"
  echo "0x200 gpt" >"$R/fake/disk/sda/sig"
  echo "/dev/sda1 8:1" >"$R/fake/mnt/_"
  printf 'NAME="sda1" TYPE="part"\nNAME="sda" TYPE="disk"\n' >"$R/fake/block/_dev_block_8:1"
  echo "QEMU HARDDISK" >"$R/fake/disk/sdb/model"
  echo blank1 >"$R/fake/disk/sdb/serial"
  echo blank2 >"$R/fake/disk/sdc/serial"
  ln -s ../../sda "$R/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root"
  ln -s ../../sda1 "$R/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root-part1"
  ln -s ../../sdb "$R/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_blank1"
  ln -s ../../sdc "$R/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_blank2"
  ln -s ../../dm-0 "$R/dev/disk/by-id/dm-name-vg0-data"
}

# sd ARGS...: runs storage-disk on the current fixture root; sets OUT,
# ERR and RC.
sd() {
  RC=0
  OUT=$(PATH=$R/shim:$PATH UBICLOUD_HOST_TEST_ROOT=$R bash "$HOST" storage-disk --fixture-root "$R" "$@" 2>"$WORK/err") || RC=$?
  ERR=$(<"$WORK/err")
}

expect_refused() {
  local case=$1 want=$2
  ((RC == 1)) || fail "$case: exit $RC, expected 1 (out: $OUT; err: $ERR)"
  [[ $ERR == *"storage-disk: refused: "*"$want"* ]] || fail "$case: stderr '$ERR' lacks 'refused: ...$want'"
  ! grep -q '^mkfs.ext4\|^chattr\|^mount' "$R/fake/log" || fail "$case: a refused run changed something: $(cat "$R/fake/log")"
  pass "$case"
}

pass() {
  PASS=$((PASS + 1))
  echo "pass $1"
}

fstab_lines() {
  grep -c "$1" "$R/etc/fstab" || true
}

# --- refusals ----------------------------------------------------------

base root
sd --by-id scsi-0QEMU_QEMU_HARDDISK_root
expect_refused "root disk" "scsi-0QEMU_QEMU_HARDDISK_root is the disk of /"

base boot
echo "/dev/sdb 8:16" >"$R/fake/mnt/_boot_efi"
printf 'NAME="sdb" TYPE="disk"\n' >"$R/fake/block/_dev_block_8:16"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "boot/efi disk" "is the disk of /boot/efi"

base partition-link
sd --by-id scsi-0QEMU_QEMU_HARDDISK_root-part1
expect_refused "partition link" "points at sda1, which is not a whole disk"

base dm-link
sd --by-id dm-name-vg0-data
expect_refused "dm link" "is a device-mapper, LVM or md link"

base two-links
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank
expect_refused "by-id matching two links" "matches 2 links (scsi-0QEMU_QEMU_HARDDISK_blank1 scsi-0QEMU_QEMU_HARDDISK_blank2)"

base no-link
sd --by-id wwn-0xdeadbeef
expect_refused "missing link" "no /dev/disk/by-id link named wwn-0xdeadbeef"

base not-disk
echo rom >"$R/fake/disk/sdb/type"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "not a disk" "is a rom, not a disk"

base partitions
echo "sdb1" >"$R/fake/disk/sdb/parts"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "partitions" "has partitions (/dev/sdb1)"

base mounted
echo /mnt/scratch >"$R/fake/disk/sdb/mounts"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "mounted disk" "is mounted (/dev/sdb at /mnt/scratch)"

base holders
touch "$R/sys/block/sdb/holders/dm-3"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "holders" "is held by dm-3"

base swap
printf '/dev/sda2\n/dev/sdb\n' >"$R/fake/swaps"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "swap" "is in use as swap"

base signature
echo "0x218 LVM2_member LVM2 001" >"$R/fake/disk/sdb/sig"
echo LVM2_member >"$R/fake/disk/sdb/fstype"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "wipefs signature" "carries a signature: 0x218 LVM2_member LVM2 001"

base blkid-only
echo dos >"$R/fake/disk/sdb/pttype"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "blkid partition table" "carries a signature: PTTYPE=dos"

base backup-gpt
printf 'EFI PART\000\000\001\000' >"$R/fake/disk/sdb/lastblock"
echo 4096 >"$R/fake/disk/sdb/ss"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "backup GPT" "carries a backup GPT header in its last block"
grep -qx "dd if=/dev/sdb bs=4096 skip=2621439 count=1 status=none" "$R/fake/log" || fail "backup GPT: dd did not read the last 4096-byte block ($(grep ^dd "$R/fake/log"))"

base iscsi
echo iscsi >"$R/fake/disk/sdb/tran"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "iscsi" "is shared storage (iscsi) another machine may write to"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1 --allow-shared-transport
((RC == 0)) || fail "iscsi with --allow-shared-transport: exit $RC ($ERR)"
grep -q "warning: .* shared storage (iscsi)" <<<"$ERR" || fail "iscsi allowed: no warning ($ERR)"
pass "iscsi with --allow-shared-transport"

base multipath
echo /dev/sdb >"$R/fake/multipath"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "multipath" "is shared storage (multipath)"

base blkid-error
echo 4 >"$R/fake/disk/sdb/blkid.rc"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
((RC == 3)) || fail "blkid error: exit $RC, expected 3 ($ERR)"
pass "blkid error fails closed"

base not-ours
echo ext4 >"$R/fake/disk/sdb/fstype"
echo ubi-disk1 >"$R/fake/disk/sdb/label"
echo 0b5e0000-0000-4000-8000-000000000001 >"$R/fake/disk/sdb/uuid"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "our label without fstab" "carries the label ubi-disk1 but /etc/fstab does not mount"

# --- formatting --------------------------------------------------------

base blank
sd --by-id /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_blank1
((RC == 0)) || fail "blank: exit $RC ($ERR)"
uuid=$(<"$R/fake/disk/sdb/uuid")
grep -qF "storage-disk: scsi-0QEMU_QEMU_HARDDISK_blank1 is /dev/sdb: 10G, model 'QEMU HARDDISK', serial 'blank1'" <<<"$OUT" || fail "blank: no size/model/serial line ($OUT)"
[[ $(tail -1 <<<"$OUT") == "storage-disk: ok /var/storage/devices/disk1 UUID=$uuid" ]] || fail "blank: last line is '$(tail -1 <<<"$OUT")'"
[[ $(tail -2 "$R/etc/fstab") == "# ubicloud-host storage-disk scsi-0QEMU_QEMU_HARDDISK_blank1
UUID=$uuid /var/storage/devices/disk1 ext4 defaults,nofail 0 2" ]] || fail "blank: fstab is $(cat "$R/etc/fstab")"
grep -q "^LABEL=cloudimg-rootfs / " "$R/etc/fstab" || fail "blank: the root line is gone"
grep -qx "mkfs.ext4 -q -L ubi-disk1 /dev/sdb" "$R/fake/log" || fail "blank: mkfs call ($(grep ^mkfs "$R/fake/log"))"
grep -qx "chattr +i $R/var/storage/devices/disk1" "$R/fake/log" || fail "blank: no chattr +i on the mount point"
[[ $(grep -n '^chattr' "$R/fake/log" | cut -d: -f1) -lt $(grep -n '^mkfs' "$R/fake/log" | cut -d: -f1) ]] || fail "blank: chattr after mkfs"
grep -qx "mount /var/storage/devices/disk1" "$R/fake/log" || fail "blank: no mount"
[[ -z $(find "$R/etc" -name '.fstab*') ]] || fail "blank: a temporary fstab is left"
pass "blank disk formatted, fstab line and disk1"

# A re-run passes and changes nothing.
cp "$R/etc/fstab" "$WORK/fstab.before"
: >"$R/fake/log"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
((RC == 0)) || fail "re-run: exit $RC ($ERR)"
grep -q "already set up" <<<"$OUT" || fail "re-run: $OUT"
[[ $(tail -1 <<<"$OUT") == "storage-disk: ok /var/storage/devices/disk1 UUID=$uuid" ]] || fail "re-run: last line '$(tail -1 <<<"$OUT")'"
cmp -s "$WORK/fstab.before" "$R/etc/fstab" || fail "re-run: fstab changed"
! grep -q '^mkfs\|^mount\|^chattr' "$R/fake/log" || fail "re-run: acted ($(cat "$R/fake/log"))"
pass "re-run passes"

# A run cut short after the fstab write mounts on the next run.
: >"$R/fake/disk/sdb/mounts"
: >"$R/fake/log"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
((RC == 0)) || fail "resume: exit $RC ($ERR)"
grep -qx "mount /var/storage/devices/disk1" "$R/fake/log" || fail "resume: no mount"
! grep -q '^mkfs' "$R/fake/log" || fail "resume: formatted again"
cmp -s "$WORK/fstab.before" "$R/etc/fstab" || fail "resume: fstab changed"
pass "re-run mounts an unmounted disk of ours"

# The second disk takes disk2.
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank2
((RC == 0)) || fail "second disk: exit $RC ($ERR)"
[[ $(tail -1 <<<"$OUT") == "storage-disk: ok /var/storage/devices/disk2 UUID=$(<"$R/fake/disk/sdc/uuid")" ]] || fail "second disk: '$(tail -1 <<<"$OUT")'"
[[ $(fstab_lines "/var/storage/devices/disk") == 2 ]] || fail "second disk: fstab $(cat "$R/etc/fstab")"
pass "second disk gets disk2"

# diskN skips fstab lines (StorageDiskFormatter's too), mounts and
# non-empty directories.
base next-free
printf '# /dev/nvme1n1\nUUID=1111 /var/storage/devices/disk1 ext4 defaults 0 2' >>"$R/etc/fstab"
mkdir -p "$R/var/storage/devices/disk2" && touch "$R/var/storage/devices/disk2/leftover"
echo "/var/storage/devices/disk3 /dev/sdz" >"$R/fake/mounted"
mkdir -p "$R/var/storage/devices/disk4"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
((RC == 0)) || fail "next free: exit $RC ($ERR)"
[[ $(tail -1 <<<"$OUT") == "storage-disk: ok /var/storage/devices/disk4 UUID=$(<"$R/fake/disk/sdb/uuid")" ]] || fail "next free: '$(tail -1 <<<"$OUT")'"
grep -qx "UUID=1111 /var/storage/devices/disk1 ext4 defaults 0 2" "$R/etc/fstab" || fail "next free: the unterminated last line was damaged ($(cat "$R/etc/fstab"))"
pass "next free diskN"

# --- guards ------------------------------------------------------------

base guard
RC=0
UBICLOUD_HOST_TEST_ROOT=$R bash "$HOST" storage-disk --fixture-root "$R" --by-id scsi-0QEMU_QEMU_HARDDISK_blank1 >/dev/null 2>"$WORK/err" || RC=$?
{ ((RC == 3)) && grep -q "is not the shim" "$WORK/err"; } || fail "test mode without shims: exit $RC ($(cat "$WORK/err"))"
pass "test mode refuses real commands"

RC=0
setpriv --reuid=65534 --regid=65534 --clear-groups bash "$HOST" storage-disk --by-id x >/dev/null 2>"$WORK/err" || RC=$?
{ ((RC == 2)) && grep -q "must run as root" "$WORK/err"; } || fail "non-root: exit $RC ($(cat "$WORK/err"))"
pass "non-root is a usage error"

RC=0
bash "$HOST" storage-disk >/dev/null 2>&1 || RC=$?
((RC == 2)) || fail "no --by-id: exit $RC"
RC=0
bash "$HOST" storage-disk --by-id x --wipe >/dev/null 2>&1 || RC=$?
((RC == 2)) || fail "unknown flag: exit $RC"
pass "usage errors"

# --- why storage-disk probes the disk itself ----------------------------

# mke2fs (e2fsprogs 1.47) checks for an existing filesystem only when
# stdin and stdout are a tty, so without one it overwrites, -F or not.
# If this ever starts failing, mke2fs became a second guard.
if command -v mkfs.ext4 >/dev/null; then
  img=$WORK/disk.img
  truncate -s 64M "$img"
  mkfs.ext4 -q -L first "$img" </dev/null >/dev/null 2>&1 || fail "real mkfs.ext4 on a blank image failed"
  RC=0
  mkfs.ext4 -q -L second "$img" </dev/null >/dev/null 2>&1 || RC=$?
  ((RC == 0)) || fail "real mkfs.ext4 without a tty refused an existing filesystem (exit $RC); update the comment in storage_disk"
  pass "real mkfs.ext4 without a tty overwrites, so the probes are the guard"
else
  echo "skip real mkfs.ext4 check (e2fsprogs missing)"
fi

# A signature that appears between the checks and mkfs is caught by the
# probe under the fstab lock: this wipefs reports one from its second
# call on.
base race
mkdir "$R/real"
mv "$R/shim/wipefs" "$R/real/wipefs"
# shellcheck disable=SC2016 # expands in the wrapper
printf '#!/bin/bash\nn=$(grep -c "^wipefs" "%s/fake/log")\n"%s/real/wipefs" "$@" || exit\n((n == 0)) || echo "0x0 ext4 raced"\n' "$R" "$R" >"$R/shim/wipefs"
chmod +x "$R/shim/wipefs"
sd --by-id scsi-0QEMU_QEMU_HARDDISK_blank1
expect_refused "signature raced in" "gained a signature while being checked: 0x0 ext4 raced"

echo "PASS storage-disk cases: $PASS"
