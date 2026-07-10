# Set a Pi's clock from this machine over the direct ethernet cable
# (discovery via find-pi), pushing the local time over ssh and writing it
# to the RTC when one is present (battery on J5 — then the time survives
# power-off and reflashing; without it, only until shutdown). Optional
# argument: the wired interface (auto-detected otherwise).

pi="$(find-pi "${1:-}")"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=4 -o LogLevel=ERROR)

# Stamp the epoch as late as possible ($(date +%s) expands HERE, on the
# laptop); date -s @<epoch> is timezone-proof.
# shellcheck disable=SC2029 # the client-side expansion is the point
out=$(ssh "${ssh_opts[@]}" "admin@$pi" "sudo /run/current-system/sw/bin/date -u -s @$(date +%s) > /dev/null && { sudo /run/current-system/sw/bin/hwclock -w 2>/dev/null && echo RTC_OK || echo RTC_MISSING; } && date")
rtc=$(head -n1 <<< "$out")
echo ">> Pi clock set: $(tail -n1 <<< "$out")"
case "$rtc" in
  RTC_OK)      echo ">> RTC written — the time now survives power-off and reflashing" ;;
  RTC_MISSING) echo ">> no RTC found (no battery on J5, or /dev/rtc0 missing) — the time holds until the Pi powers off" ;;
esac
