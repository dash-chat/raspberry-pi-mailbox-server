#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Soak test: a health check + blip roundtrip every 20 s for E2E_MINUTES
# (default 20) minutes, and the service must neither fail nor restart.

minutes="${E2E_MINUTES:-20}"
interval=20
note "longevity: ${minutes}m soak, health + blip roundtrip every ${interval}s"

# Restart counter before/after: a crash mid-soak that systemd papers over
# with a restart must still fail the test. Skipped (with a warning) when
# ssh isn't available, e.g. against a local server.
restarts_before=""
if restarts_before="$(ssh_pi systemctl show dashchat-mailbox -p NRestarts --value 2>/dev/null)"; then
  note "longevity: NRestarts before soak: $restarts_before"
else
  note "longevity: WARNING: no ssh access, skipping service-restart check"
fi

long_topic="e2e-long-$$"
i=1
deadline=$(($(date +%s) + minutes * 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(health_json | jq -r .status)" = ok ] \
    || fail "longevity: health check failed at iteration $i"
  blip_roundtrip "$long_topic" "$i"
  note "longevity: iteration $i ok"
  i=$((i + 1))
  sleep "$interval"
done

if [ -n "$restarts_before" ]; then
  restarts_after="$(ssh_pi systemctl show dashchat-mailbox -p NRestarts --value)" \
    || fail "longevity: lost ssh access during soak"
  [ "$restarts_after" = "$restarts_before" ] \
    || fail "longevity: service restarted during soak ($restarts_before -> $restarts_after)"
  [ "$(ssh_pi systemctl is-active dashchat-mailbox)" = active ] \
    || fail "longevity: service not active after soak"
fi
note "longevity: ok ($((i - 1)) iterations)"
