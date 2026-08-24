# Run the e2e suite against a real, already-flashed mailbox Pi on the
# ethernet cable. Each test is its own script in this folder (also runnable
# directly, e.g. ./scripts/e2e/blips.sh); this runner discovers the Pi once,
# exports it, and runs the requested tests in order, failing fast.
#
# Usage: e2e-test [test ...]
#   tests: health blips blobs mdns longevity   (no args = all of them)
# Environment: PI / PORT / E2E_MINUTES, see lib.sh and longevity.sh.
#
# The nix package prepends `e2e_dir=<store path of this folder>`; when run
# straight from the repo, fall back to this script's own directory.
e2e_dir="${e2e_dir:-$(dirname "$0")}"

tests=("$@")
[ ${#tests[@]} -gt 0 ] || tests=(health blips blobs mdns longevity)

for t in "${tests[@]}"; do
  case "$t" in
    health | blips | blobs | mdns | longevity) ;;
    *)
      echo "unknown test '$t' (known: health blips blobs mdns longevity)" >&2
      exit 1
      ;;
  esac
done

PI="${PI:-$(find-pi)}"
export PI

for t in "${tests[@]}"; do
  bash "$e2e_dir/$t.sh"
done

echo "PASS: ${tests[*]}"
