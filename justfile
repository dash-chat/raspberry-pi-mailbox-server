# Flashing helpers for the Dash Chat mailbox Pi image.
#
# Run with just (not bundled in the flake): `nix run nixpkgs#just -- <recipe>`.

# The flashable image (built per the README). Set env_dir to a folder whose
# contents should be dropped onto the image's FAT boot partition
# (/boot/firmware), e.g. `just --set env_dir mydir flash`; empty = skip.
image := "mailbox.img"
env_dir := ""

# Show available recipes.
_default:
    @just --list

# The image is an aarch64 build, so on an x86_64 host this needs aarch64
# emulation (see flake.nix). The build stays compressed in the store/cache; only
# this local copy is expanded. Downstream flakes run the same script against
# their own config: `nix run <this-flake>#build-sd-image -- . my-station`.
# Build the SD image and decompress it to mailbox.img for flashing.
build:
    nix run .#build-sd-image -- . mailbox-pi "{{image}}"

# Substitutes the system toplevel from the binary cache (only the store paths
# that changed get downloaded), copies only what the Pi is missing over the
# cable, and switches it to the new generation. Without local aarch64
# emulation this needs CI to have built the exact working tree first (commit,
# push, wait for the build). Reflash only for partition-layout or
# boot-breaking changes.
# Deploy the current config to a running, already-flashed Pi (no reflash).
deploy *args:
    nix run .#ethernet-deploy -- {{args}}

# End-to-end tests against a real, already-flashed Pi on the ethernet cable.
# No args runs everything, including the ~20-minute longevity soak; pass a
# subset to run less, e.g. `just e2e health blips blobs mdns`. Override the
# soak length with E2E_MINUTES=<minutes>.
e2e *tests:
    nix run .#e2e-test -- {{tests}}

# List candidate block devices, to pick the SD-card target for `flash`.
devices:
    lsblk -do NAME,SIZE,TYPE,TRAN,VENDOR,MODEL,RM

# Flash the image to an SD card and copy env/* onto its FAT boot partition.
# With no device given, the SD card is auto-detected (the single removable/
# USB disk that isn't the system disk; ambiguity aborts). Interactive: asks
# to retype the device path before erasing.
# wifi_env is a file with WIFI_SSID= and WIFI_PASSWORD= (optional
# WIFI_COUNTRY=), installed on the boot partition as wifi.env so the Pi joins
# that Wi-Fi network as a client on boot (see nix/wifi-client.nix). Omit it
# for ethernet-only stations.
# Usage: just flash [/dev/sdX] [wifi.env]   (list candidates with `just devices`)
flash device="" wifi_env="":
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f "{{image}}" ] || { echo "image '{{image}}' not found — build it first (see README)"; exit 1; }
    ./scripts/flash-sd-image.sh "{{image}}" "{{device}}" "{{env_dir}}" "{{wifi_env}}"
