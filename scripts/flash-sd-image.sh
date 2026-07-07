#!/usr/bin/env bash
# Flash an SD-card image and optionally copy env files onto its FAT boot
# partition (where the appliance reads wifi-ap.env & friends).
#
#   flash-sd-image.sh <image> [device] [env_dir]
#
# Empty/omitted device -> auto-detect via detect-sd-card (the single
# removable/USB disk that isn't the system disk). Empty/omitted env_dir ->
# leave the boot partition as-is. Interactive: asks to retype the device
# path before erasing it. Needs sudo for dd/mount.
set -euo pipefail

img="${1:?usage: flash-sd-image.sh <image> [device] [env_dir]}"
dev="${2:-}"
envdir="${3:-}"

[ -f "$img" ] || { echo "image '$img' not found" >&2; exit 1; }
[ -z "$envdir" ] || [ -d "$envdir" ] || { echo "env dir '$envdir' does not exist" >&2; exit 1; }

if [ -z "$dev" ]; then
  if command -v detect-sd-card >/dev/null 2>&1; then
    dev="$(detect-sd-card)"
  else
    dev="$("$(dirname "$0")/detect-sd-card.sh")"
  fi
  echo ">> auto-detected SD card: $dev"
fi

[ -b "$dev" ] || { echo "'$dev' is not a block device" >&2; exit 1; }
[ "$(lsblk -dno TYPE "$dev")" = "disk" ] || { echo "'$dev' is not a whole disk" >&2; exit 1; }

echo "This will ERASE and overwrite:"
lsblk -o NAME,SIZE,TYPE,TRAN,VENDOR,MODEL,MOUNTPOINTS "$dev"
read -rp "Retype the device path to confirm ($dev): " ok
[ "$ok" = "$dev" ] || { echo "no match; aborting" >&2; exit 1; }

# Unmount anything currently mounted from the target.
lsblk -rno NAME "$dev" | tail -n +2 | while read -r p; do
  sudo umount "/dev/$p" 2>/dev/null || true
done

echo ">> flashing $img -> $dev"
sudo dd if="$img" of="$dev" bs=4M conv=fsync status=progress
sync
sudo partprobe "$dev" 2>/dev/null || true
sudo udevadm settle 2>/dev/null || true

# Locate the FAT boot partition, retrying while udev re-reads the freshly
# written partition table.
boot=""
for _ in {1..10}; do
  boot="$(lsblk -rno NAME,FSTYPE "$dev" | awk '$2=="vfat"{print "/dev/"$1; exit}')"
  [ -n "$boot" ] && break
  sudo partprobe "$dev" 2>/dev/null || true
  sudo udevadm settle 2>/dev/null || true
  sleep 1
done
if [ -z "$boot" ]; then boot="${dev}1"; [ -b "$boot" ] || boot="${dev}p1"; fi
[ -b "$boot" ] || { echo "could not find the FAT boot partition on $dev" >&2; exit 1; }

if [ -z "$envdir" ]; then
  echo ">> no env dir given — leaving the boot partition as-is"
  echo ">> done — $dev is ready to boot"
  exit 0
fi

mnt="$(mktemp -d)"
trap 'sudo umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
sudo mount "$boot" "$mnt"
shopt -s nullglob
files=("$envdir"/*)
if [ "${#files[@]}" -eq 0 ]; then
  echo ">> note: '$envdir/' is empty — nothing to copy"
else
  echo ">> copying ${#files[@]} file(s) from $envdir/ to $boot"
  for f in "${files[@]}"; do
    [ -f "$f" ] && sudo cp -v "$f" "$mnt/"
  done
  sync
fi
echo ">> done — $dev is ready to boot"
