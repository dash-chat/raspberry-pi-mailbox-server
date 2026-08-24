#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# GET /health answers ok and carries a MailboxId.

note "health: GET /health"
h="$(health_json)" || fail "health endpoint unreachable"
[ "$(jq -r .status <<< "$h")" = ok ] || fail "health status not ok: $h"
eid="$(jq -r .endpoint_id <<< "$h")"
[ -n "$eid" ] && [ "$eid" != null ] || fail "health has no endpoint_id: $h"
note "health: ok, endpoint_id $eid"
