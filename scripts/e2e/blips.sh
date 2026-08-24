#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Store a blip, fetch it back byte-for-byte (/blips/store + /blips/get).

note "blips: store/fetch roundtrip"
blip_roundtrip "e2e-$$-$RANDOM" 1
note "blips: ok"
