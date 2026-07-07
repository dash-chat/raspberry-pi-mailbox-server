#!/usr/bin/env bash
# Print the device path of THE SD card: the single removable/USB disk that
# isn't the system disk. Zero or several candidates -> explain on stderr and
# exit 1/2, so callers can fall back to asking for an explicit device.
set -euo pipefail

# The disk backing / must never be a candidate ([...] strips a btrfs
# subvolume suffix from findmnt's SOURCE).
root_disk="$(lsblk -no PKNAME "$(findmnt -no SOURCE / | sed 's/\[.*//')" 2>/dev/null | head -1 || true)"

mapfile -t cands < <(lsblk -dno NAME,TYPE,RM,TRAN | awk -v rd="$root_disk" \
  '$2 == "disk" && $1 != rd && ($3 == "1" || $4 == "usb") { print $1 }')

case "${#cands[@]}" in
  0)
    echo "no removable disk found — insert the SD card, or pass the device explicitly" >&2
    exit 1
    ;;
  1)
    echo "/dev/${cands[0]}"
    ;;
  *)
    echo "several removable disks found — pass the device explicitly:" >&2
    for c in "${cands[@]}"; do lsblk -dno NAME,SIZE,TRAN,VENDOR,MODEL "/dev/$c" >&2; done
    exit 2
    ;;
esac
