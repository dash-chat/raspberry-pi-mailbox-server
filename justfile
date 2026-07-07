# Flashing helpers for the Dash Chat mailbox Pi image.
#
# Run with just (not bundled in the flake): `nix run nixpkgs#just -- <recipe>`.

# The flashable image (built per the README) and the folder whose contents are
# dropped onto the image's FAT boot partition (/boot/firmware) — e.g.
# wifi-ap.env, wifi.env.
image := "mailbox.img"
env_dir := "env"

# Show available recipes.
_default:
    @just --list

# The image is an aarch64 build, so on an x86_64 host this needs aarch64
# emulation (see flake.nix). The build stays compressed in the store/cache; only
# this local copy is expanded.
# Build the SD image and decompress it to mailbox.img for flashing.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build github:dash-chat/raspberry-pi-mailbox-server#sdImage -L --accept-flake-config
    zst="$(echo result/sd-image/*.img.zst)"
    [ -f "$zst" ] || { echo "no *.img.zst under result/sd-image/ — did the build succeed?"; exit 1; }
    echo ">> decompressing $zst -> {{image}}"
    rm -f "{{image}}"
    zstd -d "$zst" -o "{{image}}"
    ls -lh "{{image}}"

# List candidate block devices, to pick the SD-card target for `flash`.
devices:
    lsblk -do NAME,SIZE,TYPE,TRAN,VENDOR,MODEL,RM

# Flash the image to an SD card and copy env/* onto its FAT boot partition.
# With no device given, the SD card is auto-detected: the single removable/
# USB disk that isn't the system disk (ambiguity aborts — the retype-to-
# confirm prompt below is still the final gate either way).
# Usage: just flash [/dev/sdX]   (list candidates with `just devices`)
flash device="":
    #!/usr/bin/env bash
    set -euo pipefail
    img="{{image}}"; dev="{{device}}"; envdir="{{env_dir}}"

    [ -f "$img" ] || { echo "image '$img' not found — build it first (see README)"; exit 1; }

    if [ -z "$dev" ]; then
      # The disk backing / must never be a candidate ([...] strips a btrfs
      # subvolume suffix from findmnt's SOURCE).
      root_disk="$(lsblk -no PKNAME "$(findmnt -no SOURCE / | sed 's/\[.*//')" 2>/dev/null | head -1 || true)"
      mapfile -t cands < <(lsblk -dno NAME,TYPE,RM,TRAN | awk -v rd="$root_disk" \
        '$2 == "disk" && $1 != rd && ($3 == "1" || $4 == "usb") { print $1 }')
      case "${#cands[@]}" in
        0) echo "no removable disk found — insert the SD card, or pass the device (see 'just devices')"; exit 1 ;;
        1) dev="/dev/${cands[0]}"; echo ">> auto-detected SD card: $dev" ;;
        *) echo "several removable disks found — pass the device explicitly:"
           for c in "${cands[@]}"; do lsblk -dno NAME,SIZE,TRAN,VENDOR,MODEL "/dev/$c"; done
           exit 1 ;;
      esac
    fi

    [ -b "$dev" ] || { echo "'$dev' is not a block device; run 'just devices'"; exit 1; }
    [ "$(lsblk -dno TYPE "$dev")" = "disk" ] || { echo "'$dev' is not a whole disk"; exit 1; }

    echo "This will ERASE and overwrite:"
    lsblk -o NAME,SIZE,TYPE,TRAN,VENDOR,MODEL,MOUNTPOINTS "$dev"
    read -rp "Retype the device path to confirm ($dev): " ok
    [ "$ok" = "$dev" ] || { echo "no match; aborting"; exit 1; }

    # Unmount anything currently mounted from the target.
    for p in $(lsblk -rno NAME "$dev" | tail -n +2); do sudo umount "/dev/$p" 2>/dev/null || true; done

    echo ">> flashing $img -> $dev"
    sudo dd if="$img" of="$dev" bs=4M conv=fsync status=progress
    sync
    sudo partprobe "$dev" 2>/dev/null || true
    sudo udevadm settle 2>/dev/null || true

    # Locate the FAT boot partition (the firmware partition mounted at
    # /boot/firmware, where the appliance reads its *.env). Retry while udev
    # re-reads the freshly written partition table.
    boot=""
    for _ in $(seq 10); do
      boot="$(lsblk -rno NAME,FSTYPE "$dev" | awk '$2=="vfat"{print "/dev/"$1; exit}')"
      [ -n "$boot" ] && break
      sudo partprobe "$dev" 2>/dev/null || true; sudo udevadm settle 2>/dev/null || true; sleep 1
    done
    if [ -z "$boot" ]; then boot="${dev}1"; [ -b "$boot" ] || boot="${dev}p1"; fi
    [ -b "$boot" ] || { echo "could not find the FAT boot partition on $dev"; exit 1; }

    # Copy env/* onto it. (Copy, not move, so ./env stays reusable for the next
    # card — swap `cp` for `mv` below if you really want to move.)
    mnt="$(mktemp -d)"
    trap 'sudo umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
    sudo mount "$boot" "$mnt"
    shopt -s nullglob
    files=("$envdir"/*)
    if [ "${#files[@]}" -eq 0 ]; then
      echo ">> note: '$envdir/' is empty — nothing to copy"
    else
      echo ">> copying ${#files[@]} file(s) from $envdir/ to $boot"
      for f in "${files[@]}"; do [ -f "$f" ] && sudo cp -v "$f" "$mnt/"; done
      sync
    fi
    echo ">> done — $dev is ready to boot"
