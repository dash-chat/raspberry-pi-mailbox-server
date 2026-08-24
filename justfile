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
# this local copy is expanded.
# Build the SD image and decompress it to mailbox.img for flashing.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#sdImage -L --accept-flake-config
    zst="$(echo result/sd-image/*.img.zst)"
    [ -f "$zst" ] || { echo "no *.img.zst under result/sd-image/ — did the build succeed?"; exit 1; }
    echo ">> decompressing $zst -> {{image}}"
    rm -f "{{image}}"
    zstd -d "$zst" -o "{{image}}"
    ls -lh "{{image}}"

# Configure a MikroTik mAP lite as the station AP: joins the unit's current
# wifi (factory: MikroTik-XXXXXX, WPA2 password on the sticker of newer
# units — pass '' for older open ones), then sets up WPA2 with the target
# ssid/password and bridges the ethernet port into the LAN (the factory
# default has it as firewalled WAN, which would hide the Pi from the
# phones). Prompts for the unit's admin password (also on the sticker;
# empty on older units), and rejoins the target wifi to verify convergence.
# Usage: just setup-maplite <unit-ssid> <unit-wifi-password> <ssid> <password> [host]
setup-maplite unit_ssid unit_password ssid password *args:
    nix run .#setup-maplite -- "{{unit_ssid}}" "{{unit_password}}" "{{ssid}}" "{{password}}" {{args}}

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
# Usage: just flash [/dev/sdX]   (list candidates with `just devices`)
flash device="":
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f "{{image}}" ] || { echo "image '{{image}}' not found — build it first (see README)"; exit 1; }
    ./scripts/flash-sd-image.sh "{{image}}" "{{device}}" "{{env_dir}}"
