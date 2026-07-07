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
# With no device given, the SD card is auto-detected (the single removable/
# USB disk that isn't the system disk; ambiguity aborts). Interactive: asks
# to retype the device path before erasing.
# Usage: just flash [/dev/sdX]   (list candidates with `just devices`)
flash device="":
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f "{{image}}" ] || { echo "image '{{image}}' not found — build it first (see README)"; exit 1; }
    ./scripts/flash-sd-image.sh "{{image}}" "{{device}}" "{{env_dir}}"
