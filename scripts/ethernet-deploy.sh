# Deploy the configuration to a running Pi on the direct ethernet cable,
# without reflashing: build (in practice: substitute from the binary cache)
# the system toplevel, copy only the store paths the Pi is missing, and
# switch it to the new generation. A small config change transfers megabytes
# instead of the full ~1.3 GB image; reflashing is only needed for changes
# the running system can't switch into (partition layout, broken boots).
#
# Unlike its siblings, `nix` itself is deliberately NOT a pinned runtime
# input: the script drives the invoking host's daemon and flake config.
#
# Usage: ethernet-deploy [flake-ref] [nixos-config-name]
# Defaults: flake-ref '.', config name 'mailbox-pi' — downstream flakes pass
# their own, e.g. `nix run <this-flake>#ethernet-deploy -- . my-station`.
#
# This host is typically x86_64 while the Pi is aarch64: without binfmt
# emulation the toplevel must be substitutable, i.e. CI must have built and
# pushed the exact working-tree contents (commit, push, wait for the build).

flake="${1:-.}"
config="${2:-mailbox-pi}"
attr="$flake#nixosConfigurations.$config.config.system.build.toplevel"

echo ">> building/substituting $attr" >&2
if ! toplevel=$(nix build --no-link --print-out-paths --accept-flake-config "$attr"); then
  echo "error: toplevel build failed. On an x86_64 host without aarch64 emulation this" >&2
  echo "usually means the binary cache doesn't have this exact tree yet — commit, push," >&2
  echo "wait for CI, and re-run (or enable boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ])." >&2
  exit 1
fi

pi="$(find-pi)"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# nix's ssh:// URLs need IPv6 addresses bracketed, with the link-local zone
# separator URL-escaped (fe80::x%eth0 -> [fe80::x%25eth0]).
host="$pi"
case "$host" in
  *%*) host="[${host//%/%25}]" ;;
  *:*) host="[$host]" ;;
esac

echo ">> copying missing store paths to admin@$pi" >&2
NIX_SSHOPTS="${ssh_opts[*]}" nix copy --to "ssh://admin@$host" "$toplevel"

echo ">> switching the Pi to the new generation" >&2
# shellcheck disable=SC2029 # $toplevel expanding client-side is the point
ssh "${ssh_opts[@]}" "admin@$pi" \
  "sudo nix-env -p /nix/var/nix/profiles/system --set '$toplevel' \
   && sudo '$toplevel/bin/switch-to-configuration' switch"

echo ">> deployed: $toplevel" >&2
