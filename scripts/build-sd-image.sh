# Build a nixosConfiguration's SD image and decompress it to a flashable
# .img (the build output stays compressed in the store; only the local copy
# is expanded). Companion to flash-sd-image, split out so downstream flakes
# can build their own configs with it.
#
# Like ethernet-deploy, `nix` itself is deliberately NOT a pinned runtime
# input: the script drives the invoking host's daemon and flake config.
#
# Usage: build-sd-image [flake-ref] [nixos-config-name] [out-img]
# Defaults: flake-ref '.', config name 'mailbox-pi', out-img '<config>.img' —
# downstream flakes pass their own, e.g.
# `nix run <this-flake>#build-sd-image -- . my-station`.

flake="${1:-.}"
config="${2:-mailbox-pi}"
out="${3:-$config.img}"
attr="$flake#nixosConfigurations.$config.config.system.build.sdImage"

echo ">> building/substituting $attr" >&2
if ! image=$(nix build --no-link --print-out-paths --accept-flake-config -L "$attr"); then
  echo "error: sdImage build failed. On an x86_64 host without aarch64 emulation this" >&2
  echo "usually means the binary cache doesn't have this exact tree yet — commit, push," >&2
  echo "wait for CI, and re-run (or enable boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ])." >&2
  exit 1
fi

zst="$(echo "$image"/sd-image/*.img.zst)"
[ -f "$zst" ] || { echo "no *.img.zst under $image/sd-image/ — did the build succeed?" >&2; exit 1; }

echo ">> decompressing $zst -> $out" >&2
rm -f "$out"
zstd -d "$zst" -o "$out"
ls -lh "$out"
